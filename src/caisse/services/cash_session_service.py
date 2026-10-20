import uuid
from datetime import UTC, date, datetime

from sqlalchemy.orm import Session

from caisse.config import get_settings
from caisse.domain import receipt as receipt_domain
from caisse.domain.enums import CashMovementType, CashSessionStatus, PrintJobType
from caisse.errors import (
    BusinessDateMismatchError,
    NoOpenSessionError,
    NoReceiptToReprintError,
    NotFoundError,
    SessionAlreadyClosedError,
    SessionAlreadyOpenError,
    SessionHasOpenOrdersError,
    SessionNotClosedError,
)
from caisse.models.cash_session import CashMovement, CashRegister, CashSession
from caisse.models.print_job import PrintJob
from caisse.repositories import sessions as sessions_repo
from caisse.repositories import settings as settings_repo
from caisse.schemas.sessions import (
    Controls,
    FiscalGroupTotal,
    PaymentMethodTotal,
    SessionTotals,
    XReportOut,
    ZReportOut,
)
from caisse.sequences import next_value
from caisse.services import audit_service, printing_service
from caisse.services.audit_service import RequestContext


def open_session(
    db: Session,
    *,
    cash_register_id: uuid.UUID,
    opening_float_xof: int,
    business_date: date | None,
    confirm_business_date: bool,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> CashSession:
    register = db.get(CashRegister, cash_register_id)
    if register is None or not register.is_active:
        raise NotFoundError(meta={"cash_register_id": str(cash_register_id)})
    if sessions_repo.get_open_for_register(db, cash_register_id) is not None:
        raise SessionAlreadyOpenError()

    effective_date = business_date or datetime.now(UTC).date()
    if not confirm_business_date:
        same_day = sessions_repo.get_closed_same_day(db, cash_register_id, effective_date)
        if same_day is not None:
            raise BusinessDateMismatchError(
                meta={
                    "business_date": str(effective_date),
                    "existing_session_id": str(same_day.id),
                }
            )

    now = datetime.now(UTC)
    session = CashSession(
        cash_register_id=cash_register_id,
        opened_by_user_id=actor_id,
        business_date=effective_date,
        status=CashSessionStatus.OPEN,
        opening_float_xof=opening_float_xof,
        opened_at=now,
    )
    db.add(session)
    db.flush()
    audit_service.log(
        db,
        "cash_session.open",
        ctx=ctx,
        user_id=actor_id,
        entity="cash_session",
        entity_id=session.id,
        after={"cash_register_id": str(cash_register_id), "opening_float_xof": opening_float_xof},
    )
    db.commit()
    return session


def _totals(db: Session, session_id: uuid.UUID) -> SessionTotals:
    orders_count, gross_ttc_xof = sessions_repo.orders_count_and_gross(db, session_id)
    vat_xof = sessions_repo.vat_total(db, session_id)
    by_method = sessions_repo.payment_totals_by_method(db, session_id)
    by_group = sessions_repo.fiscal_group_totals(db, session_id)
    cancelled_orders, removed_items, reprints = sessions_repo.controls(db, session_id)
    return SessionTotals(
        gross_ttc_xof=gross_ttc_xof,
        vat_xof=vat_xof,
        orders_count=orders_count,
        by_payment_method=[
            PaymentMethodTotal(method=method, amount_xof=amount, count=count)
            for method, amount, count in by_method
        ],
        by_fiscal_group=[
            FiscalGroupTotal(group=group, quantity=qty, amount_xof=amount)
            for group, qty, amount in by_group
        ],
        controls=Controls(
            cancelled_orders=cancelled_orders, removed_items=removed_items, reprints=reprints
        ),
    )


def _expected_cash(db: Session, session: CashSession) -> int:
    movements_in, movements_out = sessions_repo.movements_sum(db, session.id)
    cash_captured = sessions_repo.cash_captured_total(db, session.id)
    return session.opening_float_xof + cash_captured + movements_in - movements_out


def x_report(db: Session, session_id: uuid.UUID) -> XReportOut:
    session = sessions_repo.get(db, session_id)
    if session is None:
        raise NotFoundError(meta={"session_id": str(session_id)})
    return XReportOut(
        session_id=session.id,
        business_date=session.business_date,
        expected_cash_xof=_expected_cash(db, session),
        totals=_totals(db, session_id),
    )


def close_session(
    db: Session,
    session_id: uuid.UUID,
    *,
    counted_breakdown: dict[str, int],
    notes: str | None,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> CashSession:
    session = sessions_repo.get(db, session_id)
    if session is None:
        raise NotFoundError(meta={"session_id": str(session_id)})
    if session.status == CashSessionStatus.CLOSED:
        raise SessionAlreadyClosedError(meta={"session_id": str(session_id)})

    blocking = sessions_repo.open_orders(db, session_id)
    if blocking:
        raise SessionHasOpenOrdersError(meta={"open_orders": [str(order.id) for order in blocking]})

    counted_cash_xof = sum(int(denom) * count for denom, count in counted_breakdown.items())
    expected_cash_xof = _expected_cash(db, session)
    variance_xof = counted_cash_xof - expected_cash_xof
    totals = _totals(db, session_id)
    z_number = next_value(db, f"z:{session.cash_register_id}")

    session.status = CashSessionStatus.CLOSED
    session.closed_by_user_id = actor_id
    session.closed_at = datetime.now(UTC)
    session.z_number = z_number
    session.counted_cash_xof = counted_cash_xof
    session.expected_cash_xof = expected_cash_xof
    session.variance_xof = variance_xof
    session.closing_breakdown = counted_breakdown
    session.totals_snapshot = totals.model_dump(mode="json")
    session.notes = notes

    audit_service.log(
        db,
        "cash_session.close",
        ctx=ctx,
        user_id=actor_id,
        entity="cash_session",
        entity_id=session.id,
        after={"z_number": z_number, "variance_xof": variance_xof},
    )
    db.commit()

    header = settings_repo.get_value(db, "receipt.header", {})
    footer = settings_repo.get_value(db, "receipt.footer", "")
    rendered = receipt_domain.render_z_report(
        z_number=z_number,
        business_date=str(session.business_date),
        opening_float_xof=session.opening_float_xof,
        gross_ttc_xof=totals.gross_ttc_xof,
        by_payment_method=[
            receipt_domain.PaymentMethodAmount(method=t.method, amount_xof=t.amount_xof)
            for t in totals.by_payment_method
        ],
        expected_cash_xof=expected_cash_xof,
        counted_cash_xof=counted_cash_xof,
        variance_xof=variance_xof,
        cancelled_orders=totals.controls.cancelled_orders,
        removed_items=totals.controls.removed_items,
        header_name=str(header.get("name") or ""),
        footer=str(footer or ""),
        width=get_settings().printer_width,
    )
    job = printing_service.enqueue(
        db,
        job_type=PrintJobType.Z_REPORT,
        rendered=rendered,
        open_drawer=False,
        session_id=session.id,
        user_id=actor_id,
    )
    session.print_job_id = job.id
    db.commit()
    return session


def z_report(db: Session, session_id: uuid.UUID) -> ZReportOut:
    session = sessions_repo.get(db, session_id)
    if session is None:
        raise NotFoundError(meta={"session_id": str(session_id)})
    if session.status != CashSessionStatus.CLOSED or session.totals_snapshot is None:
        raise SessionNotClosedError(meta={"session_id": str(session_id)})
    assert session.z_number is not None
    assert session.expected_cash_xof is not None
    assert session.counted_cash_xof is not None
    assert session.variance_xof is not None
    return ZReportOut(
        z_number=session.z_number,
        business_date=session.business_date,
        expected_cash_xof=session.expected_cash_xof,
        counted_cash_xof=session.counted_cash_xof,
        variance_xof=session.variance_xof,
        totals=SessionTotals.model_validate(session.totals_snapshot),
        print_job_id=session.print_job_id,
    )


def add_movement(
    db: Session,
    session_id: uuid.UUID,
    *,
    type: CashMovementType,
    amount_xof: int,
    reason: str,
    actor_id: uuid.UUID,
    ctx: RequestContext,
) -> CashMovement:
    session = sessions_repo.get(db, session_id)
    if session is None:
        raise NotFoundError(meta={"session_id": str(session_id)})
    if session.status != CashSessionStatus.OPEN:
        raise NoOpenSessionError(meta={"session_id": str(session_id)})

    movement = CashMovement(
        cash_session_id=session_id,
        type=type,
        amount_xof=amount_xof,
        reason=reason,
        user_id=actor_id,
    )
    db.add(movement)
    db.flush()
    audit_service.log(
        db,
        "cash_session.movement",
        ctx=ctx,
        user_id=actor_id,
        entity="cash_movement",
        entity_id=movement.id,
        after={"type": type, "amount_xof": amount_xof, "reason": reason},
    )
    db.commit()
    return movement


def reprint_z(
    db: Session, session_id: uuid.UUID, *, user_id: uuid.UUID, ctx: RequestContext
) -> PrintJob:
    """Duplicata du ticket Z **tel qu'imprimé à la clôture** (contenu stocké, jamais recalculé),
    marqué ré-impression et compté dans les contrôles."""
    session = sessions_repo.get(db, session_id)
    if session is None:
        raise NotFoundError(meta={"session_id": str(session_id)})
    if session.status != CashSessionStatus.CLOSED:
        raise SessionNotClosedError(meta={"session_id": str(session_id)})
    previous = db.get(PrintJob, session.print_job_id) if session.print_job_id else None
    if previous is None or not previous.rendered:
        raise NoReceiptToReprintError(meta={"session_id": str(session_id)})
    job = printing_service.enqueue(
        db,
        job_type=PrintJobType.Z_REPORT,
        rendered=previous.rendered,
        open_drawer=False,
        session_id=session.id,
        payload=previous.payload,
        is_reprint=True,
        user_id=user_id,
    )
    audit_service.log(
        db,
        "cash_session.reprint_z",
        ctx=ctx,
        user_id=user_id,
        entity="print_job",
        entity_id=job.id,
    )
    db.commit()
    return job

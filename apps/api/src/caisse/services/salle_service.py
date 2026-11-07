"""Espace salle : le service du serveur connecté (écran « Mon service »)."""

from datetime import datetime

from sqlalchemy import ColumnElement, or_
from sqlalchemy.orm import Session, joinedload

from caisse.domain.enums import OrderStatus, PaymentStatus
from caisse.domain.kitchen_rules import is_kitchen_line
from caisse.models.catalog import Product
from caisse.models.order import Order, OrderItem
from caisse.models.payment import Payment
from caisse.models.user import User
from caisse.repositories.sessions import CashSessionRepository
from caisse.schemas.salle import MyServiceEvent, MyServiceNote, MyServiceResponse

ACTIVE = (OrderStatus.OPEN, OrderStatus.PARTIALLY_PAID)
FEED_LIMIT = 40


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


class SalleService:
    def __init__(self, db: Session):
        self.db = db
        self.sessions = CashSessionRepository(db)

    def my_service(self, user: User) -> MyServiceResponse:
        register = self.sessions.get_or_create_default_register()
        active = self.sessions.get_active_by_register_id(register.id)
        # Caisse fermée : le dernier service (ce que le serveur a remis avant la clôture)
        session = active or self.sessions.get_latest_by_register_id(register.id)

        load = (
            joinedload(Order.table),
            joinedload(Order.items).joinedload(OrderItem.product).joinedload(Product.category),
            joinedload(Order.payments).joinedload(Payment.user),
        )
        # Ses notes en cours (quelle que soit la session) et celles de la session ouverte
        scope: ColumnElement[bool] = Order.status.in_(ACTIVE)
        if session:
            scope = or_(scope, Order.cash_session_id == session.id)
        orders = (
            self.db.query(Order)
            .options(*load)
            .filter(Order.served_by_user_id == user.id, scope)
            .order_by(Order.opened_at.asc())
            .all()
        )
        orders = list({o.id: o for o in orders}.values())

        open_notes = [self._note(o) for o in orders if o.status in ACTIVE]
        in_session = [o for o in orders if session and o.cash_session_id == session.id]

        handed = self.db.query(Payment).filter(
            Payment.handed_by_user_id == user.id,
            Payment.status == PaymentStatus.CAPTURED,
        )
        handed_xof = (
            sum(p.amount_xof for p in handed.filter(Payment.cash_session_id == session.id).all())
            if session
            else 0
        )

        feed: list[MyServiceEvent] = []
        for o in in_session:
            feed.extend(self._dispatch_events(o))
            if o.bill_requested_at:
                feed.append(self._event(o, "BILL_REQUESTED", o.bill_requested_at, amount_xof=o.due_xof))
            for p in o.payments:
                if p.status == PaymentStatus.CAPTURED:
                    feed.append(
                        self._event(
                            o,
                            "PAID",
                            p.created_at,
                            amount_xof=p.amount_xof,
                            method=p.method,
                            cashier_name=p.user.full_name if p.user else None,
                        )
                    )
        feed.sort(key=lambda e: e.at, reverse=True)

        starts = [o.opened_at for o in in_session if o.opened_at] + [
            it.added_at for o in in_session for it in o.items if it.dispatch_no and it.added_at
        ]
        return MyServiceResponse(
            caisse_open=active is not None,
            business_date=session.business_date if session else None,
            started_at=_iso(min(starts)) if starts else None,
            handed_xof=handed_xof,
            settled_notes_count=sum(1 for o in in_session if o.status == OrderStatus.PAID),
            open_xof=sum(n.due_xof for n in open_notes),
            open_notes=open_notes,
            feed=feed[:FEED_LIMIT],
        )

    @staticmethod
    def _note(o: Order) -> MyServiceNote:
        return MyServiceNote(
            order_id=o.id,
            order_number=o.order_number,
            service_mode=o.service_mode,  # type: ignore[arg-type]
            table_id=o.table_id,
            table_label=o.table.label if o.table else None,
            note_label=o.note_label,
            guests_count=o.guests_count,
            total_ttc_xof=o.total_ttc_xof,
            due_xof=o.due_xof,
            dispatch_count=o.dispatch_count,
            bill_requested_at=_iso(o.bill_requested_at),
            opened_at=_iso(o.opened_at) or "",
        )

    @staticmethod
    def _event(o: Order, kind: str, at: datetime, **extra: object) -> MyServiceEvent:
        return MyServiceEvent(
            kind=kind,  # type: ignore[arg-type]
            at=at.isoformat(),
            order_id=o.id,
            order_number=o.order_number,
            service_mode=o.service_mode,  # type: ignore[arg-type]
            table_label=o.table.label if o.table else None,
            note_label=o.note_label,
            **extra,  # type: ignore[arg-type]
        )

    def _dispatch_events(self, o: Order) -> list[MyServiceEvent]:
        by_dispatch: dict[int, list[OrderItem]] = {}
        for it in o.items:
            if it.dispatch_no and not it.removed_at:
                by_dispatch.setdefault(it.dispatch_no, []).append(it)
        events = []
        for no, items in sorted(by_dispatch.items()):
            kitchen = sum(
                it.quantity
                for it in items
                if is_kitchen_line(it.product.category.kind if it.product and it.product.category else None)
            )
            total = sum(it.quantity for it in items)
            events.append(
                self._event(
                    o,
                    "DISPATCH",
                    min(it.added_at for it in items),
                    dispatch_no=no,
                    kitchen_count=kitchen,
                    drinks_count=total - kitchen,
                )
            )
        return events

from datetime import datetime, timezone
from typing import Any

from fastapi import status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from caisse import idempotency
from caisse.domain.session_rules import (
    calculate_counted_cash,
    calculate_variance,
    validate_business_date,
    validate_opening_float,
)
from caisse.errors import CaisseException
from caisse.infrastructure.websocket.manager import ws_manager
from caisse.models.cash_session import CashMovement, CashSession
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.repositories.sessions import CashSessionRepository
from caisse.repositories.users import UserRepository
from caisse.schemas.sessions import (
    CashMovementResponse,
    CashSessionResponse,
    ItemSalesDetail,
    XReportResponse,
    ZReportResponse,
)
from caisse.services.audit_service import AuditService
from caisse.services.printing_service import PrintingService


class CashSessionService:
    def __init__(self, db: Session):
        self.db = db
        self.repo = CashSessionRepository(db)
        self.user_repo = UserRepository(db)
        self.printing_service = PrintingService(db)
        self.audit = AuditService(db)

    def get_current_session(self, register_id: str | None = None) -> CashSessionResponse:
        session = self.repo.get_active_by_register_id(register_id)
        if not session:
            raise CaisseException(
                code="NO_OPEN_SESSION",
                title="Aucune session de caisse ouverte",
                detail="Veuillez ouvrir une session de caisse avec un fonds initial pour commencer les ventes.",
                status_code=status.HTTP_409_CONFLICT,
            )

        return self._to_session_response(session)

    def open_session(
        self,
        cash_register_id: str,
        opening_float_xof: int,
        business_date_str: str,
        user_id: str,
        device_id: str | None = None,
        idempotency_key: str | None = None,
        path: str = "",
        payload: Any = None,
    ) -> tuple[CashSessionResponse, bool]:
        request_hash = idempotency.hash_request(payload)
        if idempotency_key:
            replay = idempotency.find_replay(
                self.db, idempotency_key, method="POST", path=path, request_hash=request_hash
            )
            if replay is not None:
                return CashSessionResponse.model_validate(replay), True

        b_date = validate_business_date(business_date_str)
        validate_opening_float(opening_float_xof)

        # S'assurer que le poste de caisse existe
        from caisse.models.cash_session import CashRegister
        register = self.db.query(CashRegister).filter(CashRegister.id == cash_register_id).first()
        if not register:
            register = CashRegister(
                id=cash_register_id,
                name=f"Caisse {cash_register_id.upper()}",
                is_active=True,
            )
            self.db.add(register)
            self.db.flush()

        active = self.repo.get_active_by_register_id(cash_register_id)
        if active:
            raise CaisseException(
                code="SESSION_ALREADY_OPEN",
                title="Session déjà ouverte",
                detail=f"Une session de caisse ({active.id}) est déjà ouverte pour cette caisse.",
                status_code=status.HTTP_409_CONFLICT,
                meta={"session_id": active.id},
            )

        session = CashSession(
            cash_register_id=cash_register_id,
            opened_by_user_id=user_id,
            business_date=b_date,
            status="OPEN",
            opening_float_xof=opening_float_xof,
            opened_at=datetime.now(timezone.utc),
        )
        created = self.repo.add(session)

        self.audit.log(
            action="SESSION_OPENED",
            entity="CASH_SESSION",
            entity_id=created.id,
            user_id=user_id,
            after={"opening_float_xof": opening_float_xof, "business_date": business_date_str},
            device_id=device_id,
        )

        resp = self._to_session_response(created)

        if idempotency_key:
            idempotency.save(
                self.db,
                idempotency_key,
                method="POST",
                path=path,
                request_hash=request_hash,
                status=201,
                body=resp.model_dump(mode="json"),
                user_id=user_id,
            )

        try:
            self.db.commit()
        except IntegrityError:
            self.db.rollback()
            if idempotency_key:
                replay = idempotency.find_replay(
                    self.db, idempotency_key, method="POST", path=path, request_hash=request_hash
                )
                if replay is not None:
                    return CashSessionResponse.model_validate(replay), True
            raise

        ws_manager.broadcast_sync(
            "SESSION_OPENED",
            {
                "session_id": created.id,
                "cash_register_id": created.cash_register_id,
                "business_date": str(created.business_date),
            },
        )

        return resp, False

    def add_movement(
        self,
        session_id: str,
        movement_type: str,
        amount_xof: int,
        reason: str,
        user_id: str,
        device_id: str | None = None,
    ) -> CashMovementResponse:
        session = self.repo.get_by_id(session_id)
        if not session or session.status != "OPEN":
            raise CaisseException(
                code="SESSION_NOT_OPEN",
                title="Session non ouverte",
                detail="Impossible d'ajouter un mouvement sur une session fermée ou inexistante.",
                status_code=status.HTTP_409_CONFLICT,
            )

        if amount_xof <= 0:
            raise CaisseException(
                code="INVALID_AMOUNT",
                title="Montant invalide",
                detail="Le montant du mouvement doit être supérieur à 0 XOF.",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )

        movement = CashMovement(
            cash_session_id=session_id,
            user_id=user_id,
            type=movement_type,
            amount_xof=amount_xof,
            reason=reason,
        )
        created = self.repo.add_movement(movement)

        user = self.user_repo.get_by_id(user_id)
        user_name = user.full_name if user else "Utilisateur"

        self.audit.log(
            action=f"CASH_MOVEMENT_{movement_type}",
            entity="CASH_MOVEMENT",
            entity_id=created.id,
            user_id=user_id,
            after={"type": movement_type, "amount_xof": amount_xof, "reason": reason},
            device_id=device_id,
        )
        self.db.commit()

        ws_manager.broadcast_sync(
            "CASH_MOVEMENT",
            {
                "session_id": created.cash_session_id,
                "type": created.type,
                "amount_xof": created.amount_xof,
            },
        )

        return CashMovementResponse(
            id=created.id,
            cash_session_id=created.cash_session_id,
            type=created.type,
            amount_xof=created.amount_xof,
            reason=created.reason,
            user_name=user_name,
            created_at=created.created_at.isoformat(),
        )

    def get_x_report(self, session_id: str) -> XReportResponse:
        session = self.repo.get_by_id(session_id)
        if not session:
            raise CaisseException(
                code="SESSION_NOT_FOUND",
                title="Session introuvable",
                detail=f"Aucune session de caisse avec l'ID {session_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        # 1. Mouvements de caisse
        in_xof = sum(m.amount_xof for m in session.movements if m.type == "IN")
        out_xof = sum(m.amount_xof for m in session.movements if m.type == "OUT")

        # 2. Commandes de la session
        orders = self.db.query(Order).filter(Order.cash_session_id == session_id).all()
        settled_orders = [o for o in orders if o.status == "PAID"]
        cancelled_orders = [o for o in orders if o.status == "CANCELLED"]

        total_sales_ttc = sum(o.total_ttc_xof for o in settled_orders)
        total_sales_ht = sum(o.total_ht_xof for o in settled_orders)
        total_sales_vat = sum(o.total_vat_xof for o in settled_orders)

        # 3. Règlements par méthode
        payments = (
            self.db.query(Payment)
            .filter(Payment.cash_session_id == session_id, Payment.status == "CAPTURED")
            .all()
        )
        payments_by_method: dict[str, int] = {}
        for p in payments:
            payments_by_method[p.method] = payments_by_method.get(p.method, 0) + p.amount_xof

        cash_sales = payments_by_method.get("CASH", 0)

        # 4. Ventes par catégorie et par article
        sales_by_category: dict[str, int] = {}
        items_map: dict[str, dict[str, Any]] = {}

        for o in settled_orders:
            for item in o.items:
                if item.removed_at is None:
                    cat = item.category_snapshot or "Autre"
                    sales_by_category[cat] = sales_by_category.get(cat, 0) + item.line_total_xof

                    p_name = item.product_name_snapshot
                    if p_name not in items_map:
                        items_map[p_name] = {
                            "product_name": p_name,
                            "category": cat,
                            "quantity": 0,
                            "unit_price_xof": item.unit_price_xof,
                            "total_ttc_xof": 0,
                        }
                    items_map[p_name]["quantity"] += item.quantity
                    items_map[p_name]["total_ttc_xof"] += item.line_total_xof

        sales_by_item = [
            ItemSalesDetail(**data)
            for data in sorted(items_map.values(), key=lambda x: x["total_ttc_xof"], reverse=True)
        ]

        # 5. Espèces théoriques dans le tiroir = Fonds d'ouverture + Ventes espèces + Entrées - Sorties
        expected_cash_xof = session.opening_float_xof + cash_sales + in_xof - out_xof

        return XReportResponse(
            cash_session_id=session.id,
            business_date=session.business_date.isoformat(),
            opened_at=session.opened_at.isoformat(),
            opening_float_xof=session.opening_float_xof,
            total_sales_ttc_xof=total_sales_ttc,
            total_sales_ht_xof=total_sales_ht,
            total_sales_vat_xof=total_sales_vat,
            payments_by_method=payments_by_method,
            sales_by_category=sales_by_category,
            sales_by_item=sales_by_item,
            cash_movements_in_xof=in_xof,
            cash_movements_out_xof=out_xof,
            expected_cash_in_drawer_xof=expected_cash_xof,
            orders_count=len(settled_orders),
            cancelled_orders_count=len(cancelled_orders),
        )

    def close_session(
        self,
        session_id: str,
        counted_breakdown: dict[str, int],
        user_id: str,
        notes: str | None = None,
        device_id: str | None = None,
        idempotency_key: str | None = None,
        path: str = "",
        payload: Any = None,
    ) -> tuple[CashSessionResponse, bool]:
        request_hash = idempotency.hash_request(payload)
        if idempotency_key:
            replay = idempotency.find_replay(
                self.db, idempotency_key, method="POST", path=path, request_hash=request_hash
            )
            if replay is not None:
                return CashSessionResponse.model_validate(replay), True

        session = self.repo.get_by_id(session_id)
        if not session or session.status != "OPEN":
            raise CaisseException(
                code="SESSION_NOT_OPEN",
                title="Session non ouverte",
                detail="Cette session est déjà clôturée ou inexistante.",
                status_code=status.HTTP_409_CONFLICT,
            )

        # 1. Vérification stricte : aucune commande non soldée
        unsettled_count = self.repo.count_unsettled_orders(session_id)
        if unsettled_count > 0:
            raise CaisseException(
                code="UNSETTLED_ORDERS_REMAIN",
                title="Commandes non soldées",
                detail=f"Impossible de clôturer la session : {unsettled_count} commande(s) sont encore en cours ou partiellement payées.",
                status_code=status.HTTP_409_CONFLICT,
                meta={"unsettled_count": unsettled_count},
            )

        # 2. Calcul du rapport X temps réel complet
        x_rep = self.get_x_report(session_id)

        # 3. Calcul du montant compté et écart
        counted_cash_xof = calculate_counted_cash(counted_breakdown)
        expected_cash_xof = x_rep.expected_cash_in_drawer_xof
        variance_xof = calculate_variance(expected_cash_xof, counted_cash_xof)

        # 4. Attribution du Z-number séquentiel
        z_num = self.repo.get_next_z_number(session.cash_register_id)

        totals_snapshot: dict[str, Any] = {
            "z_number": z_num,
            "opening_float_xof": session.opening_float_xof,
            "total_sales_ttc_xof": x_rep.total_sales_ttc_xof,
            "total_sales_ht_xof": x_rep.total_sales_ht_xof,
            "total_sales_vat_xof": x_rep.total_sales_vat_xof,
            "payments_by_method": x_rep.payments_by_method,
            "sales_by_category": x_rep.sales_by_category,
            "sales_by_item": [item.model_dump() for item in x_rep.sales_by_item],
            "cash_movements_in_xof": x_rep.cash_movements_in_xof,
            "cash_movements_out_xof": x_rep.cash_movements_out_xof,
            "expected_cash_xof": expected_cash_xof,
            "counted_cash_xof": counted_cash_xof,
            "variance_xof": variance_xof,
            "closing_breakdown": counted_breakdown,
            "orders_count": x_rep.orders_count,
            "cancelled_orders_count": x_rep.cancelled_orders_count,
        }

        session.status = "CLOSED"
        session.closed_at = datetime.now(timezone.utc)
        session.closed_by_user_id = user_id
        session.z_number = z_num
        session.counted_cash_xof = counted_cash_xof
        session.expected_cash_xof = expected_cash_xof
        session.variance_xof = variance_xof
        session.closing_breakdown = counted_breakdown
        session.totals_snapshot = totals_snapshot
        session.notes = notes

        self.audit.log(
            action="SESSION_CLOSED",
            entity="CASH_SESSION",
            entity_id=session.id,
            user_id=user_id,
            after={
                "z_number": z_num,
                "counted_cash_xof": counted_cash_xof,
                "expected_cash_xof": expected_cash_xof,
                "variance_xof": variance_xof,
            },
            device_id=device_id,
        )

        resp = self._to_session_response(session)

        if idempotency_key:
            idempotency.save(
                self.db,
                idempotency_key,
                method="POST",
                path=path,
                request_hash=request_hash,
                status=200,
                body=resp.model_dump(mode="json"),
                user_id=user_id,
            )

        try:
            self.db.commit()
        except IntegrityError:
            self.db.rollback()
            if idempotency_key:
                replay = idempotency.find_replay(
                    self.db, idempotency_key, method="POST", path=path, request_hash=request_hash
                )
                if replay is not None:
                    return CashSessionResponse.model_validate(replay), True
            raise

        ws_manager.broadcast_sync(
            "SESSION_CLOSED",
            {
                "session_id": session.id,
                "z_number": session.z_number,
                "variance_xof": session.variance_xof,
            },
        )

        return resp, False

    def get_z_report(self, session_id: str) -> ZReportResponse:
        session = self.repo.get_by_id(session_id)
        if not session:
            raise CaisseException(
                code="SESSION_NOT_FOUND",
                title="Session introuvable",
                detail=f"Aucune session de caisse avec l'ID {session_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if session.status != "CLOSED" or not session.totals_snapshot:
            raise CaisseException(
                code="SESSION_NOT_CLOSED",
                title="Session non clôturée",
                detail="Le rapport Z définitif n'est disponible qu'après clôture de la session.",
                status_code=status.HTTP_409_CONFLICT,
            )

        snap = session.totals_snapshot
        return ZReportResponse(
            z_number=session.z_number or 0,
            cash_session_id=session.id,
            business_date=session.business_date.isoformat(),
            opened_at=session.opened_at.isoformat(),
            closed_at=session.closed_at.isoformat() if session.closed_at else "",
            opening_float_xof=snap.get("opening_float_xof", 0),
            total_sales_ttc_xof=snap.get("total_sales_ttc_xof", 0),
            total_sales_ht_xof=snap.get("total_sales_ht_xof", 0),
            total_sales_vat_xof=snap.get("total_sales_vat_xof", 0),
            payments_by_method=snap.get("payments_by_method", {}),
            sales_by_category=snap.get("sales_by_category", {}),
            sales_by_item=[ItemSalesDetail(**it) for it in snap.get("sales_by_item", [])],
            cash_movements_in_xof=snap.get("cash_movements_in_xof", 0),
            cash_movements_out_xof=snap.get("cash_movements_out_xof", 0),
            expected_cash_in_drawer_xof=snap.get("expected_cash_xof", 0),
            counted_cash_xof=snap.get("counted_cash_xof", 0),
            variance_xof=snap.get("variance_xof", 0),
            closing_breakdown=snap.get("closing_breakdown", {}),
            orders_count=snap.get("orders_count", 0),
            cancelled_orders_count=snap.get("cancelled_orders_count", 0),
            notes=session.notes,
        )

    def _to_session_response(self, session: CashSession) -> CashSessionResponse:
        return CashSessionResponse(
            id=session.id,
            cash_register_id=session.cash_register_id,
            business_date=session.business_date.isoformat(),
            status=session.status,  # type: ignore
            opening_float_xof=session.opening_float_xof,
            opened_at=session.opened_at.isoformat(),
            closed_at=session.closed_at.isoformat() if session.closed_at else None,
            z_number=session.z_number,
            expected_cash_xof=session.expected_cash_xof,
            counted_cash_xof=session.counted_cash_xof,
            variance_xof=session.variance_xof,
            totals_snapshot=session.totals_snapshot,
        )

    def list_history(self, register_id: str | None = None, page: Any = None) -> list[CashSession]:
        return self.repo.list_history(register_id=register_id, page=page)

from datetime import datetime, timezone

from fastapi import status
from sqlalchemy.orm import Session

from caisse.domain.order_rules import (
    assert_order_editable,
    calculate_line_total,
    generate_order_number,
    recalculate_order_totals,
)
from caisse.errors import CaisseException
from caisse.infrastructure.websocket.manager import ws_manager
from caisse.models.order import Order, OrderItem
from caisse.repositories.catalog import CatalogRepository
from caisse.repositories.orders import OrderRepository
from caisse.repositories.sessions import CashSessionRepository
from caisse.repositories.tables import TableRepository
from caisse.schemas.orders import (
    OrderCancelRequest,
    OrderCreateRequest,
    OrderItemAddRequest,
    OrderItemRemoveRequest,
    OrderItemResponse,
    OrderResponse,
)
from caisse.services.audit_service import AuditService


class OrderService:
    def __init__(self, db: Session):
        self.db = db
        self.order_repo = OrderRepository(db)
        self.catalog_repo = CatalogRepository(db)
        self.table_repo = TableRepository(db)
        self.session_repo = CashSessionRepository(db)
        self.audit = AuditService(db)

    def create_order(
        self,
        payload: OrderCreateRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> OrderResponse:
        register = self.session_repo.get_or_create_default_register()
        active_session = self.session_repo.get_active_by_register_id(register.id)
        if not active_session:
            raise CaisseException(
                code="NO_OPEN_SESSION",
                title="Session de caisse fermée",
                detail="Impossible de créer une commande sans session de caisse ouverte.",
                status_code=status.HTTP_409_CONFLICT,
            )

        table_label = None
        note_label = payload.note_label
        if payload.table_id:
            table = self.table_repo.get_by_id(payload.table_id)
            if not table:
                raise CaisseException(
                    code="TABLE_NOT_FOUND",
                    title="Table introuvable",
                    detail=f"Aucune table trouvée avec l'ID {payload.table_id}.",
                    status_code=status.HTTP_404_NOT_FOUND,
                )
            table_label = table.label

            existing_active_orders = self.order_repo.get_active_orders_by_table_id(payload.table_id)
            if existing_active_orders:
                if not payload.allow_multiple and not payload.note_label:
                    existing_active_order = existing_active_orders[0]
                    raise CaisseException(
                        code="TABLE_ALREADY_OCCUPIED",
                        title="Table déjà occupée",
                        detail=f"La {table.label} a déjà une commande en cours ({existing_active_order.order_number}).",
                        status_code=status.HTTP_409_CONFLICT,
                        meta={"order_id": existing_active_order.id, "order_number": existing_active_order.order_number},
                    )
                if not note_label:
                    note_label = f"Note {len(existing_active_orders) + 1}"
            else:
                if not note_label:
                    note_label = "Note 1"

        b_date_str = active_session.business_date.isoformat()
        seq_num = self.order_repo.get_next_daily_sequence(b_date_str)
        order_number = generate_order_number(b_date_str, seq_num)
        while self.db.query(Order.id).filter(Order.order_number == order_number).first():
            seq_num += 1
            order_number = generate_order_number(b_date_str, seq_num)

        order = Order(
            order_number=order_number,
            cash_session_id=active_session.id,
            table_id=payload.table_id,
            note_label=note_label,
            status="OPEN",
            opened_by_user_id=user_id,
            guests_count=payload.guests_count,
            total_ttc_xof=0,
            total_ht_xof=0,
            total_vat_xof=0,
            paid_xof=0,
            due_xof=0,
            opened_at=datetime.now(timezone.utc),
        )
        created = self.order_repo.add(order)

        self.audit.log(
            action="ORDER_CREATED",
            entity="ORDER",
            entity_id=created.id,
            user_id=user_id,
            after={"order_number": order_number, "table_id": payload.table_id, "guests_count": payload.guests_count},
            device_id=device_id,
        )
        self.db.commit()

        ws_manager.broadcast_sync(
            "ORDER_CREATED",
            {
                "order_id": created.id,
                "order_number": created.order_number,
                "table_id": created.table_id,
                "total_ttc_xof": created.total_ttc_xof,
                "status": created.status,
            },
        )

        return self._to_order_response(created, table_label=table_label)

    def list_orders(
        self,
        session_id: str | None = None,
        status: str | None = None,
        limit: int = 50,
    ) -> list[OrderResponse]:
        orders = self.order_repo.list_orders(session_id=session_id, status=status, limit=limit)
        return [self._to_order_response(o) for o in orders]

    def get_order(self, order_id: str) -> OrderResponse:
        order = self.order_repo.get_by_id_with_items(order_id)
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande trouvée avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return self._to_order_response(order)

    def add_item(
        self,
        order_id: str,
        payload: OrderItemAddRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> OrderResponse:
        order = self.order_repo.get_by_id_with_items(order_id)
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande trouvée avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        assert_order_editable(order.status)

        if payload.product_id:
            product = self.catalog_repo.get_product_by_id(payload.product_id)
            if not product:
                raise CaisseException(
                    code="PRODUCT_NOT_FOUND",
                    title="Produit introuvable",
                    detail=f"Produit ID {payload.product_id} non trouvé.",
                    status_code=status.HTTP_404_NOT_FOUND,
                )
            name_snapshot = product.name
            category_snapshot = product.category.name if product.category else "Menu"
            unit_price = product.price_xof
            vat_rate = float(product.vat_rate)
        elif payload.custom_name and payload.unit_price_xof is not None:
            name_snapshot = payload.custom_name
            category_snapshot = "Hors Menu"
            unit_price = payload.unit_price_xof
            vat_rate = 0.00
        else:
            raise CaisseException(
                code="INVALID_ITEM_SPECIFICATION",
                title="Produit non spécifié",
                detail="Veuillez fournir un product_id valide ou (custom_name et unit_price_xof).",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )

        line_total = calculate_line_total(unit_price, payload.quantity)

        item = OrderItem(
            order_id=order.id,
            product_id=payload.product_id,
            product_name_snapshot=name_snapshot,
            category_snapshot=category_snapshot,
            unit_price_xof=unit_price,
            quantity=payload.quantity,
            vat_rate=vat_rate,
            line_total_xof=line_total,
            note=payload.note,
            added_by_user_id=user_id,
            added_at=datetime.now(timezone.utc),
        )
        self.order_repo.add_item(item)
        order.items.append(item)

        # Recalcul des totaux de commande
        ttc, ht, vat = recalculate_order_totals(order.items)
        order.total_ttc_xof = ttc
        order.total_ht_xof = ht
        order.total_vat_xof = vat
        order.due_xof = ttc - order.paid_xof

        self.audit.log(
            action="ORDER_ITEM_ADDED",
            entity="ORDER_ITEM",
            entity_id=item.id,
            user_id=user_id,
            after={"name": name_snapshot, "quantity": payload.quantity, "line_total_xof": line_total},
            device_id=device_id,
        )
        self.db.commit()

        ws_manager.broadcast_sync(
            "ORDER_UPDATED",
            {
                "order_id": order.id,
                "order_number": order.order_number,
                "table_id": order.table_id,
                "total_ttc_xof": order.total_ttc_xof,
                "status": order.status,
            },
        )

        return self._to_order_response(order)

    def remove_item(
        self,
        order_id: str,
        item_id: str,
        payload: OrderItemRemoveRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> OrderResponse:
        order = self.order_repo.get_by_id_with_items(order_id)
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        assert_order_editable(order.status)

        item = self.order_repo.get_item_by_id(item_id)
        if not item or item.order_id != order.id:
            raise CaisseException(
                code="ITEM_NOT_FOUND",
                title="Ligne de commande introuvable",
                detail=f"Aucune ligne {item_id} dans la commande {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if item.removed_at is not None:
            raise CaisseException(
                code="ITEM_ALREADY_REMOVED",
                title="Ligne déjà retirée",
                detail="Cette ligne a déjà été retirée de la commande.",
                status_code=status.HTTP_409_CONFLICT,
            )

        # Tracé du retrait sans suppression physique (immuabilité)
        item.removed_at = datetime.now(timezone.utc)
        item.removed_by_user_id = user_id
        item.removal_reason = payload.reason

        # Recalcul des totaux
        ttc, ht, vat = recalculate_order_totals(order.items)
        order.total_ttc_xof = ttc
        order.total_ht_xof = ht
        order.total_vat_xof = vat
        order.due_xof = ttc - order.paid_xof

        self.audit.log(
            action="ORDER_ITEM_REMOVED",
            entity="ORDER_ITEM",
            entity_id=item.id,
            user_id=user_id,
            reason=payload.reason,
            device_id=device_id,
        )
        self.db.commit()

        ws_manager.broadcast_sync(
            "ORDER_UPDATED",
            {
                "order_id": order.id,
                "order_number": order.order_number,
                "table_id": order.table_id,
                "total_ttc_xof": order.total_ttc_xof,
                "status": order.status,
            },
        )

        return self._to_order_response(order)

    def cancel_order(
        self,
        order_id: str,
        payload: OrderCancelRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> OrderResponse:
        order = self.order_repo.get_by_id_with_items(order_id)
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        assert_order_editable(order.status)

        order.status = "CANCELLED"
        order.cancelled_reason = payload.reason
        order.cancelled_by_user_id = user_id
        order.cancelled_at = datetime.now(timezone.utc)

        self.audit.log(
            action="ORDER_CANCELLED",
            entity="ORDER",
            entity_id=order.id,
            user_id=user_id,
            reason=payload.reason,
            device_id=device_id,
        )
        self.db.commit()

        ws_manager.broadcast_sync(
            "ORDER_CANCELLED",
            {
                "order_id": order.id,
                "order_number": order.order_number,
                "table_id": order.table_id,
                "status": order.status,
            },
        )

        return self._to_order_response(order)

    def _to_order_response(self, order: Order, table_label: str | None = None) -> OrderResponse:
        items_responses = []
        for it in order.items:
            items_responses.append(
                OrderItemResponse(
                    id=it.id,
                    product_id=it.product_id,
                    product_name_snapshot=it.product_name_snapshot,
                    category_snapshot=it.category_snapshot,
                    unit_price_xof=it.unit_price_xof,
                    quantity=it.quantity,
                    vat_rate=float(it.vat_rate),
                    line_total_xof=it.line_total_xof,
                    note=it.note,
                    added_at=it.added_at.isoformat(),
                    removed_at=it.removed_at.isoformat() if it.removed_at else None,
                    removal_reason=it.removal_reason,
                )
            )

        resolved_table_label = table_label or (order.table.label if order.table else "Comptoir")

        return OrderResponse(
            id=order.id,
            order_number=order.order_number,
            cash_session_id=order.cash_session_id,
            table_id=order.table_id,
            table_label=resolved_table_label,
            note_label=order.note_label,
            status=order.status,  # type: ignore
            guests_count=order.guests_count,
            total_ttc_xof=order.total_ttc_xof,
            total_ht_xof=order.total_ht_xof,
            total_vat_xof=order.total_vat_xof,
            paid_xof=order.paid_xof,
            due_xof=order.due_xof,
            items=items_responses,
            opened_at=order.opened_at.isoformat(),
            paid_at=order.paid_at.isoformat() if order.paid_at else None,
            cancelled_reason=order.cancelled_reason,
        )

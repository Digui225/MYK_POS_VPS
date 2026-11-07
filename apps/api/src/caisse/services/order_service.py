from datetime import date, datetime, timedelta, timezone

from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.errors import CaisseException
from caisse.core.pagination import PageRequest, split
from caisse.domain.enums import OrderStatus, PaymentStatus, ServiceMode, UserRole
from caisse.domain.kitchen_rules import KitchenLine, KitchenTicket, is_kitchen_line
from caisse.domain.order_rules import (
    assert_order_editable,
    calculate_line_total,
    generate_order_number,
    recalculate_order_totals,
)
from caisse.domain.split_rules import split_by_seat
from caisse.infrastructure.websocket.manager import ws_manager
from caisse.models.order import Order, OrderItem
from caisse.models.user import User
from caisse.repositories.catalog import CatalogRepository
from caisse.repositories.orders import OrderRepository
from caisse.repositories.sessions import CashSessionRepository
from caisse.repositories.tables import TableRepository
from caisse.schemas.orders import (
    BestSellerResponse,
    OrderCancelRequest,
    OrderCreateRequest,
    OrderDispatchRequest,
    OrderDispatchResponse,
    OrderItemAddRequest,
    OrderItemRemoveRequest,
    OrderItemResponse,
    OrderResponse,
)
from caisse.services.audit_service import AuditService
from caisse.services.printing_service import PrintingService


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
        served_by_user_id: str | None = None,
    ) -> OrderResponse:
        service_mode = payload.service_mode or (
            ServiceMode.SUR_PLACE if payload.table_id else ServiceMode.EMPORTER
        )
        if (service_mode == ServiceMode.SUR_PLACE) != bool(payload.table_id):
            raise CaisseException(
                code="INVALID_SERVICE_MODE",
                title="Mode de service incohérent",
                detail="Une commande sur place se prend sur une table ; à emporter et livraison, sans table.",
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            )
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

        order_number = self._next_order_number(active_session.business_date.isoformat())

        order = Order(
            order_number=order_number,
            cash_session_id=active_session.id,
            table_id=payload.table_id,
            note_label=note_label,
            status="OPEN",
            service_mode=service_mode,
            opened_by_user_id=user_id,
            served_by_user_id=served_by_user_id,
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
            after={
                "order_number": order_number,
                "table_id": payload.table_id,
                "guests_count": payload.guests_count,
                "service_mode": str(service_mode),
                "served_by_user_id": served_by_user_id,
            },
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
        *,
        page: PageRequest,
        session_id: str | None = None,
        status: str | None = None,
        business_date: date | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        order_type: str | None = None,
        search: str | None = None,
    ) -> tuple[list[OrderResponse], str | None]:
        rows = self.order_repo.list_orders(
            session_id=session_id,
            status=status,
            business_date=business_date,
            date_from=date_from,
            date_to=date_to,
            order_type=order_type,
            search=search,
            page=page,
        )
        items, next_cursor = split(rows, page, lambda o: (o.opened_at, o.id))
        return [self._to_order_response(o) for o in items], next_cursor

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

    def _get_editable_order(self, order_id: str) -> Order:
        order = self.order_repo.get_by_id_with_items(order_id)
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande trouvée avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        assert_order_editable(order.status)
        return order

    def _build_item(
        self, order: Order, payload: OrderItemAddRequest, user_id: str
    ) -> tuple[OrderItem, str | None]:
        """Ligne prête à ajouter (non validée) et type de sa catégorie (FOOD, DRINK…)."""
        category_kind: str | None = None
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
            category_kind = product.category.kind if product.category else None
            unit_price = product.price_xof
            vat_rate = float(product.vat_rate)
        elif payload.custom_name and payload.unit_price_xof is not None:
            name_snapshot = payload.custom_name
            if payload.category_id:
                cat_obj = self.catalog_repo.get_category_by_id(payload.category_id)
                category_snapshot = cat_obj.name if cat_obj else (payload.category_name or "Hors Menu")
                category_kind = cat_obj.kind if cat_obj else None
            elif payload.category_name:
                category_snapshot = payload.category_name
            else:
                category_snapshot = "Hors Menu"
            unit_price = payload.unit_price_xof
            vat_rate = 0.00
        else:
            raise CaisseException(
                code="INVALID_ITEM_SPECIFICATION",
                title="Produit non spécifié",
                detail="Veuillez fournir un product_id valide ou (custom_name et unit_price_xof).",
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            )

        # Normalisation automatique des ligatures et espaces pour éviter les doublons typographiques
        name_snapshot = name_snapshot.replace("œ", "oe").replace("Œ", "OE").strip()

        item = OrderItem(
            order_id=order.id,
            product_id=payload.product_id,
            product_name_snapshot=name_snapshot,
            category_snapshot=category_snapshot,
            unit_price_xof=unit_price,
            quantity=payload.quantity,
            vat_rate=vat_rate,
            line_total_xof=calculate_line_total(unit_price, payload.quantity),
            note=payload.note,
            seat=payload.seat,
            added_by_user_id=user_id,
            added_at=datetime.now(timezone.utc),
        )
        self.order_repo.add_item(item)
        order.items.append(item)
        return item, category_kind

    def _refresh_totals(self, order: Order) -> None:
        ttc, ht, vat = recalculate_order_totals(order.items)
        order.total_ttc_xof = ttc
        order.total_ht_xof = ht
        order.total_vat_xof = vat
        order.due_xof = ttc - order.paid_xof

    def broadcast_order_updated(self, order: Order, **extra: object) -> None:
        ws_manager.broadcast_sync(
            "ORDER_UPDATED",
            {
                "order_id": order.id,
                "order_number": order.order_number,
                "table_id": order.table_id,
                "total_ttc_xof": order.total_ttc_xof,
                "status": order.status,
                **extra,
            },
        )

    def add_item(
        self,
        order_id: str,
        payload: OrderItemAddRequest,
        user_id: str,
        device_id: str | None = None,
    ) -> OrderResponse:
        order = self._get_editable_order(order_id)
        item, _kind = self._build_item(order, payload, user_id)
        self._refresh_totals(order)

        self.audit.log(
            action="ORDER_ITEM_ADDED",
            entity="ORDER_ITEM",
            entity_id=item.id,
            user_id=user_id,
            after={"name": item.product_name_snapshot, "quantity": payload.quantity, "line_total_xof": item.line_total_xof},
            device_id=device_id,
        )
        self.db.commit()
        self.broadcast_order_updated(order)
        return self._to_order_response(order)

    def dispatch(
        self,
        order_id: str,
        payload: OrderDispatchRequest,
        user: User,
        device_id: str | None = None,
    ) -> tuple[Order, OrderDispatchResponse]:
        """Envoi en cuisine : lignes, n° d'envoi et bon cuisine (boissons exclues) dans une
        seule transaction. NE VALIDE PAS : l'appelant enregistre la clé d'idempotence puis valide,
        et diffuse ensuite (broadcast_order_updated)."""
        order = self._get_editable_order(order_id)
        dispatch_no = order.dispatch_count + 1

        kitchen_lines: list[KitchenLine] = []
        added: list[OrderItem] = []
        for line in payload.items:
            item, kind = self._build_item(order, line, user.id)
            item.dispatch_no = dispatch_no
            added.append(item)
            if is_kitchen_line(kind):
                kitchen_lines.append(
                    KitchenLine(quantity=item.quantity, name=item.product_name_snapshot, note=item.note, seat=item.seat)
                )

        self._refresh_totals(order)
        order.dispatch_count = dispatch_no
        order.bill_requested_at = None  # de nouveaux plats : l'addition demandée n'est plus à jour
        if order.served_by_user_id is None and user.role == UserRole.SERVEUR:
            order.served_by_user_id = user.id  # premier serveur qui envoie sur une note de la caisse
        self.db.flush()

        job_id: str | None = None
        if kitchen_lines:
            server = order.served_by or (user if user.role == UserRole.SERVEUR else None)
            ticket = KitchenTicket(
                order_number=order.order_number,
                service_mode=order.service_mode,
                table_label=order.table.label if order.table else None,
                note_label=order.note_label if order.table_id else None,
                server_name=server.full_name if server else None,
                guests_count=order.guests_count,
                dispatch_no=dispatch_no,
                sent_at=datetime.now(timezone.utc),
                lines=tuple(kitchen_lines),
            )
            job_id = PrintingService(self.db).create_kitchen_ticket_job(order, ticket).id

        self.audit.log(
            action="ORDER_DISPATCHED",
            entity="ORDER",
            entity_id=order.id,
            user_id=user.id,
            after={
                "dispatch_no": dispatch_no,
                "lines": [
                    {"name": it.product_name_snapshot, "quantity": it.quantity, "seat": it.seat} for it in added
                ],
                "kitchen_lines": len(kitchen_lines),
                "kitchen_ticket_job_id": job_id,
            },
            device_id=device_id,
        )
        return order, OrderDispatchResponse(
            order=self._to_order_response(order),
            dispatch_no=dispatch_no,
            kitchen_lines_count=len(kitchen_lines),
            kitchen_ticket_job_id=job_id,
        )

    def _next_order_number(self, business_date: str) -> str:
        seq_num = self.order_repo.get_next_daily_sequence(business_date)
        order_number = generate_order_number(business_date, seq_num)
        while self.db.query(Order.id).filter(Order.order_number == order_number).first():
            seq_num += 1
            order_number = generate_order_number(business_date, seq_num)
        return order_number

    def split_by_seat(self, order_id: str, user: User, device_id: str | None = None) -> list[Order]:
        """Sépare l'addition par convive : chaque autre convive part sur sa propre note (son
        ticket, sa FNE) ; le premier garde la note d'origine avec les articles pour la table.

        Seulement avant tout paiement : rien ne se modifie après encaissement. Les lignes
        gardent leur convive et leur n° d'envoi ; le déplacement est tracé. NE VALIDE PAS :
        l'appelant enregistre la clé d'idempotence puis valide, et diffuse ensuite.
        """
        order = self._get_editable_order(order_id)
        self._ensure_server_of_note(order, user)
        if order.status != OrderStatus.OPEN or order.paid_xof > 0 or any(
            p.status == PaymentStatus.CAPTURED for p in order.payments
        ):
            raise CaisseException(
                code="ORDER_SPLIT_NOT_ALLOWED",
                title="Séparation impossible",
                detail="Un paiement est déjà enregistré sur cette note : elle ne peut plus être séparée.",
                status_code=status.HTTP_409_CONFLICT,
            )
        try:
            _staying, moving = split_by_seat(order.items)
        except ValueError as exc:
            raise CaisseException(
                code="ORDER_SPLIT_NOTHING_TO_SPLIT",
                title="Rien à séparer",
                detail=str(exc),
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            ) from exc

        used_labels = {
            o.note_label for o in self.order_repo.get_active_orders_by_table_id(order.table_id)
        } if order.table_id else set()
        business_date = order.cash_session.business_date.isoformat()
        now = datetime.now(timezone.utc)
        created: list[Order] = []
        for seat, lines in moving.items():
            note_label = None
            if order.table_id:
                n = 1
                while f"Note {n}" in used_labels:
                    n += 1
                note_label = f"Note {n}"
                used_labels.add(note_label)
            new = Order(
                order_number=self._next_order_number(business_date),
                cash_session_id=order.cash_session_id,
                table_id=order.table_id,
                note_label=note_label,
                status=OrderStatus.OPEN,
                service_mode=order.service_mode,
                opened_by_user_id=user.id,
                served_by_user_id=order.served_by_user_id,
                guests_count=1,
                dispatch_count=order.dispatch_count,
                bill_requested_at=order.bill_requested_at,
                total_ttc_xof=0,
                total_ht_xof=0,
                total_vat_xof=0,
                paid_xof=0,
                due_xof=0,
                opened_at=now,
            )
            self.db.add(new)
            self.db.flush()
            for line in lines:
                line.order_id = new.id
            self.db.flush()
            self.db.refresh(new)
            self._refresh_totals(new)
            created.append(new)
            self.audit.log(
                action="ORDER_SPLIT_CREATED",
                entity="ORDER",
                entity_id=new.id,
                user_id=user.id,
                after={
                    "from_order_id": order.id,
                    "seat": seat,
                    "lines": [{"name": it.product_name_snapshot, "quantity": it.quantity} for it in lines],
                    "total_ttc_xof": new.total_ttc_xof,
                },
                device_id=device_id,
            )

        before_total = order.total_ttc_xof
        self.db.refresh(order)
        self._refresh_totals(order)
        order.guests_count = max(1, order.guests_count - len(created))
        self.audit.log(
            action="ORDER_SPLIT",
            entity="ORDER",
            entity_id=order.id,
            user_id=user.id,
            before={"total_ttc_xof": before_total},
            after={"total_ttc_xof": order.total_ttc_xof, "new_orders": [o.id for o in created]},
            device_id=device_id,
        )
        self.db.flush()
        return [order, *created]

    @staticmethod
    def _ensure_server_of_note(order: Order, user: User) -> None:
        """L'addition d'une note (la demander, la séparer) revient à son serveur : sur une même
        table, chaque serveur s'occupe de ses clients. La caisse et l'encadrement ne sont pas
        concernés ; un serveur peut toujours ajouter sur la note d'un collègue (envoi)."""
        if user.role == UserRole.SERVEUR and order.served_by_user_id != user.id:
            raise CaisseException(
                code="ORDER_NOT_YOUR_NOTE",
                title="Note d'un collègue",
                detail="Seul le serveur de la note peut demander ou séparer son addition.",
                status_code=status.HTTP_403_FORBIDDEN,
            )

    def request_bill(self, order_id: str, user: User, device_id: str | None = None) -> OrderResponse:
        """Le serveur demande l'addition : la note passe en « Addition demandée » à la caisse."""
        order = self._get_editable_order(order_id)
        self._ensure_server_of_note(order, user)
        user_id = user.id
        if order.bill_requested_at is None:
            order.bill_requested_at = datetime.now(timezone.utc)
            self.audit.log(
                action="ORDER_BILL_REQUESTED",
                entity="ORDER",
                entity_id=order.id,
                user_id=user_id,
                after={"total_ttc_xof": order.total_ttc_xof},
                device_id=device_id,
            )
            self.db.commit()
            self.broadcast_order_updated(order, bill_requested=True)
        return self._to_order_response(order)

    def best_sellers(self, days: int = 7, limit: int = 8) -> list[BestSellerResponse]:
        """Produits actifs les plus vendus (commandes réglées) sur les `days` derniers jours."""
        since = datetime.now(timezone.utc) - timedelta(days=days)
        return [
            BestSellerResponse(product_id=product_id, quantity_sold=quantity)
            for product_id, quantity in self.order_repo.best_selling_products(since=since, limit=limit)
        ]

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
                    seat=it.seat,
                    dispatch_no=it.dispatch_no,
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
            service_mode=order.service_mode,  # type: ignore
            served_by_user_id=order.served_by_user_id,
            served_by_name=order.served_by.full_name if order.served_by else None,
            dispatch_count=order.dispatch_count,
            bill_requested_at=order.bill_requested_at.isoformat() if order.bill_requested_at else None,
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

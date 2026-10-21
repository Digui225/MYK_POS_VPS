from datetime import datetime, timezone
import json
import logging
from sqlalchemy.orm import Session
from fastapi import status

from caisse.config import get_settings

logger = logging.getLogger(__name__)

from caisse.domain.enums import OrderStatus, PaymentMethod
from caisse.domain.payment_rules import (
    validate_payment_amount,
    calculate_change,
    should_open_drawer,
)
from caisse.errors import CaisseException
from caisse.models.idempotency import IdempotencyRecord
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.models.user import User
from caisse.repositories.orders import OrderRepository
from caisse.repositories.payments import PaymentRepository
from caisse.repositories.sessions import CashSessionRepository
from caisse.schemas.payments import (
    PaymentRequest,
    PaymentResponse,
    OrderPaymentResult,
)
from caisse.services.audit_service import AuditService
from caisse.services.printing_service import PrintingService


class PaymentService:
    def __init__(self, db: Session):
        self.db = db
        self.order_repo = OrderRepository(db)
        self.payment_repo = PaymentRepository(db)
        self.session_repo = CashSessionRepository(db)
        self.printing_service = PrintingService(db)
        self.audit = AuditService(db)

    def process_payment(
        self,
        order_id: str,
        payload: PaymentRequest,
        user_id: str,
        idempotency_key: str | None = None,
        device_id: str | None = None,
    ) -> OrderPaymentResult:
        # 1. Vérification Idempotence
        if idempotency_key:
            existing_rec = (
                self.db.query(IdempotencyRecord)
                .filter(IdempotencyRecord.key == idempotency_key)
                .first()
            )
            if existing_rec and existing_rec.response_body:
                return OrderPaymentResult(**existing_rec.response_body)

        # 2. Vérification de la session de caisse active
        register = self.session_repo.get_or_create_default_register()
        active_session = self.session_repo.get_active_by_register_id(register.id)
        if not active_session:
            raise CaisseException(
                code="NO_OPEN_SESSION",
                title="Session de caisse fermée",
                detail="Impossible d'enregistrer un encaissement sans session de caisse ouverte.",
                status_code=status.HTTP_409_CONFLICT,
            )

        # 3. Verrouillage pessimiste de la commande
        order = (
            self.db.query(Order)
            .filter(Order.id == order_id)
            .with_for_update()
            .first()
        )
        if not order:
            raise CaisseException(
                code="ORDER_NOT_FOUND",
                title="Commande introuvable",
                detail=f"Aucune commande trouvée avec l'ID {order_id}.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        # 4. Vérification du statut de la commande
        if order.status not in [OrderStatus.OPEN, OrderStatus.PARTIALLY_PAID]:
            raise CaisseException(
                code="ORDER_ALREADY_SETTLED",
                title="Commande déjà réglée ou annulée",
                detail=f"Impossible d'encaisser une commande avec le statut '{order.status}'.",
                status_code=status.HTTP_409_CONFLICT,
                meta={"current_status": order.status},
            )

        active_items = [it for it in order.items if it.removed_at is None]
        if not active_items or order.total_ttc_xof <= 0:
            raise CaisseException(
                code="EMPTY_ORDER_PAYMENT",
                title="Commande vide",
                detail="Impossible d'encaisser une commande ne contenant aucun article.",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )

        # 5. Validation du montant et calcul du rendu de monnaie
        validate_payment_amount(payload.amount_xof, order.due_xof)
        change_xof = calculate_change(payload.tendered_xof, payload.amount_xof, payload.method)

        # 6. Création du paiement
        payment = Payment(
            order_id=order.id,
            cash_session_id=active_session.id,
            user_id=user_id,
            method=payload.method,
            amount_xof=payload.amount_xof,
            tendered_xof=payload.tendered_xof,
            change_xof=change_xof,
            provider=payload.provider,
            reference=payload.reference,
            status="CAPTURED",
            idempotency_key=idempotency_key,
        )
        self.payment_repo.add(payment)
        if payment not in order.payments:
            order.payments.append(payment)

        # 7. Mise à jour de la commande
        order.paid_xof += payload.amount_xof
        order.due_xof = order.total_ttc_xof - order.paid_xof

        user = self.db.query(User).filter(User.id == user_id).first()
        if not user:
            raise CaisseException(
                code="USER_NOT_FOUND",
                title="Utilisateur introuvable",
                detail=f"Aucun utilisateur trouvé avec l'identifiant '{user_id}'.",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        cashier_name = user.full_name or "Caissier"

        drawer_opened = False
        print_job_id = None
        fne_status: str | None = None

        stock_warnings = []
        if order.due_xof == 0:
            order.status = OrderStatus.PAID
            order.paid_at = datetime.now(timezone.utc)
            order.closed_by_user_id = user_id

            # Décision d'ouverture du tiroir-caisse
            drawer_opened = should_open_drawer(payload.method)

            # Décrément automatique du stock
            from caisse.services import stock_service
            stock_warnings = stock_service.apply_sale(self.db, order, user_id)

            fne_info = None
            # Facturation normalisée (FNE) : uniquement si expressément demandée par le client
            if payload.request_fne:
                try:
                    from caisse.deps import get_fne_provider
                    from caisse.domain.fne import FneTemplate
                    from caisse.models.customer import Customer
                    from caisse.services import fne_service

                    template = FneTemplate.B2C
                    if payload.customer_id:
                        customer = self.db.get(Customer, payload.customer_id)
                        if customer:
                            regime = (customer.tax_regime or "").upper()
                            if "B2G" in regime or "GOUV" in regime:
                                template = FneTemplate.B2G
                            elif "B2F" in regime or "EXPORT" in regime:
                                template = FneTemplate.B2F
                            elif customer.ncc:
                                template = FneTemplate.B2B

                    provider = get_fne_provider()
                    # Commit préalable des états en cours (paiement, statut payé, stock) avant émission FNE
                    self.db.commit()

                    fne_doc, submitted = fne_service.issue_for_order(
                        self.db,
                        order.id,
                        template=template,
                        customer_id=payload.customer_id,
                        payment_method=payload.method,
                        provider=provider,
                        user=user,
                    )
                    if fne_doc:
                        fne_status = str(getattr(fne_doc.status, "value", fne_doc.status))
                        v_base = get_settings().fne_verification_base_url
                        qr_payload = (
                            fne_doc.qr_payload
                            or (fne_doc.payload.get("request", {}).get("qr_code") if isinstance(fne_doc.payload, dict) else None)
                            or f"{v_base}/{fne_doc.external_number or order.order_number}"
                        )
                        fne_info = {
                            "fne_number": fne_doc.external_number or f"FNE-{order.order_number}",
                            "qr_url": qr_payload,
                        }
                except Exception as exc:
                    logger.warning(
                        "Erreur lors de l'émission FNE pour la commande %s : %s",
                        order.id,
                        exc,
                        exc_info=True,
                    )
                    fne_status = "QUEUED"
                    v_base = get_settings().fne_verification_base_url
                    fne_info = {
                        "fne_number": f"FNE-{order.order_number}",
                        "qr_url": f"{v_base}/{order.order_number}",
                    }

            # Génération du ticket de caisse définitif
            job = self.printing_service.create_receipt_job(
                order=order,
                payments=order.payments,
                cashier_name=cashier_name,
                open_drawer=drawer_opened,
                is_duplicate=False,
                fne_info=fne_info,
            )
            print_job_id = job.id
        else:
            order.status = OrderStatus.PARTIALLY_PAID

        # 8. Audit Log
        self.audit.log(
            action="PAYMENT_CAPTURED",
            entity="PAYMENT",
            entity_id=payment.id,
            user_id=user_id,
            after={
                "order_id": order.id,
                "amount_xof": payload.amount_xof,
                "method": payload.method,
                "order_status": order.status,
                "due_xof": order.due_xof,
                "fne_requested": payload.request_fne,
            },
            device_id=device_id,
        )

        payment_res = PaymentResponse(
            id=payment.id,
            order_id=payment.order_id,
            method=payment.method,
            amount_xof=payment.amount_xof,
            tendered_xof=payment.tendered_xof,
            change_xof=payment.change_xof,
            provider=payment.provider,
            reference=payment.reference,
            status=payment.status,
            created_at=payment.created_at.isoformat() if payment.created_at else datetime.now(timezone.utc).isoformat(),
        )

        # Garantir le statut de commande requis par le schéma de retour
        final_order_status = OrderStatus.PAID if order.due_xof == 0 else OrderStatus.PARTIALLY_PAID
        order.status = final_order_status

        result = OrderPaymentResult(
            payment=payment_res,
            order_status=final_order_status.value,
            remaining_due_xof=order.due_xof,
            change_xof=change_xof,
            drawer_opened=drawer_opened,
            print_job_id=print_job_id,
            fne_status=fne_status,
            warnings=stock_warnings or [],
        )

        # 9. Enregistrement Idempotence
        if idempotency_key:
            record = IdempotencyRecord(
                key=idempotency_key,
                request_path=f"/orders/{order_id}/payments",
                request_hash="",
                response_status=201,
                response_body=result.model_dump(),
            )
            self.db.add(record)

        self.db.commit()

        try:
            from caisse.infrastructure.websocket.manager import ws_manager
            event_type = "ORDER_PAID" if order.due_xof == 0 else "ORDER_PARTIALLY_PAID"
            ws_manager.broadcast_sync(
                event_type,
                {
                    "order_id": order.id,
                    "order_number": order.order_number,
                    "status": final_order_status.value,
                    "total_ttc_xof": order.total_ttc_xof,
                    "paid_xof": order.paid_xof,
                    "amount_paid_xof": payload.amount_xof,
                    "table_id": order.table_id,
                },
            )
        except Exception as ws_err:
            logger.debug(f"Erreur lors de la diffusion WebSocket de l'événement de paiement: {ws_err}")

        return result


    def list_order_payments(self, order_id: str) -> list[PaymentResponse]:
        payments = self.payment_repo.list_by_order_id(order_id)
        return [
            PaymentResponse(
                id=p.id,
                order_id=p.order_id,
                method=p.method,
                amount_xof=p.amount_xof,
                tendered_xof=p.tendered_xof,
                change_xof=p.change_xof,
                provider=p.provider,
                reference=p.reference,
                status=p.status,
                created_at=p.created_at.isoformat(),
            )
            for p in payments
        ]

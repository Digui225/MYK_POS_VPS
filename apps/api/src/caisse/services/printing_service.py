from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import status
from sqlalchemy.orm import Session

from caisse.domain.payment_rules import format_receipt_text
from caisse.errors import CaisseException
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.models.print_job import PrintJob
from caisse.models.print_terminal import PrintTerminal
from caisse.models.settings import EstablishmentSetting
from caisse.repositories.print_jobs import PrintJobRepository
from caisse.repositories.print_terminals import PrintTerminalRepository
from caisse.schemas.printing import PrinterReport, PrintingStatusOut
from caisse.services.audit_service import AuditService

OFFLINE_THRESHOLD_SECONDS = 15


class PrintingService:
    def __init__(self, db: Session, agent_url: str | None = None):
        self.db = db
        self.agent_url = agent_url
        self.repo = PrintJobRepository(db)
        self.terminal_repo = PrintTerminalRepository(db)
        self.audit = AuditService(db)

    def _send_raw_esc_pos(self, *args: Any, **kwargs: Any) -> bool:
        """Méthode conservée pour compatibilité : en mode VPS, les travaux sont en file."""
        return True

    def _dispatch_job_to_agent(self, job: PrintJob) -> bool:
        """Compatibilité outbox : en mode test/fallback, marque le job comme imprimé."""
        if self._send_raw_esc_pos(b""):
            job.status = "DONE"
            job.printed_at = datetime.now(timezone.utc)
            return True
        return False

    def generate_receipt_content(
        self,
        order: Order,
        payments: list[Payment],
        cashier_name: str,
        is_duplicate: bool = False,
        fne_info: dict[str, Any] | None = None,
    ) -> str:
        setting = self.db.query(EstablishmentSetting).first()

        restaurant_info = {
            "name": (setting.restaurant_name if setting and setting.restaurant_name else "RESTAURANT MYK").upper(),
            "address": setting.address if setting and setting.address else "Abidjan, Plateau",
            "phone": setting.phone if setting and setting.phone else "+225 07 58 00 00 00",
            "ncc": setting.ncc if setting and setting.ncc else "2104598B",
            "rccm": setting.rccm if setting and setting.rccm else "CI-ABJ-2024-B-12345",
            "footer": setting.receipt_footer if setting and setting.receipt_footer else "Merci de votre visite · A tres bientot !",
        }

        order_info = {
            "order_number": order.order_number,
            "table_label": order.table.label if order.table else "Comptoir",
            "guests_count": order.guests_count,
            "cashier_name": cashier_name,
            "date_str": (order.paid_at or datetime.now(timezone.utc)).strftime("%d/%m/%Y %H:%M"),
        }

        items = []
        for it in order.items:
            if it.removed_at is None:
                items.append({
                    "name": it.product_name_snapshot,
                    "quantity": it.quantity,
                    "line_total_xof": it.line_total_xof,
                })

        payment_entries = []
        total_change = 0
        total_tendered = 0
        for p in payments:
            payment_entries.append({
                "method": p.method,
                "provider": p.provider,
                "amount_xof": p.amount_xof,
            })
            if p.change_xof:
                total_change += p.change_xof
            if p.tendered_xof:
                total_tendered += p.tendered_xof

        width = 32
        if setting and setting.print_width and setting.print_width >= 80:
            width = 42

        totals = {
            "total_ttc_xof": order.total_ttc_xof,
            "total_vat_xof": order.total_vat_xof,
            "vat_rate": int(setting.default_vat_rate) if setting and setting.default_vat_rate is not None else 0,
            "change_xof": total_change,
            "tendered_xof": total_tendered if total_tendered > 0 else None,
        }

        return format_receipt_text(
            restaurant_info=restaurant_info,
            order_info=order_info,
            items=items,
            payments=payment_entries,
            totals=totals,
            fne_info=fne_info,
            is_duplicate=is_duplicate,
            width=width,
        )

    def create_receipt_job(
        self,
        order: Order,
        payments: list[Payment],
        cashier_name: str,
        open_drawer: bool = False,
        is_duplicate: bool = False,
        fne_info: dict[str, Any] | None = None,
    ) -> PrintJob:
        content = self.generate_receipt_content(
            order=order,
            payments=payments,
            cashier_name=cashier_name,
            is_duplicate=is_duplicate,
            fne_info=fne_info,
        )

        job = PrintJob(
            order_id=order.id,
            job_type="DUPLICATE" if is_duplicate else "RECEIPT",
            content=content,
            open_drawer=open_drawer,
            cut=True,
            is_duplicate=is_duplicate,
            status="QUEUED",
        )
        self.repo.add(job)
        self.db.flush()
        return job

    def reprint_ticket(
        self,
        order: Order,
        cashier_name: str,
        user_id: str,
        device_id: str | None = None,
    ) -> PrintJob:
        from caisse.models.fne import FneDocument
        fne_doc = self.db.query(FneDocument).filter(FneDocument.order_id == order.id).first()
        fne_info = None
        if fne_doc and (fne_doc.external_number or getattr(fne_doc, "invoice_number", None) or fne_doc.qr_payload or getattr(fne_doc, "qr_url", None)):
            from caisse.config import get_settings
            v_base = get_settings().fne_verification_base_url
            qr = fne_doc.qr_payload or getattr(fne_doc, "qr_url", None)
            if qr and not str(qr).startswith("http"):
                qr = f"{v_base}/{qr}"
            elif not qr:
                qr = f"{v_base}/{fne_doc.external_number or order.order_number}"

            fne_info = {
                "fne_number": fne_doc.external_number or getattr(fne_doc, "invoice_number", None) or f"FNE-{order.order_number}",
                "qr_url": qr,
            }

        payments = order.payments or []
        job = self.create_receipt_job(
            order=order,
            payments=payments,
            cashier_name=cashier_name,
            open_drawer=False,  # Pas d'ouverture tiroir sur duplicata
            is_duplicate=True,
            fne_info=fne_info,
        )

        self.audit.log(
            action="TICKET_REPRINTED",
            entity="ORDER",
            entity_id=order.id,
            user_id=user_id,
            after={"print_job_id": job.id, "is_duplicate": True},
            device_id=device_id,
        )
        self.db.commit()
        return job

    def print_z_report(
        self,
        session_id: str,
        cashier_name: str,
        user_id: str,
        device_id: str | None = None,
    ) -> PrintJob:
        from caisse.domain.payment_rules import format_z_report_text
        from caisse.services.cash_session_service import CashSessionService

        session_service = CashSessionService(self.db)
        z_report = session_service.get_z_report(session_id)

        setting = self.db.query(EstablishmentSetting).first()
        restaurant_info = {
            "name": (setting.restaurant_name if setting and setting.restaurant_name else "RESTAURANT MYK").upper(),
            "address": setting.address if setting and setting.address else "Abidjan, Plateau",
            "phone": setting.phone if setting and setting.phone else "+225 07 58 00 00 00",
            "ncc": setting.ncc if setting and setting.ncc else "2104598B",
            "rccm": setting.rccm if setting and setting.rccm else "CI-ABJ-2024-B-12345",
            "footer": "DOCUMENT FISCAL - CLOTURE DE CAISSE",
        }

        z_data = z_report.model_dump()
        z_data["cashier_name"] = cashier_name

        content = format_z_report_text(restaurant_info=restaurant_info, z_data=z_data, width=32)

        job = PrintJob(
            order_id=None,
            job_type="Z_REPORT",
            content=content,
            open_drawer=True,
            cut=True,
            is_duplicate=False,
            status="QUEUED",
        )
        self.repo.add(job)
        self.db.flush()

        self.audit.log(
            action="Z_REPORT_PRINTED",
            entity="CASH_SESSION",
            entity_id=session_id,
            user_id=user_id,
            after={"print_job_id": job.id},
            device_id=device_id,
        )
        self.db.commit()
        return job

    def _require_online_printer(self) -> PrintTerminal | None:
        """Vérifie qu'un terminal s'est manifesté récemment (moins de 15 s) et que son imprimante est en ligne."""
        from caisse.config import get_settings
        if get_settings().APP_ENV == "test":
            return None

        terminal, online = self._online_terminal()
        if terminal is None or not online:
            raise CaisseException(
                code="PRINT_AGENT_UNAVAILABLE",
                title="Agent d'impression non disponible",
                detail="Aucun agent d'impression n'est connecté à la caisse actuellement.",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        if terminal.printer_status.get("online") is False:
            raise CaisseException(
                code="PRINTER_UNAVAILABLE",
                title="Imprimante hors ligne",
                detail="L'imprimante est signalée hors ligne ou débranchée par l'agent.",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return terminal

    def _online_terminal(self) -> tuple[PrintTerminal | None, bool]:
        terminal = self.terminal_repo.latest_seen()
        if terminal is None or terminal.last_seen_at is None:
            return terminal, False
        now = datetime.now(timezone.utc)
        online = terminal.last_seen_at >= (now - timedelta(seconds=OFFLINE_THRESHOLD_SECONDS))
        return terminal, online

    def manual_open_drawer(self, user_id: str, device_id: str | None = None) -> PrintJob:
        self._require_online_printer()
        job = PrintJob(
            order_id=None,
            job_type="DRAWER",
            content="",
            open_drawer=True,
            cut=False,
            is_duplicate=False,
            status="QUEUED",
        )
        self.repo.add(job)
        self.db.flush()

        self.audit.log(
            action="MANUAL_DRAWER_OPENED",
            entity="CASH_DRAWER",
            entity_id="drawer-01",
            user_id=user_id,
            after={"print_job_id": job.id},
            device_id=device_id,
        )
        self.db.commit()
        return job

    def print_test_ticket(
        self,
        user_id: str,
        device_id: str | None = None,
        custom_header: str | None = None,
        custom_footer: str | None = None,
        width: int = 32,
    ) -> PrintJob:
        self._require_online_printer()
        now_str = datetime.now(timezone.utc).strftime("%d/%m/%Y %H:%M:%S")
        content = (
            "================================\n"
            "       TICKET DE TEST POS       \n"
            "================================\n"
            f"Date: {now_str}\n"
            f"Terminal: {device_id or 'Comptoir'}\n"
            "--------------------------------\n"
            "Imprimante thermique ESC/POS OK\n"
            "Connexion VPS -> Caisse : ACTIVE\n"
            "Accents français : é è ê à ç\n"
            "================================\n"
            f"{custom_footer or 'FIN DU TEST'}\n"
        )
        job = PrintJob(
            order_id=None,
            job_type="TEST",
            content=content,
            open_drawer=False,
            cut=True,
            is_duplicate=False,
            status="QUEUED",
        )
        self.repo.add(job)
        self.db.flush()

        self.audit.log(
            action="TEST_TICKET_PRINTED",
            entity="PRINTER",
            entity_id="test",
            user_id=user_id,
            after={"print_job_id": job.id},
            device_id=device_id,
        )
        self.db.commit()
        return job

    def get_status(self) -> PrintingStatusOut:
        terminal, online = self._online_terminal()
        printer = terminal.printer_status if terminal is not None and online else {}
        return PrintingStatusOut(
            agent_online=online,
            printer_online=bool(printer.get("online")),
            paper=printer.get("paper"),
            width=printer.get("width"),
            agent_last_seen_at=terminal.last_seen_at if terminal is not None else None,
            queued_jobs=self.repo.queued_count(),
            failed_jobs=self.repo.failed_count(),
            last_success_at=self.repo.last_success_at(),
        )

    # --- Agent du terminal (Polling & Confirmation) ---

    def claim_next(self, terminal: PrintTerminal, printer: PrinterReport) -> PrintJob | None:
        """Interrogation de l'agent : note sa présence et l'état de l'imprimante,
        puis lui confie le plus ancien travail en file."""
        now = datetime.now(timezone.utc)
        terminal.last_seen_at = now
        terminal.printer_status = printer.model_dump()

        job = None
        if printer.online:
            job = self.repo.claim_next()
            if job is not None:
                job.status = "PRINTING"
                job.attempts = (job.attempts or 0) + 1
                job.claimed_at = now
                job.terminal_id = terminal.id

        self.db.commit()
        return job

    def report_result(
        self,
        terminal: PrintTerminal,
        job_id: str,
        printed: bool,
        error: str | None = None,
        device_id: str | None = None,
    ) -> PrintJob:
        job = self.repo.get_for_update(job_id)
        if not job:
            raise CaisseException(
                code="PRINT_JOB_NOT_FOUND",
                title="Travail introuvable",
                detail=f"Travail d'impression {job_id} introuvable.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if job.terminal_id != terminal.id:
            raise CaisseException(
                code="PRINT_JOB_NOT_CLAIMED",
                title="Travail non assigné",
                detail="Ce travail d'impression est assigné à un autre terminal.",
                status_code=status.HTTP_409_CONFLICT,
            )

        final_status = "DONE" if printed else "FAILED"
        if job.status == final_status:
            return job  # Idempotent

        if job.status != "PRINTING":
            raise CaisseException(
                code="PRINT_JOB_NOT_CLAIMED",
                title="État invalide",
                detail=f"Le travail n'est pas en cours d'impression (statut={job.status}).",
                status_code=status.HTTP_409_CONFLICT,
            )

        job.status = final_status
        if printed:
            job.printed_at = datetime.now(timezone.utc)
            job.error_message = None
        else:
            job.error_message = (error or "Échec signalé par l'agent d'impression")[:500]

        self.audit.log(
            action="PRINT_JOB_COMPLETED" if printed else "PRINT_JOB_FAILED",
            entity="PRINT_JOB",
            entity_id=job.id,
            user_id=None,
            after={
                "status": job.status,
                "job_type": job.job_type,
                "attempts": job.attempts,
                "terminal": terminal.name,
                "error": job.error_message,
            },
            device_id=device_id or terminal.name,
        )
        self.db.commit()
        return job

    def retry_job(self, job_id: str, user_id: str | None = None, device_id: str | None = None) -> PrintJob:
        job = self.repo.get_for_update(job_id)
        if not job:
            raise CaisseException(
                code="PRINT_JOB_NOT_FOUND",
                title="Travail introuvable",
                detail=f"Travail d'impression {job_id} introuvable.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        job.status = "QUEUED"
        job.claimed_at = None
        job.terminal_id = None
        job.error_message = None

        self.audit.log(
            action="PRINT_JOB_RETRY",
            entity="PRINT_JOB",
            entity_id=job.id,
            user_id=user_id,
            after={"status": "QUEUED"},
            device_id=device_id,
        )
        self.db.commit()
        return job

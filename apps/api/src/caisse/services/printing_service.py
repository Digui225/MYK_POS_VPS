import os
import shutil
import subprocess
from datetime import datetime, timezone
from typing import Any
import httpx
from sqlalchemy.orm import Session

from caisse.domain.payment_rules import (
    format_receipt_text,
    build_esc_pos_bytes,
    ESC_INIT,
    ESC_DRAWER_KICK,
    ESC_CUT_PAPER,
)
from caisse.models.order import Order
from caisse.models.payment import Payment
from caisse.models.print_job import PrintJob
from caisse.repositories.print_jobs import PrintJobRepository
from caisse.services.audit_service import AuditService


class PrintingService:
    def __init__(self, db: Session, agent_url: str = "http://127.0.0.1:8090"):
        self.db = db
        self.agent_url = agent_url
        self.repo = PrintJobRepository(db)
        self.audit = AuditService(db)

    def generate_receipt_content(
        self,
        order: Order,
        payments: list[Payment],
        cashier_name: str,
        is_duplicate: bool = False,
        fne_info: dict | None = None,
    ) -> str:
        from caisse.models.settings import EstablishmentSetting
        setting = self.db.query(EstablishmentSetting).first()

        restaurant_info = {
            "name": (setting.restaurant_name if setting and setting.restaurant_name else "SYLLA PLUS").upper(),
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
        else:
            width = 32

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
        fne_info: dict | None = None,
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

        # Tentative d'envoi synchrone à l'agent d'impression local (mode dégradé transparent)
        self._dispatch_job_to_agent(job)

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
            open_drawer=False,  # Strict : jamais d'ouverture tiroir sur duplicata
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
        from caisse.services.cash_session_service import CashSessionService
        from caisse.models.settings import EstablishmentSetting
        from caisse.domain.payment_rules import format_z_report_text

        session_service = CashSessionService(self.db)
        z_report = session_service.get_z_report(session_id)

        setting = self.db.query(EstablishmentSetting).first()
        restaurant_info = {
            "name": (setting.restaurant_name if setting and setting.restaurant_name else "SYLLA PLUS").upper(),
            "address": setting.address if setting and setting.address else "Abidjan, Plateau",
            "phone": setting.phone if setting and setting.phone else "+225 07 58 00 00 00",
            "ncc": setting.ncc if setting and setting.ncc else "2104598B",
            "rccm": setting.rccm if setting and setting.rccm else "CI-ABJ-2024-B-12345",
            "footer": setting.receipt_footer if setting and setting.receipt_footer else "Merci de votre visite · A tres bientot !",
        }

        z_data = z_report.model_dump()
        content = format_z_report_text(restaurant_info, z_data, width=32)

        job = PrintJob(
            order_id=None,
            job_type="Z_REPORT",
            content=content,
            open_drawer=False,
            cut=True,
            is_duplicate=False,
            status="QUEUED",
        )
        self.repo.add(job)
        self.db.flush()

        self._dispatch_job_to_agent(job)

        self.audit.log(
            action="Z_REPORT_PRINTED",
            entity="CASH_SESSION",
            entity_id=session_id,
            user_id=user_id,
            after={"print_job_id": job.id, "z_number": z_report.z_number},
            device_id=device_id,
        )
        self.db.commit()
        return job

    def _send_raw_esc_pos(self, raw_bytes: bytes, force: bool = False) -> bool:
        """Envoie des octets bruts ESC/POS directement à l'imprimante thermique."""
        from caisse.config import get_settings
        app_settings = get_settings()

        # En mode test, ne JAMAIS envoyer d'octets au matériel
        if app_settings.APP_ENV == "test":
            return True

        # Si l'impression matérielle est désactivée dans la config et non forcée manuellement
        if not app_settings.ENABLE_HARDWARE_PRINTING and not force:
            return True

        # 1. Sur Linux : priorité absolue à CUPS lp raw (Xprinter_58) ou port USB direct
        if shutil.which("lp"):
            for printer_target in ["Xprinter_58", None]:
                cmd = ["lp", "-o", "raw"] if printer_target is None else ["lp", "-d", printer_target, "-o", "raw"]
                try:
                    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    proc.communicate(input=raw_bytes, timeout=4.0)
                    if proc.returncode == 0:
                        return True
                except Exception:
                    pass
        elif shutil.which("lpr"):
            for printer_target in ["Xprinter_58", None]:
                cmd = ["lpr", "-l"] if printer_target is None else ["lpr", "-P", printer_target, "-l"]
                try:
                    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    proc.communicate(input=raw_bytes, timeout=4.0)
                    if proc.returncode == 0:
                        return True
                except Exception:
                    pass

        try:
            with open("/dev/usb/lp0", "wb") as f:
                f.write(raw_bytes)
                f.flush()
                return True
        except Exception:
            pass

        # 2. Sur Windows ou si CUPS échoue : agent d'impression local port 8090
        try:
            with httpx.Client(timeout=2.0) as client:
                res = client.post(
                    f"{self.agent_url}/print-raw",
                    content=raw_bytes,
                    headers={"Content-Type": "application/octet-stream"},
                )
                if res.status_code in [200, 201]:
                    return True
                # Fallback sur /print avec texte CP850
                res = client.post(
                    f"{self.agent_url}/print",
                    json={"content": raw_bytes.decode("cp850", errors="replace"), "open_drawer": False, "cut": False},
                )
                if res.status_code in [200, 201]:
                    return True
        except Exception:
            pass

        return False

    def manual_open_drawer(self, user_id: str, device_id: str | None = None) -> bool:
        pulse_bytes = ESC_INIT + ESC_DRAWER_KICK
        success = self._send_raw_esc_pos(pulse_bytes, force=True)

        self.audit.log(
            action="MANUAL_DRAWER_OPENED",
            entity="CASH_DRAWER",
            entity_id="drawer-01",
            user_id=user_id,
            after={"dispatched": success},
            device_id=device_id,
        )
        self.db.commit()
        return success

    def print_test_ticket(
        self,
        user_id: str,
        device_id: str | None = None,
        custom_header: str | None = None,
        custom_footer: str | None = None,
        width: int = 32,
    ) -> dict[str, Any]:
        from caisse.models.settings import EstablishmentSetting

        setting = self.db.query(EstablishmentSetting).first()
        restaurant_name = (setting.restaurant_name if setting and setting.restaurant_name else "SYLLA PLUS").upper()
        address = setting.address if setting and setting.address else "Abidjan, Plateau"
        phone = setting.phone if setting and setting.phone else "+225 07 58 00 00 00"
        ncc = setting.ncc if setting and setting.ncc else "2104598B"
        rccm = setting.rccm if setting and setting.rccm else "CI-ABJ-2024-B-12345"
        footer = custom_footer or (setting.receipt_footer if setting and setting.receipt_footer else "Merci de votre visite · A tres bientot !")
        welcome = custom_header if custom_header is not None else "Bienvenue chez Sylla Plus"

        restaurant_info = {
            "name": restaurant_name,
            "address": address,
            "phone": phone,
            "ncc": ncc,
            "rccm": rccm,
            "footer": footer,
            "welcome_message": welcome,
        }

        from caisse.config import get_settings
        v_base = get_settings().fne_verification_base_url

        order_info = {
            "order_number": "CMD-0042",
            "table_label": "12",
            "cashier_name": "Marc",
            "date_str": f"{datetime.now().strftime('%d/%m/%Y')} 13:45",
            "fne_number": "FNE-2026-10-01-MYK-0042",
            "fne_qr_url": f"{v_base}/FNE-2026-10-01-MYK-0042",
        }

        items = [
            {"name": "Poulet Braise Entier", "quantity": 1, "line_total_xof": 6500},
            {"name": "Alloco Portion", "quantity": 2, "line_total_xof": 2000},
            {"name": "Jus Bissap Maison", "quantity": 2, "line_total_xof": 2000},
        ]

        payments = [
            {"method": "CASH", "amount_xof": 10500},
        ]

        totals = {
            "total_vat_xof": 0,
            "vat_rate": 0,
            "total_ttc_xof": 10500,
            "tendered_xof": 15000,
            "change_xof": 4500,
        }

        test_content = format_receipt_text(
            restaurant_info=restaurant_info,
            order_info=order_info,
            items=items,
            payments=payments,
            totals=totals,
            fne_info={
                "fne_number": "FNE-2026-10-01-MYK-0042",
                "qr_url": f"{v_base}/FNE-2026-10-01-MYK-0042",
            },
            is_duplicate=False,
            width=width,
            welcome_message=welcome,
        )

        raw_bytes = build_esc_pos_bytes(test_content, open_drawer=False, cut=True)
        success = self._send_raw_esc_pos(raw_bytes, force=True)

        self.audit.log(
            action="TEST_TICKET_PRINTED",
            entity="PRINTER",
            entity_id="Xprinter_58",
            user_id=user_id,
            after={"success": success, "width": width},
            device_id=device_id,
        )
        self.db.commit()
        return {"status": "PRINTED" if success else "FAILED", "success": success}

    def get_status(self) -> dict[str, Any]:
        try:
            with httpx.Client(timeout=0.8) as client:
                res = client.get(f"{self.agent_url}/status")
                if res.status_code == 200:
                    return res.json()
        except Exception:
            pass

        # Détection CUPS ou USB Linux
        if shutil.which("lpstat"):
            try:
                res = subprocess.run(["lpstat", "-p", "Xprinter_58"], capture_output=True, text=True, timeout=1.0)
                if res.returncode == 0:
                    return {
                        "online": True,
                        "paper": "ok",
                        "model": "Xprinter XP-58IIH (USB Direct / CUPS)",
                        "width": 32,
                    }
            except Exception:
                pass

        if os.path.exists("/dev/usb/lp0"):
            return {
                "online": True,
                "paper": "ok",
                "model": "Xprinter XP-58IIH (USB Direct /dev/usb/lp0)",
                "width": 32,
            }

        return {
            "online": False,
            "paper": "unknown",
            "model": "POS-58 ESC/POS (Déconnecté / Mode Outbox)",
            "width": 32,
        }

    def _dispatch_job_to_agent(self, job: PrintJob) -> None:
        raw_bytes = build_esc_pos_bytes(
            content=job.content,
            open_drawer=job.open_drawer,
            cut=job.cut,
        )
        success = self._send_raw_esc_pos(raw_bytes)
        if success:
            job.status = "DONE"
            job.printed_at = datetime.now(timezone.utc)
        else:
            job.error_message = "Agent d'impression ou port USB injoignable"

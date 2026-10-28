from functools import lru_cache
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class AgentSettings(BaseSettings):
    # utf-8-sig : un .env enregistré par le Bloc-notes de Windows peut commencer par un BOM
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8-sig",
                                      extra="ignore")

    printer_vendor_id: int = 0x0416
    printer_product_id: int = 0x5011
    printer_in_ep: int = 0x82
    printer_out_ep: int = 0x01
    printer_width: int = 48
    printer_codepage: str = "CP858"
    drawer_pulse: str = "1b700019fa"
    # usb = USB direct (Linux) · win32 = spouleur Windows, pilote du fabricant en place ·
    # dummy = aucune imprimante (développement)
    printer_backend: Literal["usb", "win32", "dummy"] = "usb"
    printer_name: str = ""  # win32 : nom de l'imprimante dans Windows (python -m agent --list)
    spool_timeout_seconds: float = 15.0  # win32 : délai pour que le ticket quitte la file

    # adresse de la caisse en ligne, sans /api/v1 (ex. https://caisse.osispos.com)
    api_url: str = "http://localhost:8001"
    terminal_token: str = ""  # créé par POST /api/v1/printing/terminals ou la CLI
    poll_interval_seconds: float = 2.0
    request_timeout_seconds: float = 10.0
    log_file: str = ""  # Windows (tâche planifiée) : pas de journal système, fichier tournant

    @field_validator("printer_vendor_id", "printer_product_id", "printer_in_ep",
                     "printer_out_ep", mode="before")
    @classmethod
    def _hex(cls, value: object) -> object:
        return int(value, 0) if isinstance(value, str) else value

    @property
    def drawer_pulse_bytes(self) -> bytes:
        return bytes.fromhex(self.drawer_pulse)


@lru_cache
def get_settings() -> AgentSettings:
    return AgentSettings()

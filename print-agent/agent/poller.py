"""Boucle de l'agent : interroge la caisse en ligne, imprime, rend le résultat.

La caisse est sur un serveur distant qui ne peut pas joindre le restaurant : c'est l'agent qui
vient chercher les travaux (`POST /print-agent/poll`), un à un, puis rend le résultat
(`POST /print-agent/jobs/{id}/result`). Aucune règle métier ici : le texte arrive mis en page.
"""

import logging
import time

import httpx

from agent.config import AgentSettings
from agent.escpos_driver import EscposDriver, PrinterUnavailable, Status

log = logging.getLogger("print-agent")

_STATUS_CACHE_SECONDS = 10.0  # l'état de l'imprimante n'est pas relu à chaque interrogation
_RESULT_ATTEMPTS = 5  # un résultat perdu laisserait le travail « en cours » côté caisse
_TOKEN_REFUSED_PAUSE = 30.0


class Poller:
    def __init__(self, settings: AgentSettings, driver: EscposDriver) -> None:
        self.settings = settings
        self.driver = driver
        self.client = httpx.Client(
            base_url=f"{settings.api_url.rstrip('/')}/api/v1/print-agent",
            headers={"Authorization": f"Bearer {settings.terminal_token}"},
            timeout=settings.request_timeout_seconds,
        )
        self._status: tuple[float, Status] | None = None
        self._connected: bool | None = None

    def _printer_status(self) -> Status:
        now = time.monotonic()
        if self._status is None or now - self._status[0] > _STATUS_CACHE_SECONDS:
            self._status = (now, self.driver.status())
        return self._status[1]

    def _set_connected(self, connected: bool, detail: str = "") -> None:
        """Journalise les changements d'état seulement, pas chaque interrogation."""
        if connected != self._connected:
            if connected:
                log.info("connecté à %s", self.settings.api_url)
            else:
                log.warning("caisse injoignable (%s) : nouvel essai en continu", detail)
            self._connected = connected

    def poll(self) -> dict[str, object] | None:
        status = self._printer_status()
        resp = self.client.post(
            "/poll",
            json={
                "printer": {
                    "online": status.online,
                    "paper": status.paper,
                    "model": status.model,
                    "width": status.width,
                }
            },
        )
        resp.raise_for_status()
        job: dict[str, object] | None = resp.json()["job"]
        return job

    def process(self, job: dict[str, object]) -> tuple[bool, str | None]:
        content = str(job["content"])
        open_drawer = bool(job["open_drawer"])
        try:
            if not content:
                if open_drawer:
                    self.driver.open_drawer()
            else:
                self.driver.print(content, qr=None, open_drawer=open_drawer, cut=bool(job["cut"]))
        except Exception as exc:  # PrinterUnavailable, ou erreur imprévue du pilote
            self._status = None  # relire l'état réel à la prochaine interrogation
            if not isinstance(exc, PrinterUnavailable):
                log.exception("erreur inattendue à l'impression")
            log.error("travail %s (%s) non imprimé : %s", job["id"], job["type"], exc)
            return False, str(exc)[:500]
        log.info("travail %s (%s) imprimé", job["id"], job["type"])
        return True, None

    def report(self, job_id: object, printed: bool, error: str | None) -> None:
        for attempt in range(1, _RESULT_ATTEMPTS + 1):
            try:
                self.client.post(
                    f"/jobs/{job_id}/result", json={"printed": printed, "error": error}
                ).raise_for_status()
                return
            except httpx.HTTPStatusError as exc:
                # 409 : remis en file ou pris par un autre terminal entre-temps, rien à refaire
                log.error("résultat du travail %s refusé : %s", job_id, exc.response.text)
                return
            except httpx.HTTPError as exc:
                log.warning("résultat du travail %s non transmis (%d/%d) : %s", job_id,
                            attempt, _RESULT_ATTEMPTS, exc)
                time.sleep(self.settings.poll_interval_seconds * attempt)
        log.error("résultat du travail %s perdu : à rejouer depuis la caisse", job_id)

    def run_forever(self) -> None:
        interval = self.settings.poll_interval_seconds
        while True:
            try:
                job = self.poll()
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code == 401:
                    log.error("jeton de terminal refusé (révoqué ?) : vérifier TERMINAL_TOKEN")
                    self._connected = None
                    time.sleep(_TOKEN_REFUSED_PAUSE)
                else:
                    self._set_connected(False, f"HTTP {exc.response.status_code}")
                    time.sleep(interval)
                continue
            except httpx.HTTPError as exc:
                self._set_connected(False, type(exc).__name__)
                time.sleep(interval)
                continue
            except Exception:
                # imprévu (pilote, réponse inattendue…) : l'agent ne doit jamais s'arrêter seul
                log.exception("erreur inattendue pendant l'interrogation")
                time.sleep(interval)
                continue
            self._set_connected(True)
            if job is None:
                time.sleep(interval)
                continue
            printed, error = self.process(job)
            self.report(job["id"], printed, error)
            # travail suivant tout de suite : la file se vide sans attendre l'intervalle

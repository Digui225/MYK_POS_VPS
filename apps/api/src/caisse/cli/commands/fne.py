import argparse
import json
import logging
import signal
import sys
import threading
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

from caisse.core.config import get_settings
from caisse.core.database import SessionLocal
from caisse.core.deps import get_fne_provider

PROBE_LINES = [
    # TTC attendu : 2 x 3 500 + 1 x 1 000 = 8 000 XOF
    ("Poisson braisé", 2, 3500, Decimal("0"), "PROBE-01"),
    ("Eau minérale 1,5 L", 1, 1000, Decimal("0"), "PROBE-02"),
]


def cmd_fne_probe(args: argparse.Namespace) -> None:
    from caisse.domain import fne
    from caisse.domain.ports import FneError
    from caisse.infrastructure.fne import HttpFneProvider

    settings = get_settings()
    if not settings.fne_api_base_url or not settings.fne_api_key:
        sys.exit("FNE_API_BASE_URL et FNE_API_KEY doivent être définis (fichier .env).")
    print(f"URL FNE : {settings.fne_api_base_url} — modèle {args.template}")
    if not args.yes:
        sys.exit("Chaque appel consomme un sticker : relancez avec --yes pour confirmer.")

    out = Path(args.out) / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out.mkdir(parents=True, exist_ok=True)

    def save(name: str, data: object) -> None:
        (out / f"{name}.json").write_text(
            json.dumps(data, default=str, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    provider = HttpFneProvider(settings.fne_api_base_url, settings.fne_api_key)
    lines = [
        fne.FneLine(description=d, quantity=q, unit_price_ttc_xof=p, vat_rate=r, reference=ref)
        for d, q, p, r, ref in PROBE_LINES
    ]
    expected_ttc = sum(line.quantity * line.unit_price_ttc_xof for line in lines)
    try:
        request = fne.build_sale_request(
            lines=lines,
            client=fne.FneClient(
                company_name=args.client_name,
                phone=args.client_phone,
                email=args.client_email,
                ncc=args.client_ncc,
            ),
            template=fne.FneTemplate(args.template),
            payment_method="cash",
            issuer=fne.FneIssuer(
                point_of_sale=args.point_of_sale or settings.FNE_POINT_OF_SALE,
                establishment=args.establishment or settings.FNE_ESTABLISHMENT,
            ),
            ht_decimals=args.ht_decimals,
        )
    except fne.FneMappingError as exc:
        sys.exit(f"Requête invalide : {exc.detail}")
    save("1-sign-request", request)
    try:
        sale = provider.sign(request, timeout=args.timeout)
    except FneError as exc:
        save("1-sign-error", {"type": type(exc).__name__, "status": exc.status, "body": exc.body})
        sys.exit(f"Échec ({type(exc).__name__}) : {exc}\nDétails : {out}")
    save("1-sign-response", sale.raw)
    print(f"Facture certifiée : {sale.external_number}")
    print(f"QR (token)        : {sale.qr_payload}")
    print(f"TTC caisse / FNE  : {expected_ttc} / {sale.amount_ttc} (TVA FNE {sale.vat_amount})")
    print(f"Stickers restants : {sale.balance_sticker} (alerte : {sale.sticker_warning})")


def cmd_fne_worker(args: argparse.Namespace) -> None:
    """Renvoi automatique FNE : vide la file des documents échus toutes les
    `--interval` secondes, jusqu'à l'arrêt (SIGTERM/SIGINT). L'envoi en cours est terminé
    avant de s'arrêter : un document coupé en plein appel deviendrait incertain."""
    import caisse.cli
    from caisse.services import fne_service

    logger = logging.getLogger("caisse.fne_worker")
    stop = threading.Event()
    caisse.cli.signal.signal(caisse.cli.signal.SIGTERM, lambda *_: stop.set())
    caisse.cli.signal.signal(caisse.cli.signal.SIGINT, lambda *_: stop.set())
    provider = caisse.cli.get_fne_provider()
    if provider is None:
        print("FNE_PROVIDER=manual : aucun envoi automatique.")
        if not args.once:
            stop.wait()
        return

    print(f" fne_worker démarré (intervalle: {args.interval}s)")
    while not stop.is_set():
        try:
            with caisse.cli.SessionLocal() as db:
                while not stop.is_set() and fne_service.retry_next_due(db, provider):
                    pass
        except Exception as exc:
            logger.exception("fne_worker_error: %s", exc)
        if args.once:
            break
        stop.wait(args.interval)
    print(" fne_worker arrêté.")

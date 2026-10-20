"""Outils d'amorçage et de dépannage (04-EXPLOITATION-BACKEND §3 et §4).

python -m caisse.cli bootstrap
python -m caisse.cli create-user [--noinput]
python -m caisse.cli reset-pin --name "Awa"
python -m caisse.cli seed --demo
python -m caisse.cli create-tables --count 15 --zone Salle
python -m caisse.cli import-catalog [/data/menu.csv]     # défaut : seeds/data/menu.csv
python -m caisse.cli import-stock [--stock-initial]       # articles + fiches techniques
python -m caisse.cli set-vat-rate 0 --all-products
python -m caisse.cli create-print-terminal --name Comptoir   # jeton de l'agent d'impression
python -m caisse.cli fne-probe --point-of-sale "..." --client-phone ... --client-email ... --yes
python -m caisse.cli fne-probe ... --template B2B --client-ncc 9502363N --client-name "SOCIETE X"
"""

import argparse
import csv
import getpass
import json
import os
import sys
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from caisse.database import get_sessionmaker
from caisse.domain.enums import CategoryKind, UserRole
from caisse.domain.fne import FneTemplate
from caisse.errors import DomainError
from caisse.models.catalog import Category, Product
from caisse.models.settings import AppSetting
from caisse.models.table import RestaurantTable
from caisse.repositories import settings as settings_repo
from caisse.repositories import users as users_repo
from caisse.seeds import stock_import
from caisse.seeds.defaults import ensure_defaults
from caisse.services import audit_service, print_terminal_service, user_service
from caisse.services.audit_service import RequestContext

CLI_CTX = RequestContext(device_id="cli")


def _ask(prompt: str) -> str:
    value = input(prompt).strip()
    if not value:
        sys.exit("Valeur obligatoire.")
    return value


def _ask_pin() -> str:
    pin = getpass.getpass("PIN (6 chiffres) : ")
    if getpass.getpass("Confirmer le PIN : ") != pin:
        sys.exit("Les deux saisies diffèrent.")
    return pin


def cmd_bootstrap(db: Session, _: argparse.Namespace) -> None:
    ensure_defaults(db)
    db.commit()
    print("Caisse et paramètres par défaut en place.")


def cmd_create_user(db: Session, args: argparse.Namespace) -> None:
    if args.noinput:
        try:
            name = os.environ["CAISSE_USER_NAME"]
            role = os.environ["CAISSE_USER_ROLE"]
            pin = os.environ["CAISSE_USER_PIN"]
        except KeyError as exc:
            sys.exit(f"Variable d'environnement manquante : {exc.args[0]}")
    else:
        name = _ask("Nom complet : ")
        role = _ask("Rôle [CAISSIER/RESPONSABLE/ADMIN] : ").upper()
        pin = _ask_pin()
    try:
        user = user_service.create_user(
            db, full_name=name, role=UserRole(role.upper()), pin=pin, actor_id=None, ctx=CLI_CTX
        )
    except ValueError:
        sys.exit(f"Rôle inconnu : {role}")
    print(f"Utilisateur créé : {user.full_name} ({user.role}) — id {user.id}")


def cmd_reset_pin(db: Session, args: argparse.Namespace) -> None:
    matches = users_repo.find_by_name(db, args.name)
    if len(matches) != 1:
        sys.exit(f"{len(matches)} utilisateur(s) nommé(s) « {args.name} » : précisez.")
    user_service.set_pin(db, matches[0].id, _ask_pin(), actor_id=None, ctx=CLI_CTX)
    print(f"PIN réinitialisé pour {matches[0].full_name}.")


def cmd_seed(db: Session, args: argparse.Namespace) -> None:
    ensure_defaults(db)
    if args.demo:
        from caisse.seeds.demo import load_demo_menu

        created = load_demo_menu(db)
        _create_tables(db, 15, "Salle")
        print(f"Jeu de démonstration chargé ({created} produit(s) créé(s)).")
    db.commit()


def _create_tables(db: Session, count: int, zone: str) -> int:
    existing = set(db.scalars(select(RestaurantTable.label)))
    next_order = (db.scalar(select(func.max(RestaurantTable.sort_order))) or 0) + 1
    created = 0
    for n in range(1, count + 1):
        if str(n) not in existing:
            db.add(RestaurantTable(label=str(n), zone=zone, seats=4, sort_order=next_order))
            next_order += 1
            created += 1
    return created


def cmd_create_tables(db: Session, args: argparse.Namespace) -> None:
    created = _create_tables(db, args.count, args.zone)
    db.commit()
    print(f"{created} table(s) créée(s).")


def cmd_import_catalog(db: Session, args: argparse.Namespace) -> None:
    """CSV : categorie,nom,prix_xof,suivi_stock,groupe_fiscal[,nom_ticket] (en-tête
    obligatoire). L'ordre du fichier donne l'ordre d'affichage ; `suivi_stock` marque une
    catégorie de boissons (le déstockage vient des fiches techniques : `import-stock`)."""
    path = Path(args.csv)
    created = 0
    vat_rate = settings_repo.default_vat_rate(db)
    category_order: dict[str, int] = {}
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for line_no, row in enumerate(csv.DictReader(fh), start=2):
            try:
                cat_name = row["categorie"].strip()
                name = row["nom"].strip()
                price = int(row["prix_xof"])
                drink = row["suivi_stock"].strip().lower() in {"1", "oui", "true", "o", "x"}
                group = (row.get("groupe_fiscal") or "AUTRES").strip().upper()
                short_name = (row.get("nom_ticket") or "").strip() or name
            except (KeyError, ValueError) as exc:
                sys.exit(f"Ligne {line_no} invalide : {exc}")
            if len(short_name) > 20:
                sys.exit(f"Ligne {line_no} invalide : nom_ticket de plus de 20 caractères")
            category_order.setdefault(cat_name, len(category_order))
            category = db.scalar(select(Category).where(Category.name == cat_name))
            if category is None:
                category = Category(
                    name=cat_name,
                    fiscal_group=group,
                    kind=CategoryKind.DRINK if drink else CategoryKind.FOOD,
                    sort_order=category_order[cat_name],
                )
                db.add(category)
                db.flush()
            if db.scalar(select(Product).where(Product.name == name)) is not None:
                continue
            db.add(
                Product(
                    category_id=category.id,
                    name=name,
                    short_name=short_name,
                    price_xof=price,
                    vat_rate=vat_rate,
                    sort_order=line_no,
                )
            )
            created += 1
    db.commit()
    print(f"{created} produit(s) importé(s).")


def cmd_import_stock(db: Session, args: argparse.Namespace) -> None:
    """Articles puis fiches techniques ; les produits du menu doivent déjà exister."""
    try:
        articles = stock_import.import_articles(
            db, Path(args.articles), initial_stock=args.stock_initial
        )
        products = stock_import.import_components(db, Path(args.fiches))
    except stock_import.StockImportError as exc:
        db.rollback()
        sys.exit(f"Erreur : {exc}")
    audit_service.log(
        db,
        "stock.import",
        ctx=CLI_CTX,
        entity="stock_article",
        after={
            "articles_created": articles.created,
            "articles_skipped": articles.skipped,
            "initial_counts": articles.initial_counts,
            "products_with_recipe": products,
        },
    )
    db.commit()
    print(
        f"Articles : {articles.created} créé(s), {articles.skipped} déjà présent(s) ; "
        f"stock de départ : {articles.initial_counts} article(s) ; "
        f"fiches techniques : {products} produit(s)."
    )


def cmd_create_print_terminal(db: Session, args: argparse.Namespace) -> None:
    _, token = print_terminal_service.create_terminal(
        db, name=args.name, actor_id=None, ctx=CLI_CTX
    )
    print(f"Terminal « {args.name} » créé. Jeton de l'agent (affiché une seule fois) :")
    print(token)


def cmd_set_vat_rate(db: Session, args: argparse.Namespace) -> None:
    """Taux de TVA par défaut (`vat.default_rate`) et, avec `--all-products`, taux de tous les
    produits. Les commandes déjà saisies gardent le taux figé sur leurs lignes."""
    try:
        rate = Decimal(args.rate).quantize(Decimal("0.01"))
    except ArithmeticError:
        sys.exit(f"Taux invalide : {args.rate}")
    if not Decimal(0) <= rate < Decimal(100):
        sys.exit("Le taux doit être compris entre 0 et 99,99.")
    setting = db.get(AppSetting, "vat.default_rate")
    before = setting.value if setting else None
    if setting is None:
        db.add(AppSetting(key="vat.default_rate", value=str(rate)))
    else:
        setting.value = str(rate)
    changed = 0
    if args.all_products:
        for product in db.scalars(select(Product).where(Product.vat_rate != rate)):
            product.vat_rate = rate
            changed += 1
    audit_service.log(
        db,
        "settings.vat_rate",
        ctx=CLI_CTX,
        entity="settings",
        entity_id="vat.default_rate",
        before={"vat.default_rate": before},
        after={"vat.default_rate": str(rate), "products_changed": changed},
    )
    db.commit()
    print(f"Taux par défaut : {rate} %. Produits modifiés : {changed}.")


PROBE_LINES = [
    # TTC attendu : 2 x 3 500 + 1 x 1 000 = 8 000 XOF
    ("Poisson braisé", 2, 3500, Decimal("18"), "PROBE-01"),
    ("Eau minérale 1,5 L", 1, 1000, Decimal("0"), "PROBE-02"),
]


def cmd_fne_probe(args: argparse.Namespace) -> None:
    """Sonde de l'environnement FNE de test (PLAN-FNE phase 1) : une facture (B2C par défaut,
    ou B2B avec `--client-ncc`), puis éventuellement un avoir d'une unité sur le premier article.
    Requêtes et réponses sont écrites dans `--out` (sans la clé API)."""
    from caisse.config import get_settings
    from caisse.domain import fne
    from caisse.domain.ports import FneError
    from caisse.infrastructure.fne import HttpFneProvider

    settings = get_settings()
    if not settings.fne_api_base_url or not settings.fne_api_key:
        sys.exit("FNE_API_BASE_URL et FNE_API_KEY doivent être définis (fichier .env).")
    print(f"URL FNE : {settings.fne_api_base_url} — modèle {args.template}")
    if not args.yes:
        sys.exit("Chaque appel consomme un sticker : relancez avec --yes pour confirmer.")

    out = Path(args.out) / datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
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
                point_of_sale=args.point_of_sale, establishment=args.establishment
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
    print(f"Solde FNE (XOF)   : {sale.balance_funds_xof} (alerte : {sale.low_balance_warning})")

    if args.refund:
        if not sale.invoice_id or not sale.items:
            sys.exit("Réponse sans invoice.id ou items[].id : avoir impossible.")
        refund_request = fne.build_refund_request([(sale.items[0].id, 1)])
        save("2-refund-request", {"invoice_id": sale.invoice_id, **refund_request})
        try:
            credit = provider.refund(sale.invoice_id, refund_request, timeout=args.timeout)
        except FneError as exc:
            save(
                "2-refund-error",
                {"type": type(exc).__name__, "status": exc.status, "body": exc.body},
            )
            sys.exit(f"Échec de l'avoir ({type(exc).__name__}) : {exc}\nDétails : {out}")
        save("2-refund-response", credit.raw)
        print(f"Avoir certifié    : {credit.external_number}")
    print(f"Traces : {out}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="caisse.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("bootstrap", help="Caisse n° 1 + paramètres par défaut")
    p = sub.add_parser("create-user", help="Créer un utilisateur (PIN)")
    p.add_argument(
        "--noinput",
        action="store_true",
        help="lit CAISSE_USER_NAME / CAISSE_USER_ROLE / CAISSE_USER_PIN",
    )
    p = sub.add_parser("reset-pin", help="Réinitialiser un PIN")
    p.add_argument("--name", required=True)
    p = sub.add_parser("seed", help="Données initiales")
    p.add_argument("--demo", action="store_true", help="menu et tables de démonstration")
    p = sub.add_parser("create-tables", help="Créer les tables de la salle")
    p.add_argument("--count", type=int, required=True)
    p.add_argument("--zone", default="Salle")
    p = sub.add_parser("import-catalog", help="Importer le menu depuis un CSV")
    p.add_argument("csv", nargs="?", default=str(stock_import.DATA_DIR / "menu.csv"))
    p = sub.add_parser("import-stock", help="Importer les articles et les fiches techniques")
    p.add_argument("--articles", default=str(stock_import.ARTICLES_CSV))
    p.add_argument("--fiches", default=str(stock_import.COMPONENTS_CSV))
    p.add_argument(
        "--stock-initial",
        action="store_true",
        help="inventaire de départ avec la colonne stock_excel_13_10 (articles créés)",
    )
    p = sub.add_parser("set-vat-rate", help="Taux de TVA par défaut (et des produits)")
    p.add_argument("rate", help="en %, ex. 0 (régime TEE) ou 18")
    p.add_argument("--all-products", action="store_true", help="appliquer à tous les produits")
    p = sub.add_parser("create-print-terminal", help="Jeton de l'agent d'impression d'un poste")
    p.add_argument("--name", required=True)
    p = sub.add_parser("fne-probe", help="Sonde de l'API FNE de test (consomme des stickers)")
    p.add_argument("--point-of-sale", required=True, help="tel que configuré dans l'espace FNE")
    p.add_argument(
        "--establishment",
        default="RESTAURANT CHEZ SYLLA PLUS",
        help="tel que configuré dans l'espace FNE",
    )
    p.add_argument("--template", choices=[t.value for t in FneTemplate], default="B2C")
    p.add_argument("--client-name", default="CLIENT DIVERS")
    p.add_argument("--client-ncc", help="NCC du client, obligatoire en B2B")
    p.add_argument("--client-phone", required=True)
    p.add_argument("--client-email", required=True)
    p.add_argument("--ht-decimals", type=int, default=4, help="précision du prix HT envoyé")
    p.add_argument("--refund", action="store_true", help="enchaîner un avoir d'une unité")
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--out", default="fne-probe", help="dossier des traces")
    p.add_argument("--yes", action="store_true", help="confirme l'envoi réel")

    args = parser.parse_args(argv)
    if args.command == "fne-probe":  # aucun accès base
        cmd_fne_probe(args)
        return
    handler = {
        "bootstrap": cmd_bootstrap,
        "create-user": cmd_create_user,
        "reset-pin": cmd_reset_pin,
        "seed": cmd_seed,
        "create-tables": cmd_create_tables,
        "import-catalog": cmd_import_catalog,
        "import-stock": cmd_import_stock,
        "set-vat-rate": cmd_set_vat_rate,
        "create-print-terminal": cmd_create_print_terminal,
    }[args.command]
    with get_sessionmaker()() as db:
        try:
            handler(db, args)
        except DomainError as exc:
            sys.exit(f"Erreur : {exc.detail}")


if __name__ == "__main__":
    main()

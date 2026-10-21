import argparse
import csv
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import sys
from sqlalchemy import select

from caisse.database import SessionLocal
from caisse.models.catalog import Category, Product
from caisse.models.settings import AppSetting
from caisse.models.table import RestaurantTable
from caisse.services.auth_service import AuthService
from caisse.repositories.sessions import CashSessionRepository
from caisse.seeds.demo_data import seed_catalog_and_tables

PROBE_LINES = [
    # TTC attendu : 2 x 3 500 + 1 x 1 000 = 8 000 XOF
    ("Poisson braisé", 2, 3500, Decimal("0"), "PROBE-01"),
    ("Eau minérale 1,5 L", 1, 1000, Decimal("0"), "PROBE-02"),
]


def cmd_set_vat_rate(db, args: argparse.Namespace) -> None:
    try:
        rate = Decimal(args.rate).quantize(Decimal("0.01"))
    except Exception:
        sys.exit(f"Taux invalide : {args.rate}")
    if not Decimal(0) <= rate < Decimal(100):
        sys.exit("Le taux doit être compris entre 0 et 99,99.")
    setting = db.get(AppSetting, "vat.default_rate")
    if setting is None:
        db.add(AppSetting(key="vat.default_rate", value=str(rate)))
    else:
        setting.value = str(rate)
    changed = 0
    if args.all_products:
        for product in db.scalars(select(Product)):
            product.vat_rate = float(rate)
            changed += 1
    db.commit()
    print(f"✅ Taux par défaut : {rate} %. Produits modifiés : {changed}.")


def cmd_fne_probe(args: argparse.Namespace) -> None:
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


def main() -> None:
    parser = argparse.ArgumentParser(description="CLI d'administration de la Caisse MYK")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Commande create-user
    user_parser = subparsers.add_parser("create-user", help="Créer un nouvel utilisateur")
    user_parser.add_argument("--name", help="Nom complet de l'utilisateur")
    user_parser.add_argument("--role", choices=["CAISSIER", "RESPONSABLE", "ADMIN"], help="Rôle")
    user_parser.add_argument("--pin", help="Code PIN (6 chiffres)")
    user_parser.add_argument("--noinput", action="store_true", help="Mode non interactif")

    # Commande reset-pin
    reset_parser = subparsers.add_parser("reset-pin", help="Réinitialiser le code PIN")
    reset_parser.add_argument("--name", required=True, help="Nom complet de l'utilisateur")
    reset_parser.add_argument("--new-pin", help="Nouveau code PIN")

    # Commande seed
    seed_parser = subparsers.add_parser("seed", help="Initialiser les données de test / démo")
    seed_parser.add_argument("--demo", action="store_true", help="Charger les données de démonstration")

    # Commande import-catalog
    import_parser = subparsers.add_parser("import-catalog", help="Importer le catalogue depuis un fichier CSV")
    import_parser.add_argument("file", nargs="?", default=None, help="Chemin du fichier CSV (défaut : seeds/data/menu.csv)")

    # Commande create-tables
    tables_parser = subparsers.add_parser("create-tables", help="Générer des tables de salle")
    tables_parser.add_argument("--count", type=int, default=15, help="Nombre de tables à générer")
    tables_parser.add_argument("--zone", default="Salle", help="Nom de la zone")

    # Commande set-vat-rate
    vat_parser = subparsers.add_parser("set-vat-rate", help="Changer le taux de TVA par défaut")
    vat_parser.add_argument("rate", help="Taux de TVA (ex: 0 pour TEE, 18 pour taux standard)")
    vat_parser.add_argument("--all-products", action="store_true", help="Appliquer à tous les produits existants")

    # Commande fne-probe
    probe_parser = subparsers.add_parser("fne-probe", help="Tester la connexion API FNE DGI")
    probe_parser.add_argument("--point-of-sale", default="CAISSE-1", help="Point de vente FNE")
    probe_parser.add_argument("--establishment", default="RESTAURANT CHEZ SYLLA PLUS", help="Nom établissement")
    probe_parser.add_argument("--template", choices=["B2C", "B2B"], default="B2C", help="Modèle fiscal")
    probe_parser.add_argument("--client-name", default="CLIENT DIVERS", help="Nom client")
    probe_parser.add_argument("--client-phone", default="0748735573", help="Téléphone client")
    probe_parser.add_argument("--client-email", default="restaurantmykpro@gmail.com", help="Email client")
    probe_parser.add_argument("--client-ncc", default=None, help="NCC client (en B2B)")
    probe_parser.add_argument("--ht-decimals", type=int, default=4, help="Décimales HT")
    probe_parser.add_argument("--timeout", type=float, default=5.0, help="Timeout en secondes")
    probe_parser.add_argument("--out", default="fne-probe", help="Répertoire de sortie")
    # Commande import-stock
    stock_parser = subparsers.add_parser("import-stock", help="Importer les articles de stock et fiches techniques")
    stock_parser.add_argument("--stock-initial", action="store_true", help="Charger le stock de départ du classeur Excel")
    stock_parser.add_argument("--articles-csv", default=None, help="Chemin alternatif vers articles.csv")
    stock_parser.add_argument("--fiches-csv", default=None, help="Chemin alternatif vers fiches_techniques.csv")

    args = parser.parse_args()

    if args.command == "fne-probe":
        cmd_fne_probe(args)
        return

    if args.command == "outbox-worker":
        from caisse.infrastructure.outbox.worker import run_outbox_worker_sync
        run_outbox_worker_sync(once=args.once, interval_seconds=args.interval)
        return

    db = SessionLocal()
    auth_service = AuthService(db)
    session_repo = CashSessionRepository(db)

    try:
        if args.command == "set-vat-rate":
            cmd_set_vat_rate(db, args)

        elif args.command == "create-user":
            if args.noinput or (args.name and args.role and args.pin):
                name = args.name or sys.stdin.readline().strip()
                role = args.role or "CAISSIER"
                pin = args.pin or "123456"
            else:
                name = input("Nom complet : ").strip()
                role = input("Rôle [CAISSIER/RESPONSABLE/ADMIN] : ").strip().upper()
                pin = input("PIN (6 chiffres) : ").strip()

            user = auth_service.create_user(full_name=name, pin=pin, role=role)
            print(f"✅ Utilisateur '{user.full_name}' ({user.role}) créé avec succès. ID: {user.id}")

        elif args.command == "reset-pin":
            user = auth_service.user_repo.get_by_name(args.name)
            if not user:
                print(f"❌ Utilisateur '{args.name}' introuvable.")
                sys.exit(1)
            new_pin = args.new_pin or input(f"Nouveau PIN pour {user.full_name} : ").strip()
            from caisse.security import hash_pin
            user.pin_hash = hash_pin(new_pin)
            user.failed_attempts = 0
            user.locked_until = None
            db.commit()
            print(f"✅ PIN de '{user.full_name}' réinitialisé avec succès.")

        elif args.command == "seed":
            session_repo.get_or_create_default_register()
            if not auth_service.user_repo.list_all():
                auth_service.create_user("Caissière Principale", "111111", "CAISSIER")
                auth_service.create_user("Responsable Restaurant", "222222", "RESPONSABLE")
                auth_service.create_user("Administrateur", "999999", "ADMIN")
                print("✅ Utilisateurs de démo créés (Caissière: 111111, Responsable: 222222, Admin: 999999).")
            seed_catalog_and_tables(db)
            print("✅ Caisse, menu et tables de base initialisés avec succès.")

        elif args.command == "create-tables":
            created_count = 0
            for i in range(1, args.count + 1):
                label = f"Table {i}"
                if not db.query(RestaurantTable).filter(RestaurantTable.label == label).first():
                    t = RestaurantTable(
                        label=label,
                        zone=args.zone,
                        seats=4,
                        sort_order=i,
                        is_active=True,
                    )
                    db.add(t)
                    created_count += 1
            db.commit()
            print(f"✅ {created_count} tables créées dans la zone '{args.zone}'.")

        elif args.command == "import-catalog":
            menu_file = args.file or (Path(__file__).parent / "seeds" / "data" / "menu.csv")
            with open(menu_file, encoding="utf-8") as f:
                reader = csv.DictReader(f)
                count = 0
                for row in reader:
                    cat_name = row["categorie"].strip()
                    category = db.query(Category).filter(Category.name == cat_name).first()
                    if not category:
                        category = Category(
                            name=cat_name,
                            kind="DRINK" if "boisson" in cat_name.lower() or "eau" in cat_name.lower() else "FOOD",
                            fiscal_group=row.get("groupe_fiscal", "PLATS"),
                        )
                        db.add(category)
                        db.flush()

                    short_name = (row.get("nom_court") or row.get("nom_ticket") or row["nom"][:20]).strip()
                    track_stock = row.get("suivi_stock", "false").lower() in ("true", "1", "oui")

                    prod = db.query(Product).filter(Product.name == row["nom"].strip()).first()
                    if not prod:
                        prod = Product(
                            category_id=category.id,
                            name=row["nom"].strip(),
                            short_name=short_name,
                            price_xof=int(row["prix_xof"]),
                            track_stock=track_stock,
                        )
                        db.add(prod)
                        count += 1
                db.commit()
                print(f"✅ {count} produits importés avec succès depuis '{menu_file}'.")

        elif args.command == "import-stock":
            from caisse.seeds.stock_import import import_articles, import_components, ARTICLES_CSV, COMPONENTS_CSV
            art_path = Path(args.articles_csv) if args.articles_csv else ARTICLES_CSV
            comp_path = Path(args.fiches_csv) if args.fiches_csv else COMPONENTS_CSV
            res = import_articles(db, art_path, initial_stock=args.stock_initial)
            comps = import_components(db, comp_path)
            db.commit()
            print(f"✅ Stock importé : {res.created} créés, {res.skipped} existants, {res.initial_counts} comptages initiaux, {comps} fiches techniques.")

    finally:
        db.close()


if __name__ == "__main__":
    main()

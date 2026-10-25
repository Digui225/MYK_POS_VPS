import argparse

from caisse.cli.commands.catalog import (
    cmd_import_catalog,
    cmd_import_stock,
    cmd_set_vat_rate,
)
from caisse.cli.commands.db import (
    cmd_create_tables,
    cmd_reset_transactions,
    cmd_seed,
    cmd_seed_weekly_flow,
)
from caisse.cli.commands.fne import cmd_fne_probe, cmd_fne_worker
from caisse.cli.commands.users import cmd_create_user, cmd_reset_pin
from caisse.cli.commands.workers import cmd_create_print_terminal, cmd_outbox_worker
from caisse.core.database import SessionLocal


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CLI d'administration de la Caisse MYK")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Commande create-user
    user_parser = subparsers.add_parser("create-user", help="Créer un nouvel utilisateur")
    user_parser.add_argument("--name", help="Nom complet de l'utilisateur")
    user_parser.add_argument("--role", choices=["CAISSIER", "RESPONSABLE", "ADMIN", "ECONOME"], help="Rôle")
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

    # Commande create-print-terminal
    terminal_parser = subparsers.add_parser("create-print-terminal", help="Jeton de l'agent d'impression d'un poste")
    terminal_parser.add_argument("--name", required=True, help="Nom du poste (ex: Comptoir)")

    # Commande fne-worker
    fne_worker_parser = subparsers.add_parser("fne-worker", help="Renvoi automatique des FNE en file (service)")
    fne_worker_parser.add_argument("--interval", type=float, default=30.0, help="Secondes entre deux passages")
    fne_worker_parser.add_argument("--once", action="store_true", help="Un seul passage, puis arrêt")

    # Commande outbox-worker
    outbox_worker_parser = subparsers.add_parser("outbox-worker", help="Worker d'arrière-plan Outbox")
    outbox_worker_parser.add_argument("--interval", type=float, default=5.0, help="Secondes entre deux passages")
    outbox_worker_parser.add_argument("--once", action="store_true", help="Un seul passage, puis arrêt")

    # Commande reset-transactions
    reset_tx_parser = subparsers.add_parser(
        "reset-transactions",
        help="Vider toutes les transactions (ventes, caisses, mouvements, achats) et remettre le stock à 0",
    )
    reset_tx_parser.add_argument(
        "--yes", "-y", action="store_true", help="Confirmer automatiquement sans invite interactive"
    )

    # Commande seed-weekly-flow
    seed_flow_parser = subparsers.add_parser(
        "seed-weekly-flow",
        help="Générer des données cohérentes Achat économe -> Ventes pour tester la matrice hebdomadaire",
    )
    seed_flow_parser.add_argument(
        "--monday",
        default="2026-10-19",
        help="Date du lundi de la semaine à tester (YYYY-MM-DD, défaut: 2026-10-19)",
    )

    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    # Commandes sans besoin de session BD permanente
    if args.command == "fne-probe":
        cmd_fne_probe(args)
        return

    if args.command == "fne-worker":
        cmd_fne_worker(args)
        return

    if args.command == "outbox-worker":
        cmd_outbox_worker(args)
        return

    # Commandes avec session BD
    db = SessionLocal()
    try:
        if args.command == "set-vat-rate":
            cmd_set_vat_rate(db, args)
        elif args.command == "create-user":
            cmd_create_user(db, args)
        elif args.command == "reset-pin":
            cmd_reset_pin(db, args)
        elif args.command == "seed":
            cmd_seed(db, args)
        elif args.command == "create-tables":
            cmd_create_tables(db, args)
        elif args.command == "import-catalog":
            cmd_import_catalog(db, args)
        elif args.command == "import-stock":
            cmd_import_stock(db, args)
        elif args.command == "create-print-terminal":
            cmd_create_print_terminal(db, args)
        elif args.command == "reset-transactions":
            cmd_reset_transactions(db, args)
        elif args.command == "seed-weekly-flow":
            cmd_seed_weekly_flow(db, args)
    finally:
        db.close()


if __name__ == "__main__":
    main()

import argparse
import sys
from datetime import date
from decimal import Decimal

from sqlalchemy.orm import Session

from caisse.core.config import get_settings
from caisse.models.table import RestaurantTable
from caisse.repositories.sessions import CashSessionRepository
from caisse.seeds.demo_data import seed_catalog_and_tables
from caisse.services.auth_service import AuthService


def cmd_seed(db: Session, args: argparse.Namespace) -> None:
    auth_service = AuthService(db)
    session_repo = CashSessionRepository(db)
    session_repo.get_or_create_default_register()
    if not auth_service.user_repo.list_all():
        auth_service.create_user("Caissière Principale", "111111", "CAISSIER")
        auth_service.create_user("Responsable Restaurant", "222222", "RESPONSABLE")
        auth_service.create_user("Administrateur", "999999", "ADMIN")
        auth_service.create_user("Économe Marché", "112233", "ECONOME")
        print(
            " Utilisateurs de démo créés "
            "(Caissière: 111111, Responsable: 222222, Admin: 999999, Économe: 112233)."
        )
    seed_catalog_and_tables(db)
    print(" Caisse, menu et tables de base initialisés avec succès.")


def cmd_create_tables(db: Session, args: argparse.Namespace) -> None:
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
    print(f" {created_count} tables créées dans la zone '{args.zone}'.")


def cmd_reset_transactions(db: Session, args: argparse.Namespace) -> None:
    import caisse.cli

    settings = caisse.cli.get_settings()
    if settings.APP_ENV == "production":
        print(
            " ERREUR CRITIQUE : La commande reset-transactions est STRICTEMENT INTERDITE en environnement de production."
        )
        sys.exit(1)

    if not args.yes:
        confirm = input(
            "  Cette opération va supprimer toutes les transactions (commandes, caisses, "
            "mouvements de stock, achats marché) et remettre le stock à zéro en conservant "
            "le catalogue et les fiches recettes. Confirmer ? (oui/non) : "
        )
        if confirm.strip().lower() not in ("oui", "o", "yes", "y"):
            print("Annulé.")
            return

    from caisse.models.audit import AuditLog
    from caisse.models.cash_session import CashMovement, CashSession
    from caisse.models.finance import BankDeposit, CashExpense
    from caisse.models.fne import FneDocument
    from caisse.models.idempotency import IdempotencyRecord
    from caisse.models.order import Order, OrderItem
    from caisse.models.outbox import OutboxEvent
    from caisse.models.payment import Payment
    from caisse.models.print_job import PrintJob
    from caisse.models.production import DailyPreparation, MarketPurchaseItem, MarketPurchaseList
    from caisse.models.purchase import PurchaseRequest, PurchaseRequestLine
    from caisse.models.stock import StockArticle, StockMovement

    # 1. Supprimer les éléments dépendants des commandes et sessions
    pj_count = db.query(PrintJob).delete()
    sm_count = db.query(StockMovement).delete()
    fne_count = db.query(FneDocument).delete()
    pay_count = db.query(Payment).delete()
    oi_count = db.query(OrderItem).delete()
    ord_count = db.query(Order).delete()

    # 2. Supprimer les éléments de caisse
    cm_count = db.query(CashMovement).delete()
    ce_count = db.query(CashExpense).delete()
    bd_count = db.query(BankDeposit).delete()
    cs_count = db.query(CashSession).delete()

    # 3. Supprimer les achats marché, sorties cuisine et demandes d'achat
    dp_count = db.query(DailyPreparation).delete()
    mpi_count = db.query(MarketPurchaseItem).delete()
    mpl_count = db.query(MarketPurchaseList).delete()
    prl_count = db.query(PurchaseRequestLine).delete()
    pr_count = db.query(PurchaseRequest).delete()

    # 4. Supprimer les files et idempotence (l'historique d'audit est conservé pour conformité)
    ob_count = db.query(OutboxEvent).delete()
    idem_count = db.query(IdempotencyRecord).delete()

    # 5. Remettre la quantité des articles de stock à 0
    art_count = db.query(StockArticle).update({StockArticle.quantity: Decimal(0)})

    # 6. Tracer l'opération dans l'AuditLog
    reset_audit = AuditLog(
        action="RESET_TRANSACTIONS",
        entity="SYSTEM",
        reason="Réinitialisation des transactions via CLI",
        after={
            "deleted_orders": ord_count,
            "deleted_order_items": oi_count,
            "deleted_payments": pay_count,
            "deleted_print_jobs": pj_count,
            "deleted_fne": fne_count,
            "deleted_sessions": cs_count,
            "deleted_cash_movements": cm_count,
            "deleted_expenses": ce_count,
            "deleted_bank_deposits": bd_count,
            "deleted_market_purchases": mpl_count,
            "deleted_preparations": dp_count,
            "deleted_purchase_requests": pr_count,
            "deleted_purchase_request_lines": prl_count,
            "deleted_outbox_events": ob_count,
            "deleted_idempotency_records": idem_count,
            "deleted_stock_movements": sm_count,
            "reset_stock_articles": art_count,
        },
    )
    db.add(reset_audit)
    db.commit()

    print(" Réinitialisation des transactions terminée avec succès :")
    print(f"   - Commandes supprimées : {ord_count} (avec {oi_count} lignes, {pay_count} paiements, {fne_count} FNE)")
    print(f"   - Sessions de caisse supprimées : {cs_count} (avec {cm_count} mouvements, {ce_count} dépenses)")
    print(f"   - Bons d'achat marché supprimés : {mpl_count} ({mpi_count} lignes)")
    print(f"   - Sorties cuisine supprimées : {dp_count}")
    print(f"   - Mouvements de stock supprimés : {sm_count}")
    print(f"   - Quantités de stock remises à 0 : {art_count} articles")
    print("   - Fiches recettes (ProductComponents) : conservées intactes")
    print("   - Catalogue produits et tables : conservés intacts")
    print("   - Audit log : tracé avec l'événement RESET_TRANSACTIONS")


def cmd_seed_weekly_flow(db: Session, args: argparse.Namespace) -> None:
    from caisse.seeds.seed_weekly_flow import seed_weekly_flow

    m_date = date.fromisoformat(args.monday)
    flow_res = seed_weekly_flow(db, monday_date=m_date)
    print(" Données de simulation générées avec succès :")
    print(f"   - Période : du {flow_res['start_date']} au {flow_res['end_date']}")
    print(f"   - Total achats économe : {flow_res['total_purchases_xof']:,} XOF (Plafond <= 300 000 XOF)")
    print(f"   - Total plats vendus : {flow_res['total_dishes_sold']} plats")
    print(f"   - Chiffre d'affaires réalisé : {flow_res['total_sales_xof']:,} XOF")
    print(f"   - Écarts portions : {flow_res['variance_dishes']} (Perte valorisée : {flow_res['variance_loss_xof']:,} XOF)")

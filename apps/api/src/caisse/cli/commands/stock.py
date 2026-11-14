"""Commandes de stock : recalage de la date d'entrée en stock d'un bon d'achat marché (D13)."""

import argparse
import sys
from datetime import date

from sqlalchemy.orm import Session

from caisse.models.production import MarketPurchaseList
from caisse.models.user import User
from caisse.services.production_service import redate_market_reception


def _find_purchase(db: Session, args: argparse.Namespace) -> MarketPurchaseList:
    query = db.query(MarketPurchaseList).filter(MarketPurchaseList.status == "COMPLETED")
    if args.id:
        query = query.filter(MarketPurchaseList.id == args.id)
    else:
        query = query.filter(MarketPurchaseList.business_date == date.fromisoformat(args.bon_date))
    found = query.all()
    if len(found) != 1:
        print(f" {len(found)} bon(s) réceptionné(s) trouvé(s) : précisez --id.")
        for p in found:
            print(f"   {p.id}  bon du {p.business_date}  en stock le {p.stock_date or p.business_date}")
        sys.exit(1)
    return found[0]


def cmd_redate_reception(db: Session, args: argparse.Namespace) -> None:
    if not args.id and not args.bon_date:
        print(" Indiquez --bon-date AAAA-MM-JJ ou --id.")
        sys.exit(1)
    purchase = _find_purchase(db, args)
    new_date = date.fromisoformat(args.to)
    old_date = purchase.stock_date or purchase.business_date
    print(f" Bon du {purchase.business_date} ({purchase.id})")
    print(f" Entrée en stock : {old_date} → {new_date}")
    for item in purchase.items:
        qty = item.received_quantity if item.received_quantity is not None else item.quantity
        name = item.article.name if item.article else item.article_id
        print(f"   {name} : {qty} à {item.unit_price_xof} XOF")
    if purchase.include_condiments_envelope:
        print("   + kit condiments du bon")
    if old_date == new_date:
        print(" Déjà à cette date : rien à faire.")
        return
    if not args.apply:
        print(" Simulation : rien n'est écrit. Relancez avec --apply pour appliquer.")
        return

    user = db.query(User).filter(User.full_name == args.by, User.is_active.is_(True)).first()
    if user is None:
        print(f" Utilisateur actif '{args.by}' introuvable.")
        sys.exit(1)
    moves = redate_market_reception(
        db, str(purchase.id), new_date, user_id=str(user.id), reason=args.reason
    )
    print(f" Recalé : {len(moves)} article(s), un retrait le {old_date} et une entrée le {new_date} chacun.")

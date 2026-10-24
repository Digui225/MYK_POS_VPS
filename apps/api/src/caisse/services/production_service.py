from datetime import date, timedelta
from decimal import Decimal
from typing import Optional

from fastapi import status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload

from caisse.domain.enums import (
    CashSessionStatus,
    OrderStatus,
    StockArticleCategory,
    StockMovementType,
    StockOutMode,
)
from caisse.domain.production_rules import (
    calculate_dish_variance,
    calculate_financial_impact,
    calculate_item_total,
    calculate_theoretical_dishes,
)
from caisse.domain.stock_rules import weighted_average_cost
from caisse.errors import CaisseException
from caisse.models.cash_session import CashMovement, CashSession
from caisse.models.finance import CashExpense
from caisse.models.order import Order, OrderItem
from caisse.models.production import (
    DailyPreparation,
    MarketPurchaseItem,
    MarketPurchaseList,
)
from caisse.models.stock import ProductComponent, StockArticle, StockMovement
from caisse.models.user import User
from caisse.schemas.production import (
    DailyPreparationCreate,
    DailyPreparationOut,
    MarketBudgetStatusOut,
    MarketPurchaseItemOut,
    MarketPurchaseListCreate,
    MarketPurchaseListOut,
    WeeklyDayData,
    WeeklyMatrixReportOut,
    WeeklyProductRow,
)

DAY_NAMES_FR = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]


def _format_purchase_out(purchase: MarketPurchaseList) -> MarketPurchaseListOut:
    return MarketPurchaseListOut(
        id=str(purchase.id),
        business_date=purchase.business_date,
        status=purchase.status,
        created_by_user_id=str(purchase.created_by_user_id),
        created_by_user_name=purchase.created_by.full_name if purchase.created_by else "—",
        validated_by_user_id=str(purchase.validated_by_user_id) if purchase.validated_by_user_id else None,
        validated_by_user_name=purchase.validated_by.full_name if purchase.validated_by else None,
        total_budget_xof=purchase.total_budget_xof,
        notes=purchase.notes,
        created_at=purchase.created_at,
        items=[
            MarketPurchaseItemOut(
                id=str(item.id),
                article_id=str(item.article_id),
                article_name=item.article.name if item.article else "—",
                unit=item.article.unit if item.article else "—",
                quantity=float(item.quantity),
                unit_price_xof=item.unit_price_xof,
                total_price_xof=item.total_price_xof,
            )
            for item in purchase.items
        ],
    )


def create_market_purchase(
    db: Session, user: User, data: MarketPurchaseListCreate
) -> MarketPurchaseListOut:
    """Crée une nouvelle liste d'achats prévisionnels pour le marché.
    Si un article n'existe pas encore en base (nouvel article de l'économe ou protéine prioritaire),
    il est créé automatiquement en stock."""
    purchase = MarketPurchaseList(
        business_date=data.business_date,
        status="DRAFT",
        created_by_user_id=user.id,
        notes=data.notes,
        total_budget_xof=0,
    )
    db.add(purchase)
    db.flush()

    total_budget = 0
    for item_in in data.items:
        art = None
        if item_in.article_id and not item_in.article_id.startswith("proto-"):
            art = db.query(StockArticle).filter(StockArticle.id == item_in.article_id).first()

        if not art:
            art_name = (item_in.custom_article_name or "").strip()
            if not art_name and item_in.article_id and item_in.article_id.startswith("proto-"):
                art_name = item_in.article_id.replace("proto-", "").strip()

            if not art_name:
                raise CaisseException(
                    code="ARTICLE_NOT_FOUND",
                    title="Article introuvable",
                    detail=f"Article de stock {item_in.article_id} introuvable et aucun nom fourni",
                    status_code=status.HTTP_404_NOT_FOUND,
                )

            # Vérifier si un article avec ce nom existe déjà (insensible à la casse)
            existing_art = (
                db.query(StockArticle)
                .filter(func.lower(StockArticle.name) == func.lower(art_name))
                .first()
            )
            if existing_art:
                art = existing_art
            else:
                cat_str = (item_in.category or "EPICERIE").upper()
                try:
                    cat_enum = StockArticleCategory(cat_str)
                except ValueError:
                    cat_enum = StockArticleCategory.EPICERIE

                unit_str = (item_in.unit or "kg").strip()

                art = StockArticle(
                    name=art_name,
                    category=cat_enum,
                    unit=unit_str,
                    out_mode=StockOutMode.INVENTORY,
                    quantity=Decimal(0),
                    avg_cost_xof=Decimal(item_in.unit_price_xof),
                    is_active=True,
                    note="Créé automatiquement par l'Économe (Bon d'achat marché)",
                )
                db.add(art)
                db.flush()

        line_total = calculate_item_total(
            Decimal(str(item_in.quantity)), item_in.unit_price_xof
        )
        total_budget += line_total
        item = MarketPurchaseItem(
            purchase_list_id=purchase.id,
            article_id=art.id,
            quantity=Decimal(str(item_in.quantity)),
            unit_price_xof=item_in.unit_price_xof,
            total_price_xof=line_total,
        )
        db.add(item)

    purchase.total_budget_xof = total_budget

    # Contrôle strict du plafond budgétaire côté serveur
    from caisse.domain.market_budget_rules import get_market_budget_limits, validate_market_budget
    total_limit, econome_limit, _ = get_market_budget_limits(db)
    validate_market_budget(
        total_budget,
        role=user.role,
        total_limit=total_limit,
        econome_limit=econome_limit,
    )

    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


def get_market_budget_status_service(
    db: Session, user: User, total_budget_xof: int = 0
) -> MarketBudgetStatusOut:
    from caisse.domain.market_budget_rules import (
        calculate_market_budget_status,
        get_market_budget_limits,
    )

    total_limit, econome_limit, _ = get_market_budget_limits(db)
    raw = calculate_market_budget_status(
        total_budget_xof,
        role=user.role,
        total_limit=total_limit,
        econome_limit=econome_limit,
    )
    return MarketBudgetStatusOut(**raw)


def get_market_purchase(db: Session, purchase_id: str) -> MarketPurchaseListOut:
    purchase = (
        db.query(MarketPurchaseList)
        .filter(MarketPurchaseList.id == purchase_id)
        .first()
    )
    if not purchase:
        raise CaisseException(
            code="PURCHASE_NOT_FOUND",
            title="Bon d'achat introuvable",
            detail=f"Bon d'achat {purchase_id} introuvable",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    return _format_purchase_out(purchase)


def list_market_purchases(
    db: Session, date_from: Optional[date] = None, date_to: Optional[date] = None
) -> list[MarketPurchaseListOut]:
    q = db.query(MarketPurchaseList).order_by(MarketPurchaseList.business_date.desc(), MarketPurchaseList.created_at.desc())
    if date_from:
        q = q.filter(MarketPurchaseList.business_date >= date_from)
    if date_to:
        q = q.filter(MarketPurchaseList.business_date <= date_to)
    return [_format_purchase_out(p) for p in q.all()]


def complete_market_purchase(
    db: Session,
    purchase_id: str,
    validator_user: User,
    create_stock_movements: bool = True,
    deduct_from_cash_session: bool = False,
) -> MarketPurchaseListOut:
    """Valide les achats après retour du marché et met à jour le stock en créant
    les mouvements PURCHASE_IN (ce qui alimente automatiquement la colonne ACHATS REÇUS).
    Si deduct_from_cash_session est vrai, crée également un décaissement CashExpense."""
    purchase = (
        db.query(MarketPurchaseList)
        .filter(MarketPurchaseList.id == purchase_id)
        .first()
    )
    if not purchase:
        raise CaisseException(
            code="PURCHASE_NOT_FOUND",
            title="Bon d'achat introuvable",
            detail=f"Bon d'achat {purchase_id} introuvable",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    if purchase.status == "COMPLETED":
        return _format_purchase_out(purchase)

    purchase.status = "COMPLETED"
    purchase.validated_by_user_id = validator_user.id

    if create_stock_movements:
        for item in purchase.items:
            art = db.query(StockArticle).filter(StockArticle.id == item.article_id).first()
            if art:
                new_qty = art.quantity + item.quantity
                new_avg = weighted_average_cost(
                    stock_qty=art.quantity,
                    stock_cost=art.avg_cost_xof,
                    in_qty=item.quantity,
                    in_unit_cost=Decimal(item.unit_price_xof),
                )
                art.quantity = new_qty
                art.avg_cost_xof = new_avg

                mov = StockMovement(
                    article_id=art.id,
                    type=StockMovementType.PURCHASE_IN,
                    quantity=item.quantity,
                    quantity_after=new_qty,
                    unit_cost_xof=Decimal(item.unit_price_xof),
                    business_date=purchase.business_date,
                    user_id=validator_user.id,
                    reason=f"Achats marché #{purchase.business_date}",
                )
                db.add(mov)

    # Déduction optionnelle du tiroir-caisse (dépense d'exploitation MARCHE_APPOINT)
    if deduct_from_cash_session and purchase.total_budget_xof > 0:
        open_session = (
            db.query(CashSession)
            .filter(CashSession.status == CashSessionStatus.OPEN)
            .order_by(CashSession.created_at.desc())
            .first()
        )
        session_id = open_session.id if open_session else None
        if open_session:
            db.add(
                CashMovement(
                    cash_session_id=open_session.id,
                    user_id=validator_user.id,
                    type="OUT",
                    amount_xof=purchase.total_budget_xof,
                    reason=f"[MARCHE_APPOINT] Achats marché {purchase.business_date}",
                )
            )

        db.add(
            CashExpense(
                business_date=purchase.business_date,
                cash_session_id=session_id,
                user_id=validator_user.id,
                category="MARCHE_APPOINT",
                amount_xof=purchase.total_budget_xof,
                recipient="Marché d'approvisionnement",
                reason=f"Achats viandes & poissons {purchase.business_date}",
            )
        )

    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


def save_daily_preparation(
    db: Session, user: User, data: DailyPreparationCreate
) -> DailyPreparationOut:
    """Enregistre ou met à jour la sortie cuisine d'un article pour une journée."""
    art = db.query(StockArticle).filter(StockArticle.id == data.article_id).first()
    if not art:
        raise CaisseException(
            code="ARTICLE_NOT_FOUND",
            title="Article introuvable",
            detail=f"Article {data.article_id} introuvable",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    prep_qty = Decimal(str(data.prepared_quantity))
    yield_portions = Decimal(str(data.yield_portions_per_unit))
    theo_dishes = calculate_theoretical_dishes(prep_qty, yield_portions)

    prep = (
        db.query(DailyPreparation)
        .filter(
            DailyPreparation.business_date == data.business_date,
            DailyPreparation.article_id == data.article_id,
        )
        .first()
    )

    if prep:
        prep.prepared_quantity = prep_qty
        prep.yield_portions_per_unit = yield_portions
        prep.theoretical_dishes = theo_dishes
        prep.user_id = user.id
        prep.notes = data.notes
    else:
        prep = DailyPreparation(
            business_date=data.business_date,
            article_id=data.article_id,
            prepared_quantity=prep_qty,
            yield_portions_per_unit=yield_portions,
            theoretical_dishes=theo_dishes,
            user_id=user.id,
            notes=data.notes,
        )
        db.add(prep)

    db.commit()
    db.refresh(prep)
    return DailyPreparationOut(
        id=str(prep.id),
        business_date=prep.business_date,
        article_id=str(prep.article_id),
        article_name=art.name,
        unit=art.unit,
        prepared_quantity=float(prep.prepared_quantity),
        yield_portions_per_unit=float(prep.yield_portions_per_unit),
        theoretical_dishes=prep.theoretical_dishes,
        user_id=str(prep.user_id),
        user_name=user.full_name,
        notes=prep.notes,
        created_at=prep.created_at,
    )


def get_weekly_matrix(
    db: Session, date_from: date, date_to: date
) -> WeeklyMatrixReportOut:
    """Génère la matrice hebdomadaire fidèle au tableau blanc du patron :
    Achats de la semaine | ventilation par jour (Sorti, Prévu, Vendu caisse, Écart, Valeur) | Totaux."""
    # 1. Calendrier des jours
    calendar_dates: list[date] = []
    cur = date_from
    while cur <= date_to:
        calendar_dates.append(cur)
        cur += timedelta(days=1)

    # 2. CA journalier réalisé (orders PAID)
    revenue_rows = db.execute(
        select(
            CashSession.business_date,
            func.sum(Order.total_ttc_xof),
        )
        .join(Order, Order.cash_session_id == CashSession.id)
        .where(
            Order.status == OrderStatus.PAID,
            CashSession.business_date >= date_from,
            CashSession.business_date <= date_to,
        )
        .group_by(CashSession.business_date)
    ).all()
    daily_revenues: dict[str, int] = {
        d.isoformat(): int(amt or 0) for d, amt in revenue_rows
    }
    for d in calendar_dates:
        if d.isoformat() not in daily_revenues:
            daily_revenues[d.isoformat()] = 0

    # 3. Articles catégorie PROTEINE
    articles = (
        db.query(StockArticle)
        .filter(StockArticle.category == StockArticleCategory.PROTEINE)
        .order_by(StockArticle.name)
        .all()
    )

    # 4. Fiches techniques pour connaître les plats associés et le rendement par défaut
    components = (
        db.query(ProductComponent)
        .options(joinedload(ProductComponent.product))
        .join(StockArticle, StockArticle.id == ProductComponent.article_id)
        .filter(StockArticle.category == StockArticleCategory.PROTEINE)
        .all()
    )
    article_components: dict[str, list[ProductComponent]] = {}
    for c in components:
        article_components.setdefault(str(c.article_id), []).append(c)

    # 5. Achats validés sur la période
    purchases_rows = db.execute(
        select(
            MarketPurchaseItem.article_id,
            func.sum(MarketPurchaseItem.quantity),
            func.sum(MarketPurchaseItem.total_price_xof),
        )
        .join(MarketPurchaseList, MarketPurchaseList.id == MarketPurchaseItem.purchase_list_id)
        .where(
            MarketPurchaseList.status == "COMPLETED",
            MarketPurchaseList.business_date >= date_from,
            MarketPurchaseList.business_date <= date_to,
        )
        .group_by(MarketPurchaseItem.article_id)
    ).all()
    purchases_map = {
        str(aid): (float(q or 0), int(cost or 0)) for aid, q, cost in purchases_rows
    }

    # 6. Sorties cuisine journalières (DailyPreparation)
    prep_rows = (
        db.query(DailyPreparation)
        .filter(
            DailyPreparation.business_date >= date_from,
            DailyPreparation.business_date <= date_to,
        )
        .all()
    )
    prep_map: dict[tuple[str, date], DailyPreparation] = {
        (str(p.article_id), p.business_date): p for p in prep_rows
    }

    # 7. Ventes journalières par produit issues de la caisse
    sales_rows = db.execute(
        select(
            CashSession.business_date,
            OrderItem.product_id,
            func.sum(OrderItem.quantity),
            func.sum(OrderItem.line_total_xof),
        )
        .join(Order, Order.cash_session_id == CashSession.id)
        .join(OrderItem, OrderItem.order_id == Order.id)
        .where(
            Order.status == OrderStatus.PAID,
            CashSession.business_date >= date_from,
            CashSession.business_date <= date_to,
            OrderItem.removed_at.is_(None),
        )
        .group_by(CashSession.business_date, OrderItem.product_id)
    ).all()
    # (date, product_id) -> (qty_sold, revenue)
    sales_by_day_prod: dict[tuple[date, str], tuple[int, int]] = {}
    for b_date, pid, q, rev in sales_rows:
        sales_by_day_prod[(b_date, str(pid))] = (int(q or 0), int(rev or 0))

    # 8. Assemblage des lignes de la matrice
    rows: list[WeeklyProductRow] = []
    total_purchases_cost = 0
    total_variance_impact = 0

    for a in articles:
        comps = article_components.get(str(a.id), [])
        standard_portion = float(comps[0].quantity) if comps else 1.0
        default_yield = round(1.0 / standard_portion, 2) if standard_portion > 0 else 1.0

        # Détection des plats associés : plat normal vs plat foufou
        normal_comp = None
        foufou_comp = None
        for c in comps:
            p_name = (c.product.name if c.product else "").lower()
            if "foufou" in p_name or "foutou" in p_name:
                if foufou_comp is None:
                    foufou_comp = c
            else:
                if normal_comp is None:
                    normal_comp = c

        dish_selling_price = 3000
        if normal_comp and normal_comp.product and normal_comp.product.price_xof:
            dish_selling_price = int(normal_comp.product.price_xof)
        elif comps and comps[0].product and comps[0].product.price_xof:
            dish_selling_price = int(comps[0].product.price_xof)

        foufou_selling_price = dish_selling_price + 500
        if foufou_comp and foufou_comp.product and foufou_comp.product.price_xof:
            foufou_selling_price = int(foufou_comp.product.price_xof)

        p_qty, p_cost = purchases_map.get(str(a.id), (0.0, 0))
        total_purchases_cost += p_cost
        potential_dishes = int(round(p_qty * default_yield))

        purchase_unit_price = int(round(p_cost / p_qty)) if p_qty > 0 else 0
        weekly_expected_rev = potential_dishes * dish_selling_price
        expected_margin_pct = (
            round(((weekly_expected_rev - p_cost) * 100) / weekly_expected_rev, 2)
            if weekly_expected_rev > 0
            else 0.0
        )

        row_days: list[WeeklyDayData] = []
        tot_prep_qty = 0.0
        tot_theo_dishes = 0
        tot_sold_dishes = 0
        tot_normal_sold = 0
        tot_foufou_sold = 0
        tot_var_dishes = 0
        tot_impact_xof = 0
        tot_actual_rev = 0

        for d in calendar_dates:
            day_name = DAY_NAMES_FR[d.weekday()]
            remaining_q = max(0.0, round(p_qty - tot_prep_qty, 3))

            prep = prep_map.get((str(a.id), d))
            prepared_q = float(prep.prepared_quantity) if prep else 0.0
            day_yield = float(prep.yield_portions_per_unit) if prep else default_yield
            theo_dishes = prep.theoretical_dishes if prep else int(round(prepared_q * day_yield))

            # Ventes des plats liés à cet article pour ce jour
            day_normal_sold = 0
            day_foufou_sold = 0
            day_sold = 0
            day_rev = 0

            for c in comps:
                s_q, s_r = sales_by_day_prod.get((d, str(c.product_id)), (0, 0))
                if s_q > 0:
                    day_sold += s_q
                    day_rev += s_r
                    p_name = (c.product.name if c.product else "").lower()
                    if "foufou" in p_name or "foutou" in p_name:
                        day_foufou_sold += s_q
                    else:
                        day_normal_sold += s_q

            # Solution 2 : Quantité suggérée d'après les ventes réelles
            suggested_q = round(day_sold / day_yield, 2) if day_yield > 0 else 0.0

            variance = calculate_dish_variance(day_sold, theo_dishes)
            avg_dish_price = (day_rev // day_sold) if day_sold > 0 else dish_selling_price
            impact = calculate_financial_impact(variance, avg_dish_price)

            day_expected_rev = theo_dishes * dish_selling_price
            day_actual_rev = day_rev if day_rev > 0 else (day_normal_sold * dish_selling_price + day_foufou_sold * foufou_selling_price)
            day_rev_variance = day_actual_rev - day_expected_rev

            tot_prep_qty += prepared_q
            tot_theo_dishes += theo_dishes
            tot_sold_dishes += day_sold
            tot_normal_sold += day_normal_sold
            tot_foufou_sold += day_foufou_sold
            tot_var_dishes += variance
            tot_impact_xof += impact
            tot_actual_rev += day_actual_rev

            row_days.append(
                WeeklyDayData(
                    business_date=d,
                    day_name=day_name,
                    remaining_quantity=remaining_q,
                    prepared_quantity=prepared_q,
                    suggested_quantity=suggested_q,
                    yield_portions_per_unit=day_yield,
                    theoretical_dishes=theo_dishes,
                    sold_dishes=day_sold,
                    normal_dishes_sold=day_normal_sold,
                    foufou_dishes_sold=day_foufou_sold,
                    foufou_price_xof=foufou_selling_price,
                    variance_dishes=variance,
                    dish_price_xof=dish_selling_price,
                    expected_revenue_xof=day_expected_rev,
                    actual_revenue_xof=day_actual_rev,
                    revenue_variance_xof=day_rev_variance,
                    financial_impact_xof=impact,
                )
            )

        total_variance_impact += tot_impact_xof

        actual_margin_xof = tot_actual_rev - p_cost
        actual_margin_pct = (
            round((actual_margin_xof * 100) / tot_actual_rev, 2)
            if tot_actual_rev > 0
            else 0.0
        )
        qty_variance = round(tot_prep_qty - p_qty, 3)
        dishes_variance = tot_sold_dishes - potential_dishes

        rows.append(
            WeeklyProductRow(
                article_id=str(a.id),
                article_name=a.name,
                unit=a.unit,
                weekly_purchased_qty=p_qty,
                purchase_unit_price_xof=purchase_unit_price,
                weekly_purchased_cost_xof=p_cost,
                default_yield_portions=default_yield,
                weekly_potential_dishes=potential_dishes,
                dish_selling_price_xof=dish_selling_price,
                weekly_expected_revenue_xof=weekly_expected_rev,
                expected_margin_pct=expected_margin_pct,
                days=row_days,
                total_prepared_qty=round(tot_prep_qty, 3),
                total_theoretical_dishes=tot_theo_dishes,
                total_sold_dishes=tot_sold_dishes,
                total_variance_dishes=tot_var_dishes,
                total_financial_impact_xof=tot_impact_xof,
                actual_revenue_xof=tot_actual_rev,
                actual_gross_margin_xof=actual_margin_xof,
                actual_gross_margin_pct=actual_margin_pct,
                quantity_variance=qty_variance,
                dishes_variance=dishes_variance,
            )
        )

    total_revenue = sum(daily_revenues.values())
    gross_margin_estimate = total_revenue - total_purchases_cost

    return WeeklyMatrixReportOut(
        date_from=date_from,
        date_to=date_to,
        daily_revenues=daily_revenues,
        total_weekly_revenue_xof=total_revenue,
        total_weekly_purchases_xof=total_purchases_cost,
        total_variance_impact_xof=total_variance_impact,
        gross_margin_estimate_xof=gross_margin_estimate,
        rows=rows,
    )

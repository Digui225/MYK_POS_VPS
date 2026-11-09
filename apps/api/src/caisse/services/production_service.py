from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Any, Optional

from fastapi import status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload

from caisse.core.errors import CaisseException, NotFoundError, ValidationError
from caisse.domain.enums import (
    CashSessionStatus,
    OrderStatus,
    StockArticleCategory,
    StockMovementType,
    StockOutMode,
)
from caisse.domain.money import to_xof
from caisse.domain.production_rules import (
    calculate_dish_variance,
    calculate_financial_impact,
    calculate_item_total,
    calculate_theoretical_dishes,
)
from caisse.domain.protein_mapping import dish_variant
from caisse.domain.stock_rules import quantize_qty, weighted_average_cost
from caisse.models.cash_session import CashMovement, CashSession
from caisse.models.finance import CashExpense
from caisse.models.order import Order
from caisse.models.production import (
    DailyPreparation,
    MarketPurchaseItem,
    MarketPurchaseList,
)
from caisse.models.stock import StockArticle, StockMovement
from caisse.models.user import User
from caisse.schemas.production import (
    DailyPreparationCreate,
    DailyPreparationOut,
    DailyPreparationValidateDayOut,
    MarketProteinAnalysisOut,
    MarketPurchaseCancel,
    MarketPurchaseItemOut,
    MarketPurchaseListCreate,
    MarketPurchaseListOut,
    MarketPurchaseListUpdate,
    MarketPurchaseReceive,
    OpeningStockCorrection,
    OpeningStockCorrectionOut,
    ProteinComparisonRow,
    WeeklyDayData,
    WeeklyMatrixReportOut,
    WeeklyProductRow,
)
from caisse.services import audit_service, protein_ledger, stock_service

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
        include_condiments_envelope=getattr(purchase, "include_condiments_envelope", False),
        created_at=purchase.created_at,
        received_at=purchase.received_at,
        stock_date=purchase.stock_date,
        received_by_user_name=purchase.received_by.full_name if purchase.received_by else None,
        cancelled_at=purchase.cancelled_at,
        cancelled_by_user_name=purchase.cancelled_by.full_name if purchase.cancelled_by else None,
        cancel_reason=purchase.cancel_reason,
        items=[
            MarketPurchaseItemOut(
                id=str(item.id),
                article_id=str(item.article_id),
                article_name=item.article.name if item.article else "—",
                unit=item.article.unit if item.article else "—",
                quantity=float(item.quantity),
                unit_price_xof=item.unit_price_xof,
                total_price_xof=item.total_price_xof,
                received_quantity=(
                    float(item.received_quantity) if item.received_quantity is not None else None
                ),
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
        include_condiments_envelope=data.include_condiments_envelope,
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


def update_market_purchase(
    db: Session,
    purchase_id: str,
    user: User,
    payload: MarketPurchaseListUpdate,
) -> MarketPurchaseListOut:
    """Met à jour les articles et quantités d'un bon d'achat en attente (DRAFT).
    Permet au Patron/Responsable d'ajuster les quantités avant départ au marché."""
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
    if purchase.status != "DRAFT":
        raise CaisseException(
            code="PURCHASE_ALREADY_COMPLETED",
            title="Modification impossible",
            detail="Seul un bon d'achat en attente (DRAFT) peut être modifié.",
            status_code=status.HTTP_400_BAD_REQUEST,
        )

    if payload.items is not None:
        # Vider les anciens items pour recréer la liste mise à jour
        db.query(MarketPurchaseItem).filter(
            MarketPurchaseItem.purchase_list_id == purchase.id
        ).delete(synchronize_session="fetch")

        total_budget = 0
        for item_in in payload.items:
            art = None
            if item_in.article_id:
                art = db.query(StockArticle).filter(StockArticle.id == item_in.article_id).first()

            if not art and item_in.custom_article_name:
                art_name = item_in.custom_article_name.strip()
                existing_art = (
                    db.query(StockArticle)
                    .filter(func.lower(StockArticle.name) == art_name.lower())
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

            if not art:
                continue

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

    if payload.include_condiments_envelope is not None:
        purchase.include_condiments_envelope = payload.include_condiments_envelope

    if payload.notes is not None:
        purchase.notes = payload.notes

    from caisse.domain.market_budget_rules import get_market_budget_limits, validate_market_budget
    total_limit, econome_limit, _ = get_market_budget_limits(db)
    validate_market_budget(
        purchase.total_budget_xof,
        role=user.role,
        total_limit=total_limit,
        econome_limit=econome_limit,
    )

    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


def get_market_purchase_protein_analysis(
    db: Session, purchase_id: str
) -> MarketProteinAnalysisOut:
    """Analyse comparative des 9 protéines principales du bon d'achat
    croisées avec la matrice hebdomadaire de ventes et le stock en cuisine."""
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

    # 1. Période de référence de la matrice d'activité (Semaine ouvrée Lundi - Vendredi)
    b_date = purchase.business_date
    cur_monday = b_date - timedelta(days=b_date.weekday())
    cur_friday = cur_monday + timedelta(days=4)
    matrix = get_weekly_matrix(db, cur_monday, cur_friday)

    has_current_week_activity = any(
        (p.total_sold_dishes > 0 or p.total_prepared_qty > 0 or p.weekly_purchased_qty > 0)
        for p in matrix.rows
    )
    if b_date.weekday() == 0 and not has_current_week_activity:
        # Bon préparé le lundi matin avant l'activité de la semaine : vue sur la semaine écoulée
        week_start = cur_monday - timedelta(days=7)
        week_end = week_start + timedelta(days=4)
        matrix = get_weekly_matrix(db, week_start, week_end)
    else:
        week_start = cur_monday
        week_end = cur_friday

    matrix_products_map = {p.article_id: p for p in matrix.rows}

    # 3. Récupération des 9 protéines en base
    protein_articles = (
        db.query(StockArticle)
        .filter(StockArticle.category == StockArticleCategory.PROTEINE)
        .order_by(StockArticle.name)
        .all()
    )

    # 4. Articles figurant sur le bon d'achat
    purchase_items_map = {item.article_id: item for item in purchase.items}

    rows: list[ProteinComparisonRow] = []
    tot_req_cost = 0
    tot_rec_cost = 0

    for art in protein_articles:
        art_id = str(art.id)
        p_item = purchase_items_map.get(art_id)
        requested_qty = float(p_item.quantity) if p_item else 0.0
        unit_price = p_item.unit_price_xof if p_item else to_xof(art.avg_cost_xof)
        line_total = to_xof(requested_qty * unit_price)

        current_stock = float(art.quantity)
        m_prod = matrix_products_map.get(art_id)
        weekly_purchased = m_prod.weekly_purchased_qty if m_prod else 0.0
        weekly_prepared = m_prod.total_prepared_qty if m_prod else 0.0
        weekly_sold_dishes = m_prod.total_sold_dishes if m_prod else 0

        # Stock réel restant actuellement en cuisine/réserve (intègre ventes encaissées,
        # clôture de caisse, pertes et inventaires contradictoires — jamais le stock initial)
        estimated_remaining = max(0.0, round(current_stock, 2))


        # Quantité conseillée : Demande - Reste en cuisine (au minimum 0)
        # Si rien n'est demandé par l'économe, la recommandation reste 0
        if requested_qty > 0:
            recommended_qty = max(0.0, round(requested_qty - estimated_remaining, 2))
        else:
            recommended_qty = 0.0

        recommended_total = to_xof(recommended_qty * unit_price)
        savings = max(0, line_total - recommended_total)

        tot_req_cost += line_total
        tot_rec_cost += recommended_total

        # Statut d'alerte
        if estimated_remaining <= 0.1:
            status_alert = "EXHAUSTED"  # Stock épuisé, réapprovisionnement nécessaire
        elif estimated_remaining < requested_qty:
            status_alert = "PARTIAL"    # Stock partiel, réduction suggérée
        else:
            status_alert = "SURPLUS"    # Stock suffisant, achat déconseillé

        rows.append(
            ProteinComparisonRow(
                article_id=art_id,
                article_name=art.name,
                unit=art.unit,
                requested_quantity=requested_qty,
                unit_price_xof=unit_price,
                line_total_xof=line_total,
                current_stock_quantity=current_stock,
                weekly_purchased_quantity=weekly_purchased,
                weekly_prepared_quantity=weekly_prepared,
                weekly_sold_dishes=weekly_sold_dishes,
                estimated_remaining_quantity=estimated_remaining,
                recommended_quantity=recommended_qty,
                recommended_total_xof=recommended_total,
                potential_savings_xof=savings,
                status_alert=status_alert,
            )
        )

    return MarketProteinAnalysisOut(
        purchase_id=str(purchase.id),
        business_date=purchase.business_date,
        week_start=week_start,
        week_end=week_end,
        proteins=rows,
        total_requested_proteins_cost_xof=tot_req_cost,
        total_recommended_proteins_cost_xof=tot_rec_cost,
        total_potential_savings_xof=max(0, tot_req_cost - tot_rec_cost),
    )




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
    deduct_from_cash_session: bool = False,
) -> MarketPurchaseListOut:
    """Valide le bon (D9) : l'argent est remis, le stock ne bouge pas. Les achats entrent en
    stock à la réception (`receive_market_purchase`), avec les quantités réellement reçues.
    Si deduct_from_cash_session est vrai, crée également un décaissement CashExpense."""
    # Verrou sur le bon : deux validations simultanées (double clic) ne décaissent pas deux fois.
    purchase = _lock_purchase(db, purchase_id)
    if purchase.status in (PURCHASE_VALIDATED, PURCHASE_COMPLETED):
        return _format_purchase_out(purchase)
    if purchase.status != PURCHASE_DRAFT:
        raise ValidationError(
            "Ce bon d'achat a été annulé",
            meta={"status": purchase.status},
        )

    purchase.status = PURCHASE_VALIDATED
    purchase.validated_by_user_id = validator_user.id

    from caisse.domain.market_budget_rules import DEFAULT_RESERVE_XOF

    # Déduction optionnelle du tiroir-caisse
    condiments_xof = DEFAULT_RESERVE_XOF if purchase.include_condiments_envelope else 0
    total_disbursement_xof = purchase.total_budget_xof + condiments_xof
    if deduct_from_cash_session and total_disbursement_xof > 0:
        open_session = (
            db.query(CashSession)
            .filter(CashSession.status == CashSessionStatus.OPEN)
            .order_by(CashSession.created_at.desc())
            .first()
        )
        session_id = open_session.id if open_session else None
        reason_label = (
            f"[MARCHE_HEBDO] Achats marché {purchase.business_date} (Protéines {purchase.total_budget_xof:,} + Condiments {DEFAULT_RESERVE_XOF:,} XOF)"
            if purchase.include_condiments_envelope
            else f"[MARCHE_APPOINT] Achats marché {purchase.business_date} ({purchase.total_budget_xof:,} XOF)"
        )
        if open_session:
            db.add(
                CashMovement(
                    cash_session_id=open_session.id,
                    user_id=validator_user.id,
                    type="OUT",
                    amount_xof=total_disbursement_xof,
                    reason=reason_label,
                )
            )

        expense_reason = (
            f"Achats viandes ({purchase.total_budget_xof:,} XOF) et condiments ({DEFAULT_RESERVE_XOF:,} XOF) {purchase.business_date}"
            if purchase.include_condiments_envelope
            else f"Achats viandes ({purchase.total_budget_xof:,} XOF) {purchase.business_date}"
        )
        db.add(
            CashExpense(
                business_date=purchase.business_date,
                cash_session_id=session_id,
                user_id=validator_user.id,
                category="MARCHE_APPOINT",
                amount_xof=total_disbursement_xof,
                recipient="Marché d'approvisionnement",
                reason=expense_reason,
            )
        )

    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


# --- Réception des achats marché (D9) ----------------------------------------------------

PURCHASE_DRAFT = "DRAFT"
PURCHASE_VALIDATED = "VALIDATED"
PURCHASE_COMPLETED = "COMPLETED"
PURCHASE_CANCELLED = "CANCELLED"


def cancel_market_purchase(
    db: Session,
    purchase_id: str,
    payload: MarketPurchaseCancel,
    *,
    user: User,
    ctx: Any = None,
) -> MarketPurchaseListOut:
    """Annule un bon pas encore validé (D10) : aucun argent remis, aucun stock entré, donc
    aucun effet à compenser. Le bon n'est jamais supprimé : il passe à `CANCELLED` avec l'auteur,
    la date et le motif. Le responsable et l'admin annulent tout bon ; l'économe seulement ceux
    qu'il a préparés. Rejouer l'annulation d'un bon déjà annulé ne change rien."""
    purchase = _lock_purchase(db, purchase_id)
    if user.role == "ECONOME" and str(purchase.created_by_user_id) != str(user.id):
        raise CaisseException(
            code="INSUFFICIENT_PRIVILEGE",
            title="Droits insuffisants",
            detail="L'économe ne peut annuler que les bons d'achat qu'il a préparés.",
            status_code=status.HTTP_403_FORBIDDEN,
        )
    if purchase.status == PURCHASE_CANCELLED:
        return _format_purchase_out(purchase)
    if purchase.status != PURCHASE_DRAFT:
        raise CaisseException(
            code="PURCHASE_NOT_CANCELLABLE",
            title="Annulation impossible",
            detail=(
                "Seul un bon pas encore validé peut être annulé. Un bon réceptionné se corrige "
                "par ses quantités reçues."
            ),
            status_code=status.HTTP_409_CONFLICT,
            meta={"status": purchase.status},
        )

    reason = payload.reason.strip()
    if len(reason) < 3:
        raise ValidationError(
            "Indiquez le motif de l'annulation",
            meta={"fields": [{"loc": ["body", "reason"], "type": "missing"}]},
        )
    purchase.status = PURCHASE_CANCELLED
    purchase.cancelled_at = datetime.now(timezone.utc)
    purchase.cancelled_by_user_id = str(user.id)
    purchase.cancel_reason = reason
    audit_service.log(
        db,
        "market_purchase.cancel",
        ctx=ctx,
        user_id=str(user.id),
        entity="market_purchase",
        entity_id=str(purchase.id),
        before={"status": PURCHASE_DRAFT},
        after={
            "status": PURCHASE_CANCELLED,
            "business_date": str(purchase.business_date),
            "total_budget_xof": purchase.total_budget_xof,
            "reason": reason,
        },
    )
    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


def _lock_purchase(db: Session, purchase_id: str) -> MarketPurchaseList:
    purchase = (
        db.query(MarketPurchaseList)
        .filter(MarketPurchaseList.id == purchase_id)
        .with_for_update()
        .populate_existing()
        .first()
    )
    if not purchase:
        raise CaisseException(
            code="PURCHASE_NOT_FOUND",
            title="Bon d'achat introuvable",
            detail=f"Bon d'achat {purchase_id} introuvable",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    return purchase


def _purchase_entry(
    db: Session,
    article: StockArticle,
    quantity: Decimal,
    unit_cost: Decimal,
    *,
    business_date: date,
    user_id: str,
    reason: str,
) -> StockMovement:
    """Entrée (ou retrait, si négative) d'achat sur un article verrouillé. Une entrée recalcule
    le coût moyen pondéré ; un retrait sort au prix du bon sans changer le coût moyen."""
    if quantity > 0:
        return stock_service.record_purchase(
            db,
            article,
            quantity,
            unit_cost,
            business_date=business_date,
            user_id=user_id,
            supplier=None,
            reason=reason,
        )
    return stock_service.move(
        db,
        article,
        StockMovementType.PURCHASE_IN,
        quantity,
        unit_cost=unit_cost,
        business_date=business_date,
        user_id=user_id,
        reason=reason,
    )


def _reception_day(db: Session) -> date:
    """Jour de la réception : la journée de la caisse ouverte, sinon aujourd'hui (comme les
    autres mouvements de stock)."""
    return stock_service.business_day(db)


def _stock_date_of(purchase: MarketPurchaseList) -> date:
    """Date des mouvements de stock d'un bon réceptionné : `stock_date`, ou la date du bon pour
    un bon réceptionné avant D13."""
    return purchase.stock_date or purchase.business_date


def _fmt_qty(value: Decimal) -> str:
    return format(value.normalize(), "f")


def receive_market_purchase(
    db: Session,
    purchase_id: str,
    payload: MarketPurchaseReceive,
    *,
    user: User,
    ctx: Any = None,
) -> MarketPurchaseListOut:
    """Réception d'un bon validé : seules les quantités réellement reçues entrent en stock, au
    prix du bon et au **jour de la réception** (D13 : un bon se prépare souvent la veille du
    marché ; c'est l'arrivée des achats qui compte). Sur un bon déjà réceptionné, corrige les
    quantités reçues : l'écart est un mouvement d'achat signé et tracé, daté comme la réception
    (on ne modifie jamais un mouvement). Les quantités sont des valeurs cibles : renvoyer la
    même demande ne change rien."""
    purchase = _lock_purchase(db, purchase_id)
    if purchase.status == PURCHASE_DRAFT:
        raise ValidationError(
            "Validez le bon d'achat avant de réceptionner les achats",
            meta={"status": purchase.status},
        )
    if purchase.status not in (PURCHASE_VALIDATED, PURCHASE_COMPLETED):
        raise ValidationError(
            "Ce bon d'achat a été annulé", meta={"status": purchase.status}
        )

    items = {str(item.id): item for item in purchase.items}
    unknown = [line.item_id for line in payload.lines if line.item_id not in items]
    if unknown:
        raise NotFoundError("Ligne de bon introuvable", meta={"item_ids": unknown})
    targets = {line.item_id: quantize_qty(Decimal(str(line.received_quantity))) for line in payload.lines}

    first_reception = purchase.status == PURCHASE_VALIDATED
    # quantité déjà entrée en stock par ligne (prévue pour les bons d'avant la réception)
    current = {
        iid: (
            Decimal(0)
            if first_reception
            else Decimal(item.received_quantity if item.received_quantity is not None else item.quantity)
        )
        for iid, item in items.items()
    }
    wanted = {
        iid: targets.get(iid, Decimal(item.quantity) if first_reception else current[iid])
        for iid, item in items.items()
    }
    changes = {iid: wanted[iid] - current[iid] for iid in items if wanted[iid] != current[iid]}

    reason = (payload.reason or "").strip()
    if not first_reception:
        if not changes:
            return _format_purchase_out(purchase)
        if len(reason) < 3:
            raise ValidationError(
                "Indiquez le motif de la correction",
                meta={"fields": [{"loc": ["body", "reason"], "type": "missing"}]},
            )

    label = purchase.business_date.strftime("%d/%m/%Y")
    # Première réception : aujourd'hui. Correction : la date de la réception (date du bon pour
    # les bons réceptionnés avant D13, qui n'ont pas de stock_date).
    stock_date = _reception_day(db) if first_reception else _stock_date_of(purchase)
    articles = stock_service.lock_existing(db, [str(items[iid].article_id) for iid in changes])
    movements: list[dict[str, Any]] = []
    for iid, delta in changes.items():
        item = items[iid]
        article = articles[str(item.article_id)]
        if first_reception:
            text_reason = f"Achats marché #{purchase.business_date}"
        else:
            text_reason = (
                f"Correction réception bon du {label} : "
                f"{_fmt_qty(current[iid])} → {_fmt_qty(wanted[iid])} — {reason}"
            )[:255]
        _purchase_entry(
            db,
            article,
            delta,
            Decimal(item.unit_price_xof),
            business_date=stock_date,
            user_id=str(user.id),
            reason=text_reason,
        )
        movements.append(
            {"article": article.name, "from": str(current[iid]), "to": str(wanted[iid])}
        )
    for iid, item in items.items():
        item.received_quantity = wanted[iid]

    if first_reception:
        purchase.stock_date = stock_date
        _enter_condiments_kit(db, purchase, str(user.id))
        purchase.status = PURCHASE_COMPLETED
        purchase.received_at = datetime.now(timezone.utc)
        purchase.received_by_user_id = str(user.id)

    audit_service.log(
        db,
        "market_purchase.receive" if first_reception else "market_purchase.receipt_correction",
        ctx=ctx,
        user_id=str(user.id),
        entity="market_purchase",
        entity_id=str(purchase.id),
        after={
            "business_date": str(purchase.business_date),
            "stock_date": str(stock_date),
            "lines": movements,
            "reason": reason or None,
        },
    )
    db.commit()
    db.refresh(purchase)
    return _format_purchase_out(purchase)


def redate_market_reception(
    db: Session,
    purchase_id: str,
    new_date: date,
    *,
    user_id: str,
    reason: str,
) -> list[dict[str, Any]]:
    """Recale la date d'entrée en stock d'un bon déjà réceptionné (D13), sans modifier aucun
    mouvement : pour chaque achat reçu (et le kit condiments), un retrait daté de l'ancienne
    date et la même entrée datée de la nouvelle, au prix du bon. Le stock et le coût moyen ne
    changent pas ; seuls les achats changent de jour (et de semaine dans la matrice).
    Renvoie les mouvements faits ; rien si le bon est déjà à cette date."""
    purchase = _lock_purchase(db, purchase_id)
    if purchase.status != PURCHASE_COMPLETED:
        raise ValidationError(
            "Seul un bon réceptionné peut être recalé", meta={"status": purchase.status}
        )
    reason = reason.strip()
    if len(reason) < 3:
        raise ValidationError(
            "Indiquez le motif du recalage",
            meta={"fields": [{"loc": ["body", "reason"], "type": "missing"}]},
        )
    old_date = _stock_date_of(purchase)
    if new_date == old_date:
        return []

    lines: list[tuple[str, Decimal, Decimal]] = [
        (
            str(item.article_id),
            Decimal(item.received_quantity if item.received_quantity is not None else item.quantity),
            Decimal(item.unit_price_xof),
        )
        for item in purchase.items
    ]
    if purchase.include_condiments_envelope:
        from caisse.domain.market_budget_rules import DEFAULT_MARKET_CONDIMENTS_KIT

        names = [str(c["name"]) for c in DEFAULT_MARKET_CONDIMENTS_KIT]
        kit_ids = {
            a.name: str(a.id)
            for a in db.query(StockArticle).filter(StockArticle.name.in_(names)).all()
        }
        lines += [
            (kit_ids[str(c["name"])], Decimal(c["quantity"]), Decimal(c["unit_price_xof"]))
            for c in DEFAULT_MARKET_CONDIMENTS_KIT
            if str(c["name"]) in kit_ids
        ]
    lines = [line for line in lines if line[1] != 0]

    label = purchase.business_date.strftime("%d/%m/%Y")
    text = (
        f"Recalage réception bon du {label} : {old_date.strftime('%d/%m/%Y')} → "
        f"{new_date.strftime('%d/%m/%Y')} — {reason}"
    )[:255]
    articles = stock_service.lock_existing(db, [aid for aid, _, _ in lines])
    movements: list[dict[str, Any]] = []
    for aid, qty, unit_cost in lines:
        article = articles[aid]
        for day, signed in ((old_date, -qty), (new_date, qty)):
            stock_service.move(
                db,
                article,
                StockMovementType.PURCHASE_IN,
                signed,
                unit_cost=unit_cost,
                business_date=day,
                user_id=user_id,
                reason=text,
            )
        movements.append({"article": article.name, "quantity": _fmt_qty(qty)})

    purchase.stock_date = new_date
    audit_service.log(
        db,
        "market_purchase.reception_redated",
        user_id=user_id,
        entity="market_purchase",
        entity_id=str(purchase.id),
        before={"stock_date": str(old_date)},
        after={"stock_date": str(new_date), "lines": movements, "reason": reason},
    )
    db.commit()
    return movements


def _enter_condiments_kit(db: Session, purchase: MarketPurchaseList, user_id: str) -> None:
    """Kit condiments hebdomadaire (120 000 XOF) : entré en stock à la réception du bon, si
    le bon l'inclut."""
    if not purchase.include_condiments_envelope:
        return
    from caisse.domain.market_budget_rules import DEFAULT_MARKET_CONDIMENTS_KIT

    for cond in DEFAULT_MARKET_CONDIMENTS_KIT:
        c_art = (
            db.query(StockArticle)
            .filter(StockArticle.name == cond["name"])
            .with_for_update()
            .first()
        )
        if c_art:
            qty: Decimal = cond["quantity"]
            unit_cost = Decimal(cond["unit_price_xof"])
            new_qty = c_art.quantity + qty
            new_avg = weighted_average_cost(
                stock_qty=c_art.quantity,
                stock_cost=c_art.avg_cost_xof,
                in_qty=qty,
                in_unit_cost=unit_cost,
            )
            c_art.quantity = new_qty
            c_art.avg_cost_xof = new_avg
            db.add(
                StockMovement(
                    article_id=c_art.id,
                    type=StockMovementType.PURCHASE_IN,
                    quantity=qty,
                    quantity_after=new_qty,
                    unit_cost_xof=unit_cost,
                    business_date=_stock_date_of(purchase),
                    user_id=user_id,
                    reason=f"Kit condiments marché (120 000 XOF) #{purchase.business_date}",
                )
            )


def correct_opening_stock(
    db: Session,
    payload: OpeningStockCorrection,
    *,
    user: User,
    ctx: Any = None,
) -> OpeningStockCorrectionOut:
    """Corrige le stock de départ d'un article à une journée (valeur cible). L'écart est un
    mouvement de stock de départ daté de cette journée : la matrice le compte dans l'ouverture,
    et toutes les journées suivantes, stock actuel compris, sont décalées d'autant."""
    article = stock_service.lock_existing(db, [payload.article_id])[payload.article_id]
    day = payload.business_date
    led = protein_ledger.daily_ledger(db, [article], day, day)[str(article.id)][0]
    previous = led.opening
    target = quantize_qty(Decimal(str(payload.quantity)))
    delta = target - previous
    if delta != 0:
        stock_service.move(
            db,
            article,
            StockMovementType.OPENING,
            delta,
            unit_cost=article.avg_cost_xof,
            business_date=day,
            user_id=str(user.id),
            reason=(
                f"Correction stock initial au {day.strftime('%d/%m/%Y')} : "
                f"{_fmt_qty(previous)} → {_fmt_qty(target)} — {payload.reason.strip()}"
            )[:255],
        )
        audit_service.log(
            db,
            "stock.opening_correction",
            ctx=ctx,
            user_id=str(user.id),
            entity="stock_article",
            entity_id=str(article.id),
            after={
                "business_date": str(day),
                "from": str(previous),
                "to": str(target),
                "reason": payload.reason.strip(),
            },
        )
        db.commit()
        db.refresh(article)
    return OpeningStockCorrectionOut(
        article_id=str(article.id),
        article_name=article.name,
        unit=article.unit,
        business_date=day,
        previous_quantity=_f(previous),
        quantity=_f(target),
        delta_quantity=_f(delta),
        current_stock_quantity=_f(Decimal(article.quantity)),
    )


# --- Sorties cuisine : simple contrôle, sans effet sur le stock (D6) ---------------------

PREP_ESTIMATED = "ESTIMATED"
PREP_VALIDATED = "VALIDATED"
PREP_ADJUSTED = "ADJUSTED"

ESTIMATED_NOTE = "Estimation à la clôture de caisse (à valider)"
# Ancien libellé des sorties créées par la clôture (avant la migration 026)
AUTO_VALIDATED_NOTE = "Auto-validé à la clôture de caisse"


def _prep_out(prep: DailyPreparation, article: StockArticle, user: User | None) -> DailyPreparationOut:
    return DailyPreparationOut(
        id=str(prep.id),
        business_date=prep.business_date,
        article_id=str(prep.article_id),
        article_name=article.name,
        unit=article.unit,
        prepared_quantity=float(prep.prepared_quantity),
        yield_portions_per_unit=float(prep.yield_portions_per_unit),
        theoretical_dishes=prep.theoretical_dishes,
        user_id=str(prep.user_id),
        user_name=(user.full_name if user else "") or "",
        notes=prep.notes,
        created_at=prep.created_at,
        status=prep.status,  # type: ignore[arg-type]
        estimated_quantity=(
            float(prep.estimated_quantity) if prep.estimated_quantity is not None else None
        ),
    )


def save_daily_preparation(
    db: Session, user: User, data: DailyPreparationCreate
) -> DailyPreparationOut:
    """La cuisine enregistre sa sortie du jour : VALIDÉE si elle confirme l'estimation (ou s'il
    n'y en a pas), AJUSTÉE si elle saisit un autre chiffre. 0 efface la sortie."""
    art = db.query(StockArticle).filter(StockArticle.id == data.article_id).first()
    if not art:
        raise CaisseException(
            code="ARTICLE_NOT_FOUND",
            title="Article introuvable",
            detail=f"Article {data.article_id} introuvable",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    prep_qty = quantize_qty(Decimal(str(data.prepared_quantity)))
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

    if prep_qty <= 0:
        created_at_val = prep.created_at if prep else datetime.now(timezone.utc)
        if prep:
            db.delete(prep)
            db.commit()
        return DailyPreparationOut(
            id=str(prep.id) if prep else "",
            business_date=data.business_date,
            article_id=str(art.id),
            article_name=art.name,
            unit=art.unit,
            prepared_quantity=0.0,
            yield_portions_per_unit=float(yield_portions),
            theoretical_dishes=0,
            user_id=str(user.id),
            user_name=user.full_name,
            notes=data.notes,
            created_at=created_at_val,
            estimated_quantity=None,
        )

    estimated = prep.estimated_quantity if prep else None
    new_status = (
        PREP_VALIDATED
        if estimated is None or quantize_qty(Decimal(estimated)) == prep_qty
        else PREP_ADJUSTED
    )

    if prep:
        prep.prepared_quantity = prep_qty
        prep.yield_portions_per_unit = yield_portions
        prep.theoretical_dishes = theo_dishes
        prep.user_id = user.id
        prep.notes = data.notes
        prep.status = new_status
    else:
        prep = DailyPreparation(
            business_date=data.business_date,
            article_id=data.article_id,
            prepared_quantity=prep_qty,
            yield_portions_per_unit=yield_portions,
            theoretical_dishes=theo_dishes,
            user_id=user.id,
            notes=data.notes,
            status=new_status,
        )
        db.add(prep)

    db.commit()
    db.refresh(prep)
    return _prep_out(prep, art, user)


def validate_day_preparations(
    db: Session, user: User, business_date: date
) -> DailyPreparationValidateDayOut:
    """« Valider la journée » : la cuisine confirme d'un coup toutes les estimations du jour."""
    preps = (
        db.query(DailyPreparation)
        .options(joinedload(DailyPreparation.article), joinedload(DailyPreparation.user))
        .filter(DailyPreparation.business_date == business_date)
        .all()
    )
    validated = 0
    for prep in preps:
        if prep.status == PREP_ESTIMATED:
            prep.status = PREP_VALIDATED
            prep.user_id = user.id
            if prep.notes == ESTIMATED_NOTE or (prep.notes or "").startswith("Auto-valid"):
                prep.notes = None
            validated += 1
    db.commit()
    for prep in preps:
        db.refresh(prep)
    return DailyPreparationValidateDayOut(
        business_date=business_date,
        validated_count=validated,
        preparations=[
            _prep_out(p, p.article, user if str(p.user_id) == str(user.id) else p.user)
            for p in sorted(preps, key=lambda p: p.article.name)
        ],
    )


def estimate_daily_preparations_from_sales(
    db: Session,
    business_date: date,
    user_id: str,
) -> list[DailyPreparation]:
    """À la clôture de caisse : estime la sortie cuisine de chaque protéine d'après les ventes
    soldées du jour, avec la même règle que le déstockage (fiche du plat, sinon mot-clé).

    - une sortie ESTIMÉE est mise à jour (service midi puis soir) ;
    - une sortie VALIDÉE ou AJUSTÉE n'est jamais modifiée, seule l'estimation est notée ;
    - une estimation tombée à zéro (ventes annulées) est retirée."""
    if isinstance(business_date, str):
        business_date = date.fromisoformat(business_date)

    resolver = protein_ledger.build_resolver(db)
    if not resolver.articles:
        return []

    expected: dict[str, Decimal] = {}
    for line in protein_ledger.paid_sale_lines(db, business_date, business_date):
        for aid, per_dish in resolver.protein_lines(line.product_id, line.name):
            expected[aid] = expected.get(aid, Decimal(0)) + per_dish * line.quantity

    existing = {
        str(p.article_id): p
        for p in db.query(DailyPreparation)
        .filter(DailyPreparation.business_date == business_date)
        .all()
    }

    touched: list[DailyPreparation] = []
    for a in resolver.articles:
        aid = str(a.id)
        est = quantize_qty(expected.get(aid, Decimal(0)))
        prep = existing.get(aid)
        if est <= 0:
            if prep is not None and prep.status == PREP_ESTIMATED:
                db.delete(prep)
            continue

        portion = resolver.portion(aid)
        yield_portions = Decimal(str(round(1.0 / float(portion), 2)))
        theo_dishes = calculate_theoretical_dishes(est, yield_portions)

        if prep is not None:
            prep.estimated_quantity = est
            if prep.status == PREP_ESTIMATED:
                prep.prepared_quantity = est
                prep.yield_portions_per_unit = yield_portions
                prep.theoretical_dishes = theo_dishes
                prep.user_id = user_id
                prep.notes = ESTIMATED_NOTE
            touched.append(prep)
        else:
            new_prep = DailyPreparation(
                business_date=business_date,
                article_id=aid,
                prepared_quantity=est,
                yield_portions_per_unit=yield_portions,
                theoretical_dishes=theo_dishes,
                user_id=user_id,
                notes=ESTIMATED_NOTE,
                status=PREP_ESTIMATED,
                estimated_quantity=est,
            )
            db.add(new_prep)
            touched.append(new_prep)
    return touched


# Nom historique, appelé par la clôture de caisse
auto_validate_daily_preparations_from_sales = estimate_daily_preparations_from_sales


# --- Matrice de contrôle (D6) : lue dans le grand livre, égale au stock -----------------


def _f(value: Decimal) -> float:
    return round(float(value), 3)


def get_weekly_matrix(
    db: Session, date_from: date, date_to: date
) -> WeeklyMatrixReportOut:
    """Matrice hebdomadaire du patron, lue dans le journal du stock (règle universelle D6) :
    Restant = Ouverture + Achats − Ventes − Pertes ± Écart d'inventaire ± Corrections.
    Le restant de fin de période est la quantité en stock à cette date. La sortie cuisine
    n'est qu'un contrôle (sorti contre vendu)."""
    days = protein_ledger.calendar(date_from, date_to)

    # 1. CA journalier réalisé (commandes soldées)
    revenue_rows = db.execute(
        select(CashSession.business_date, func.sum(Order.total_ttc_xof))
        .join(Order, Order.cash_session_id == CashSession.id)
        .where(
            Order.status == OrderStatus.PAID,
            CashSession.business_date >= date_from,
            CashSession.business_date <= date_to,
        )
        .group_by(CashSession.business_date)
    ).all()
    daily_revenues: dict[str, int] = {d.isoformat(): 0 for d in days}
    for d, amt in revenue_rows:
        daily_revenues[d.isoformat()] = int(amt or 0)

    # 2. Protéines, fiches techniques et grand livre
    resolver = protein_ledger.build_resolver(db)
    articles = resolver.articles
    ledger = protein_ledger.daily_ledger(db, articles, date_from, date_to)

    # 3. Ventes soldées rattachées à chaque protéine, et contrôle du déstockage
    lines = protein_ledger.paid_sale_lines(db, date_from, date_to)
    destocked = protein_ledger.destocked_by_item(db, [ln.item_id for ln in lines])
    sales: dict[tuple[str, date], dict[str, Decimal]] = {}
    for ln in lines:
        for aid, per_dish in resolver.protein_lines(ln.product_id, ln.name):
            agg = sales.setdefault(
                (aid, ln.business_date),
                {k: Decimal(0) for k in ("dishes", "revenue", "normal", "foufou", "foutou",
                                         "expected", "non_destocked")},
            )
            agg["dishes"] += ln.quantity
            agg["revenue"] += ln.revenue_xof
            agg[dish_variant(ln.name)] += ln.quantity
            agg["expected"] += per_dish * ln.quantity
            if destocked.get((ln.item_id, aid), Decimal(0)) <= 0:
                agg["non_destocked"] += ln.quantity

    # 4. Sorties cuisine (contrôle)
    prep_map: dict[tuple[str, date], DailyPreparation] = {
        (str(p.article_id), p.business_date): p
        for p in db.query(DailyPreparation)
        .filter(
            DailyPreparation.business_date >= date_from,
            DailyPreparation.business_date <= date_to,
        )
        .all()
    }

    rows: list[WeeklyProductRow] = []
    total_purchases_cost = 0
    total_variance_impact = 0

    for a in articles:
        aid = str(a.id)
        comps = resolver.components_by_article.get(aid, [])
        portion = resolver.portion(aid)
        default_yield = round(1.0 / float(portion), 2) if portion > 0 else 1.0

        normal_comp = next((c for c in comps if dish_variant(c.product.name if c.product else "") == "normal"), None)
        foufou_comp = next((c for c in comps if dish_variant(c.product.name if c.product else "") != "normal"), None)
        dish_selling_price = 3000
        if normal_comp and normal_comp.product and normal_comp.product.price_xof:
            dish_selling_price = int(normal_comp.product.price_xof)
        elif comps and comps[0].product and comps[0].product.price_xof:
            dish_selling_price = int(comps[0].product.price_xof)
        foufou_selling_price = dish_selling_price + 500
        if foufou_comp and foufou_comp.product and foufou_comp.product.price_xof:
            foufou_selling_price = int(foufou_comp.product.price_xof)

        led = ledger.get(aid) or [protein_ledger.LedgerDay(business_date=d) for d in days]
        opening = led[0].opening
        p_qty = sum((ld.purchases for ld in led), Decimal(0))
        p_cost = to_xof(sum((ld.purchases_value for ld in led), Decimal(0)))
        available = opening + p_qty
        total_purchases_cost += p_cost

        purchase_unit_price = to_xof(Decimal(p_cost) / p_qty) if p_qty > 0 else to_xof(a.avg_cost_xof)
        positive_available = max(Decimal(0), available)
        tot_available_cost = to_xof(positive_available * Decimal(purchase_unit_price))
        potential_dishes = int(round(float(positive_available) * default_yield))
        weekly_expected_rev = potential_dishes * dish_selling_price
        expected_margin_pct = (
            round(((weekly_expected_rev - tot_available_cost) * 100) / weekly_expected_rev, 2)
            if weekly_expected_rev > 0
            else 0.0
        )

        row_days: list[WeeklyDayData] = []
        tot = {k: 0 for k in ("theo", "sold", "var", "impact", "rev", "non_destocked")}
        tot_prep_qty = Decimal(0)
        tot_stock_sold = Decimal(0)
        tot_prep_gap = Decimal(0)

        for ld in led:
            d = ld.business_date
            prep = prep_map.get((aid, d))
            prepared_q = Decimal(prep.prepared_quantity) if prep else Decimal(0)
            day_yield = float(prep.yield_portions_per_unit) if prep else default_yield
            theo_dishes = prep.theoretical_dishes if prep else 0

            s = sales.get((aid, d))
            day_sold = int(s["dishes"]) if s else 0
            day_rev = int(s["revenue"]) if s else 0
            normal_sold = int(s["normal"]) if s else 0
            foufou_sold = int(s["foufou"]) if s else 0
            foutou_sold = int(s["foutou"]) if s else 0
            non_destocked = int(s["non_destocked"]) if s else 0
            expected_q = s["expected"] if s else Decimal(0)
            suggested_q = round(float(expected_q), 2)
            # Contrôle sorti cuisine − besoin des plats vendus (portion × plats encaissés,
            # déstockés ou non), seulement les jours où la sortie est saisie.
            prep_gap = prepared_q - expected_q if prep else Decimal(0)

            variance = calculate_dish_variance(day_sold, theo_dishes)
            avg_dish_price = (day_rev // day_sold) if day_sold > 0 else dish_selling_price
            impact = calculate_financial_impact(variance, avg_dish_price)
            day_expected_rev = theo_dishes * dish_selling_price
            day_actual_rev = day_rev if day_rev > 0 else (
                normal_sold * dish_selling_price + (foufou_sold + foutou_sold) * foufou_selling_price
            )

            tot_prep_qty += prepared_q
            tot_stock_sold += ld.sales
            tot_prep_gap += prep_gap
            tot["theo"] += theo_dishes
            tot["sold"] += day_sold
            tot["var"] += variance
            tot["impact"] += impact
            tot["rev"] += day_actual_rev
            tot["non_destocked"] += non_destocked

            row_days.append(
                WeeklyDayData(
                    business_date=d,
                    day_name=DAY_NAMES_FR[d.weekday()],
                    remaining_quantity=_f(ld.available),
                    prepared_quantity=_f(prepared_q),
                    suggested_quantity=suggested_q,
                    yield_portions_per_unit=day_yield,
                    theoretical_dishes=theo_dishes,
                    sold_dishes=day_sold,
                    normal_dishes_sold=normal_sold,
                    foufou_dishes_sold=foufou_sold,
                    foutou_dishes_sold=foutou_sold,
                    foufou_price_xof=foufou_selling_price,
                    variance_dishes=variance,
                    dish_price_xof=dish_selling_price,
                    expected_revenue_xof=day_expected_rev,
                    actual_revenue_xof=day_actual_rev,
                    revenue_variance_xof=day_actual_rev - day_expected_rev,
                    financial_impact_xof=impact,
                    notes=prep.notes if prep else None,
                    opening_quantity=_f(ld.opening),
                    purchased_quantity=_f(ld.purchases),
                    stock_sold_quantity=_f(ld.sales),
                    loss_quantity=_f(ld.losses),
                    inventory_variance_quantity=_f(ld.inventory),
                    correction_quantity=_f(ld.corrections),
                    closing_quantity=_f(ld.closing),
                    preparation_status=prep.status if prep else None,  # type: ignore[arg-type]
                    estimated_quantity=(
                        float(prep.estimated_quantity)
                        if prep and prep.estimated_quantity is not None
                        else None
                    ),
                    preparation_gap_quantity=_f(prep_gap),
                    non_destocked_dishes=non_destocked,
                )
            )

        total_variance_impact += tot["impact"]
        # Marge brute sur le coût de la matière consommée (CMP), comme la synthèse des
        # rendements : un achat fait avant la période ne donne plus une marge de 100 %.
        consumed_cost = to_xof(protein_ledger.consumed_quantity(led) * Decimal(a.avg_cost_xof))
        actual_margin_xof = tot["rev"] - consumed_cost
        actual_margin_pct = (
            round((actual_margin_xof * 100) / tot["rev"], 2) if tot["rev"] > 0 else 0.0
        )

        rows.append(
            WeeklyProductRow(
                article_id=aid,
                article_name=a.name,
                unit=a.unit,
                opening_stock_qty=_f(opening),
                weekly_purchased_qty=_f(p_qty),
                total_available_qty=_f(available),
                purchase_unit_price_xof=purchase_unit_price,
                weekly_purchased_cost_xof=p_cost,
                total_available_cost_xof=tot_available_cost,
                default_yield_portions=default_yield,
                weekly_potential_dishes=potential_dishes,
                dish_selling_price_xof=dish_selling_price,
                weekly_expected_revenue_xof=weekly_expected_rev,
                expected_margin_pct=expected_margin_pct,
                days=row_days,
                total_prepared_qty=_f(tot_prep_qty),
                total_theoretical_dishes=tot["theo"],
                total_sold_dishes=tot["sold"],
                total_variance_dishes=tot["var"],
                total_financial_impact_xof=tot["impact"],
                actual_revenue_xof=tot["rev"],
                actual_gross_margin_xof=actual_margin_xof,
                actual_gross_margin_pct=actual_margin_pct,
                quantity_variance=_f(tot_prep_gap),
                dishes_variance=tot["sold"] - potential_dishes,
                total_stock_sold_qty=_f(tot_stock_sold),
                total_loss_qty=_f(sum((ld.losses for ld in led), Decimal(0))),
                total_inventory_variance_qty=_f(sum((ld.inventory for ld in led), Decimal(0))),
                total_correction_qty=_f(sum((ld.corrections for ld in led), Decimal(0))),
                closing_stock_qty=_f(led[-1].closing),
                current_stock_qty=_f(Decimal(a.quantity)),
                total_non_destocked_dishes=tot["non_destocked"],
            )
        )

    total_revenue = sum(daily_revenues.values())
    return WeeklyMatrixReportOut(
        date_from=date_from,
        date_to=date_to,
        daily_revenues=daily_revenues,
        total_weekly_revenue_xof=total_revenue,
        total_weekly_purchases_xof=total_purchases_cost,
        total_variance_impact_xof=total_variance_impact,
        gross_margin_estimate_xof=total_revenue - total_purchases_cost,
        rows=rows,
    )

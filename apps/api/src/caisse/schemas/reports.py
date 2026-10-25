from datetime import date, datetime

from pydantic import Field

from caisse.domain.enums import (
    CashSessionStatus,
    PaymentMethod,
    StockArticleCategory,
    StockOutMode,
)
from caisse.schemas.common import BaseSchema as Schema

# --- Ventes ------------------------------------------------------------------------------


class SalesTotals(Schema):
    revenue_xof: int = Field(description="Chiffre d'affaires des commandes soldées")
    orders_count: int = Field(description="Nombre de commandes soldées")
    average_ticket_xof: int = Field(description="Panier moyen")
    recipe_cost_xof: int = Field(
        description="Coût matière des plats vendus, d'après leurs fiches techniques"
    )
    recipe_margin_xof: int = Field(description="Chiffre d'affaires - coût matière des fiches")
    uncosted_revenue_xof: int = Field(
        description="Part du chiffre d'affaires réalisée par des produits sans fiche technique"
    )
    inventory_consumption_xof: int = Field(
        description="Consommation des articles suivis par inventaire (légumes, gaz…) : "
        "écarts d'inventaire et pertes"
    )
    stock_variance_xof: int = Field(
        description="Écarts sur les articles à fiche (protéines, boissons) : manquants à "
        "l'inventaire et pertes déclarées ; négatif si l'inventaire trouve plus que prévu"
    )
    gross_margin_xof: int = Field(
        description="Marge brute : chiffre d'affaires - coût matière - consommation - écarts"
    )
    expenses_xof: int = Field(
        default=0, description="Total des dépenses d'exploitation (décaissements)"
    )
    net_result_xof: int = Field(
        default=0, description="Résultat net d'exploitation estimé (Marge brute - Dépenses)"
    )
    bank_deposit_xof: int = Field(
        default=0, description="Total des versements bancaires"
    )


class SalesDay(Schema):
    business_date: date = Field(description="Journée")
    orders_count: int = Field(description="Commandes soldées")
    revenue_xof: int = Field(description="Chiffre d'affaires")
    recipe_cost_xof: int = Field(description="Coût matière (fiches)")
    recipe_margin_xof: int = Field(description="Marge sur coût matière")
    purchases_xof: int = Field(default=0, description="Achats / Réceptions de marchandises du jour")
    inventory_consumption_xof: int = Field(
        default=0, description="Consommations inventaire et pertes du jour"
    )
    gross_margin_xof: int = Field(default=0, description="Marge brute du jour (CA - Coût matière - Pertes/Conso)")
    gross_margin_rate: float = Field(default=0.0, description="Taux de marge brute (%)")
    expenses_xof: int = Field(default=0, description="Dépenses d'exploitation du jour (décaissements)")
    net_result_xof: int = Field(default=0, description="Résultat net d'exploitation (Marge brute - Dépenses)")
    expected_cash_xof: int = Field(default=0, description="Espèces attendues en caisse")
    counted_cash_xof: int = Field(default=0, description="Espèces comptées / versées")
    cash_variance_xof: int = Field(default=0, description="Écart de caisse (compté - attendu)")
    bank_deposit_xof: int = Field(default=0, description="Versements en banque")


class SalesProduct(Schema):
    product_id: str = Field(description="Produit")
    name: str = Field(description="Nom à la vente")
    category: str = Field(description="Catégorie à la vente")
    quantity: int = Field(description="Quantité vendue")
    revenue_xof: int = Field(description="Chiffre d'affaires")
    has_recipe: bool = Field(description="Le produit a une fiche technique aujourd'hui")
    recipe_cost_xof: int = Field(description="Coût matière (0 sans fiche)")
    recipe_margin_xof: int = Field(description="Marge sur coût matière")


class SalesCategory(Schema):
    category: str = Field(description="Catégorie")
    quantity: int = Field(description="Quantité vendue")
    revenue_xof: int = Field(description="Chiffre d'affaires")
    recipe_cost_xof: int = Field(description="Coût matière (fiches)")
    recipe_margin_xof: int = Field(description="Marge sur coût matière")


class SalesPaymentMethod(Schema):
    method: PaymentMethod = Field(description="Moyen de paiement")
    count: int = Field(description="Nombre de paiements")
    amount_xof: int = Field(description="Montant encaissé")


class SalesCashSession(Schema):
    id: str = Field(description="Session de caisse")
    business_date: date = Field(description="Journée")
    status: CashSessionStatus = Field(description="État")
    z_number: int | None = Field(description="Numéro du Z (clôturée)")
    expected_cash_xof: int | None = Field(description="Espèces attendues à la clôture")
    counted_cash_xof: int | None = Field(description="Espèces comptées")
    variance_xof: int | None = Field(description="Écart de caisse (compté - attendu)")


class SalesReportOut(Schema):
    date_from: date = Field(description="Première journée incluse")
    date_to: date = Field(description="Dernière journée incluse")
    totals: SalesTotals
    by_day: list[SalesDay] = Field(description="Une ligne par journée avec des ventes")
    by_product: list[SalesProduct] = Field(description="Par chiffre d'affaires décroissant")
    by_category: list[SalesCategory] = Field(description="Par chiffre d'affaires décroissant")
    by_payment_method: list[SalesPaymentMethod] = Field(description="Encaissements par moyen")
    cash_sessions: list[SalesCashSession] = Field(description="Sessions de la période")


# --- Stock -------------------------------------------------------------------------------


class StockTotals(Schema):
    stock_value_xof: int = Field(description="Valeur du stock actuel (coût moyen)")
    purchases_xof: int = Field(description="Achats de la période")
    sales_cost_xof: int = Field(description="Sorties par les ventes (coût matière)")
    inventory_consumption_xof: int = Field(
        description="Consommation des articles suivis par inventaire (écarts et pertes)"
    )
    stock_variance_xof: int = Field(
        description="Écarts sur les articles à fiche (inventaire et pertes)"
    )
    low_count: int = Field(description="Articles en alerte (stock négatif ou sous le seuil)")


class StockReportArticle(Schema):
    article_id: str = Field(description="Article")
    name: str = Field(description="Nom")
    category: StockArticleCategory = Field(description="Famille")
    unit: str = Field(description="Unité")
    out_mode: StockOutMode = Field(description="RECIPE ou INVENTORY")
    opening_quantity: float = Field(description="Stock au début de la période")
    purchased_quantity: float = Field(description="Entrées (achats)")
    purchases_xof: int = Field(description="Montant des achats")
    sold_quantity: float = Field(description="Sorties par les ventes (nettes des annulations)")
    loss_quantity: float = Field(description="Pertes déclarées")
    count_adjustment_quantity: float = Field(
        description="Écart d'inventaire (+ trouvé en plus, - manquant)"
    )
    closing_quantity: float = Field(description="Stock à la fin de la période")
    consumption_quantity: float = Field(description="Consommation totale : début + entrées - fin")
    consumption_xof: int = Field(description="Valeur de la consommation")
    quantity: float = Field(description="Stock actuel")
    avg_cost_xof: float = Field(description="Coût moyen actuel")
    value_xof: int = Field(description="Valeur du stock actuel")
    alert_threshold: float | None = Field(description="Seuil d'alerte")
    is_low: bool = Field(description="En alerte")
    last_count_date: date | None = Field(description="Dernier inventaire (avant la fin)")


class StockReportOut(Schema):
    date_from: date = Field(description="Première journée incluse")
    date_to: date = Field(description="Dernière journée incluse")
    totals: StockTotals
    articles: list[StockReportArticle] = Field(description="Par famille puis par nom")


# --- Tableau de bord du jour -------------------------------------------------------------


class DashboardPayment(Schema):
    method: PaymentMethod = Field(description="Moyen de paiement")
    provider: str | None = Field(description="Opérateur Mobile Money (WAVE, ORANGE…), sinon null")
    count: int = Field(description="Nombre de paiements")
    amount_xof: int = Field(description="Montant encaissé")


class DashboardProduct(Schema):
    product_id: str = Field(description="Produit")
    name: str = Field(description="Nom à la vente")
    quantity: int = Field(description="Quantité vendue")
    revenue_xof: int = Field(description="Chiffre d'affaires")


class DashboardHour(Schema):
    hour: int = Field(description="Heure d'encaissement (0 à 23, heure d'Abidjan)")
    orders_count: int = Field(description="Commandes soldées dans l'heure")
    revenue_xof: int = Field(description="Chiffre d'affaires de l'heure")


class DashboardCashier(Schema):
    user_id: str = Field(description="Utilisateur qui a soldé les commandes")
    full_name: str = Field(description="Nom")
    orders_count: int = Field(description="Commandes soldées")
    revenue_xof: int = Field(description="Chiffre d'affaires")


class DashboardSession(Schema):
    id: str = Field(description="Session de caisse")
    cash_register: str = Field(description="Nom de la caisse")
    status: CashSessionStatus = Field(description="OPEN, CLOSING ou CLOSED")
    opened_by: str = Field(description="Ouverte par")
    opened_at: datetime = Field(description="Ouverture")
    closed_at: datetime | None = Field(description="Clôture (Z)")
    z_number: int | None = Field(description="Numéro du Z")
    variance_xof: int | None = Field(description="Écart de caisse à la clôture")


class DashboardFne(Schema):
    certified: int = Field(description="Commandes de la journée avec une FNE certifiée")
    pending: int = Field(description="Documents FNE de la journée encore en attente")


class DashboardOut(Schema):
    business_date: date = Field(description="Journée comptable")
    revenue_xof: int = Field(description="Chiffre d'affaires des commandes soldées")
    orders_paid: int = Field(description="Commandes soldées")
    orders_open: int = Field(description="Commandes encore ouvertes (OPEN, PARTIALLY_PAID)")
    orders_cancelled: int = Field(description="Commandes annulées")
    average_ticket_xof: int = Field(description="Panier moyen")
    guests_count: int = Field(description="Couverts des commandes soldées (quand saisis)")
    dine_in_orders: int = Field(description="Commandes soldées servies à table")
    takeaway_orders: int = Field(description="Commandes soldées à emporter")
    tables_occupied: int = Field(description="Tables qui portent une commande active")
    tables_total: int = Field(description="Tables en service")
    payments: list[DashboardPayment] = Field(description="Encaissements par moyen et opérateur")
    top_products: list[DashboardProduct] = Field(description="10 meilleures ventes (CA)")
    hourly: list[DashboardHour] = Field(description="Heures avec des encaissements")
    by_cashier: list[DashboardCashier] = Field(description="Ventes par personne qui a encaissé")
    sessions: list[DashboardSession] = Field(description="Sessions de caisse de la journée")
    low_stock_articles: int = Field(description="Articles de stock en alerte (aujourd'hui)")
    fne: DashboardFne = Field(description="Factures normalisées de la journée")


# --- Rendement & Contrôle des Protéines (Viandes & Poissons) -----------------------------


class ProteinYieldItem(Schema):
    article_id: str = Field(description="Identifiant de l'article de stock")
    article_name: str = Field(description="Nom de la matière première (ex: Bœuf, Mouton)")
    category: StockArticleCategory = Field(description="Famille de stock")
    unit: str = Field(description="Unité de mesure (kg, pièce, morceau)")
    avg_cost_xof: float = Field(description="Coût moyen unitaire d'achat (CMP)")
    standard_portion: float = Field(description="Quantité standard consommée par plat (fiche)")
    yield_ratio_per_unit: float = Field(description="Nombre de plats théoriques par unité")
    consumed_quantity: float = Field(description="Quantité totale sortie / consommée")
    consumed_cost_xof: int = Field(description="Valeur matière de la quantité sortie")
    theoretical_dishes: int = Field(description="Nombre de plats théoriquement réalisables")
    sold_dishes: int = Field(description="Nombre de plats réellement enregistrés et vendus")
    sold_revenue_xof: int = Field(description="Chiffre d'affaires généré par ces plats")
    gross_margin_xof: int = Field(description="Marge brute directe (Ventes - Coût matière)")
    loss_dishes: int = Field(default=0, description="Portions couvertes par des pertes déclarées")
    variance_dishes: int = Field(
        description="Écart de portions (Théorique - Vendu - Pertes). Positif = manquant"
    )
    financial_impact_xof: int = Field(
        description="Valeur financière estimée de l'écart de portions"
    )
    status: str = Field(description="Statut : NORMAL, WARNING ou CRITICAL")
    associated_products: list[str] = Field(description="Plats qui consomment cet article")


class ProteinYieldTotals(Schema):
    total_consumed_cost_xof: int = Field(description="Coût matière total des viandes/poissons")
    total_sold_revenue_xof: int = Field(description="Chiffre d'affaires total généré")
    total_gross_margin_xof: int = Field(description="Marge brute directe totale")
    total_theoretical_dishes: int = Field(description="Total des plats théoriques attendus")
    total_sold_dishes: int = Field(description="Total des plats servis")
    total_variance_dishes: int = Field(description="Total des portions manquantes")
    total_financial_impact_xof: int = Field(description="Impact financier total des écarts")
    anomalies_count: int = Field(description="Nombre d'articles en anomalie")


class ProteinYieldReportOut(Schema):
    date_from: date = Field(description="Première journée incluse")
    date_to: date = Field(description="Dernière journée incluse")
    totals: ProteinYieldTotals
    items: list[ProteinYieldItem] = Field(description="Détail par viande/poisson")


# --- KPI & Synthèse Temps Réel -----------------------------------------------------------


class TopProductReport(Schema):
    product_id: str
    product_name: str
    category_name: str | None = None
    quantity_sold: float
    total_revenue_xof: int


class PaymentMethodSplit(Schema):
    method: str
    provider: str | None = None
    count: int
    total_amount_xof: int


class HourlySalesItem(Schema):
    hour: str
    total_sales_xof: int
    orders_count: int


class ClosingStatusResponse(Schema):
    is_closed: bool
    closed_at: str | None = None
    closed_by_name: str | None = None
    session_id: str | None = None
    z_number: int | None = None


class CashierSalesResponse(Schema):
    cashier_name: str
    orders_count: int
    total_sales_ttc_xof: int


class DashboardKpiResponse(Schema):
    business_date: str
    total_orders: int
    settled_orders: int
    open_orders: int = 0
    active_tables_count: int = 0
    total_tables_count: int = 14
    dine_in_orders_count: int = 0
    takeaway_orders_count: int = 0
    total_sales_ttc_xof: int
    total_sales_ht_xof: int
    total_sales_vat_xof: int
    average_basket_xof: int
    payments_by_method: list[PaymentMethodSplit]
    top_products: list[TopProductReport]
    hourly_sales: list[HourlySalesItem] = Field(default_factory=list)
    active_sessions_count: int
    low_stock_items_count: int
    fne_certified_count: int
    fne_pending_count: int
    closing_status: ClosingStatusResponse | None = None
    last_x_report_at: str | None = None
    sales_by_cashier: list[CashierSalesResponse] = Field(default_factory=list)


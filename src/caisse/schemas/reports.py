import uuid
from datetime import date, datetime

from pydantic import Field

from caisse.domain.enums import (
    CashSessionStatus,
    PaymentMethod,
    StockArticleCategory,
    StockOutMode,
)
from caisse.schemas.common import Schema

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


class SalesDay(Schema):
    business_date: date = Field(description="Journée")
    orders_count: int = Field(description="Commandes soldées")
    revenue_xof: int = Field(description="Chiffre d'affaires")
    recipe_cost_xof: int = Field(description="Coût matière (fiches)")
    recipe_margin_xof: int = Field(description="Marge sur coût matière")


class SalesProduct(Schema):
    product_id: uuid.UUID = Field(description="Produit")
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
    id: uuid.UUID = Field(description="Session de caisse")
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
    article_id: uuid.UUID = Field(description="Article")
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


# --- Rendement des fiches ----------------------------------------------------------------


class YieldProduct(Schema):
    product_id: uuid.UUID = Field(description="Plat")
    name: str = Field(description="Nom à la vente")
    portion_quantity: float = Field(description="Quantité d'article par plat")
    quantity: int = Field(description="Plats vendus (nets des annulations)")
    revenue_xof: int = Field(description="Chiffre d'affaires du plat")


class YieldArticle(Schema):
    article_id: uuid.UUID = Field(description="Article à fiche (protéine, boisson…)")
    name: str = Field(description="Nom", examples=["Bœuf"])
    category: StockArticleCategory = Field(description="Famille")
    unit: str = Field(description="Unité", examples=["kg"])
    counted_in_period: bool = Field(
        description="Un inventaire a été saisi dans la période : sans lui, l'écart vaut 0"
    )
    last_count_date: date | None = Field(description="Dernier inventaire (au plus la fin)")
    opening_quantity: float = Field(description="Stock au début de la période")
    purchased_quantity: float = Field(description="Entrées (achats)")
    closing_quantity: float = Field(description="Stock à la fin de la période")
    consumed_quantity: float = Field(description="Consommé : début + entrées - fin")
    portion_quantity: float = Field(
        description="Quantité moyenne par plat (fiches appliquées aux ventes de la période)"
    )
    expected_portions: float = Field(description="Plats prévus : consommé / quantité par plat")
    sold_portions: int = Field(description="Plats vendus à la caisse")
    portion_variance: float = Field(
        description="Écart en plats : prévus - vendus (positif : consommé sans vente)"
    )
    loss_portions: float = Field(description="Dont pertes déclarées, en plats")
    unexplained_portions: float = Field(
        description="Dont manquant à l'inventaire, en plats (écart - pertes)"
    )
    sold_xof: int = Field(description="Montant des plats vendus")
    average_price_xof: int = Field(
        description="Prix moyen d'un plat (pondéré par les ventes ; sans vente : prix actuels)"
    )
    variance_xof: int = Field(description="Montant de l'écart : écart en plats x prix moyen")
    unexplained_xof: int = Field(description="Montant du manquant non expliqué par les pertes")
    products: list[YieldProduct] = Field(description="Plats qui utilisent l'article")


class YieldTotals(Schema):
    sold_xof: int = Field(description="Montant des plats vendus (articles à fiche)")
    variance_xof: int = Field(description="Montant total des écarts, au prix de vente")
    unexplained_xof: int = Field(description="Dont manquants non expliqués par les pertes")
    articles_counted: int = Field(description="Articles inventoriés dans la période")


class YieldReportOut(Schema):
    date_from: date = Field(description="Première journée incluse")
    date_to: date = Field(description="Dernière journée incluse")
    totals: YieldTotals
    articles: list[YieldArticle] = Field(description="Par montant d'écart décroissant")


# --- Tableau de bord du jour -------------------------------------------------------------


class DashboardPayment(Schema):
    method: PaymentMethod = Field(description="Moyen de paiement")
    provider: str | None = Field(description="Opérateur Mobile Money (WAVE, ORANGE…), sinon null")
    count: int = Field(description="Nombre de paiements")
    amount_xof: int = Field(description="Montant encaissé")


class DashboardProduct(Schema):
    product_id: uuid.UUID = Field(description="Produit")
    name: str = Field(description="Nom à la vente")
    quantity: int = Field(description="Quantité vendue")
    revenue_xof: int = Field(description="Chiffre d'affaires")


class DashboardHour(Schema):
    hour: int = Field(description="Heure d'encaissement (0 à 23, heure d'Abidjan)")
    orders_count: int = Field(description="Commandes soldées dans l'heure")
    revenue_xof: int = Field(description="Chiffre d'affaires de l'heure")


class DashboardCashier(Schema):
    user_id: uuid.UUID = Field(description="Utilisateur qui a soldé les commandes")
    full_name: str = Field(description="Nom")
    orders_count: int = Field(description="Commandes soldées")
    revenue_xof: int = Field(description="Chiffre d'affaires")


class DashboardSession(Schema):
    id: uuid.UUID = Field(description="Session de caisse")
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

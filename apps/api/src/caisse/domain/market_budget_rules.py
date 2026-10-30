"""Règles métier du budget marché (approvisionnement et production).

Règles de gestion :
1. Plafond absolu marché : 300 000 XOF
2. Réserve patronale / invisible : 155 000 XOF
3. Seuil alloué à l'économe : 145 000 XOF (300 000 - 155 000)

Confidentialité :
L'économe / acheteur ne voit AUCUN montant chiffré (ni plafond, ni total).
Il voit uniquement une jauge visuelle (ratio, pourcentage, couleur, libellé).
Dès dépassement de son seuil, la transmission est bloquée (MARKET_BUDGET_EXCEEDED).
Seul le Responsable ou l'Administrateur peut visualiser les montants chiffrés.
"""

from decimal import Decimal
from typing import Any, TypedDict

from caisse.errors import MarketBudgetExceededError


class MarketCondimentItem(TypedDict):
    name: str
    quantity: Decimal
    unit_price_xof: int


DEFAULT_TOTAL_LIMIT_XOF = 300_000
DEFAULT_ECONOME_LIMIT_XOF = 180_000
DEFAULT_RESERVE_XOF = 120_000
ECONOME_TOLERANCE_XOF = 2_000  # Tolérance souple (ex: 180 338 XOF autorisé)

# Panier type hebdomadaire des condiments financé par l'enveloppe de 120 000 XOF (Option 1)
# Totalise exactement 120 000 FCFA avec les articles existants en base
DEFAULT_MARKET_CONDIMENTS_KIT: list[MarketCondimentItem] = [
    {"name": "Oignon violet", "quantity": Decimal("20.0"), "unit_price_xof": 700},      # 14 000
    {"name": "Tomate", "quantity": Decimal("15.0"), "unit_price_xof": 1000},            # 15 000
    {"name": "Ail", "quantity": Decimal("4.0"), "unit_price_xof": 1500},                # 6 000
    {"name": "Piment", "quantity": Decimal("16.0"), "unit_price_xof": 500},             # 8 000
    {"name": "Huile", "quantity": Decimal("15.0"), "unit_price_xof": 1060},             # 15 900
    {"name": "Huile rouge", "quantity": Decimal("5.0"), "unit_price_xof": 2000},         # 10 000
    {"name": "Assaisonnement vert", "quantity": Decimal("20.0"), "unit_price_xof": 150},# 3 000
    {"name": "Tomate en pâte", "quantity": Decimal("4.0"), "unit_price_xof": 2250},      # 9 000
    {"name": "Gombo", "quantity": Decimal("10.0"), "unit_price_xof": 500},               # 5 000
    {"name": "Feuille de dah", "quantity": Decimal("2.0"), "unit_price_xof": 3000},      # 6 000
    {"name": "Attiéké", "quantity": Decimal("20.0"), "unit_price_xof": 500},            # 10 000
    {"name": "Banane alloco", "quantity": Decimal("16.0"), "unit_price_xof": 500},      # 8 000
    {"name": "Riz", "quantity": Decimal("15.0"), "unit_price_xof": 640},                # 9 600
    {"name": "Poivron", "quantity": Decimal("0.385"), "unit_price_xof": 1300},          # 500
]


def calculate_market_budget_status(
    total_budget_xof: int,
    *,
    role: str = "ECONOME",
    total_limit: int = DEFAULT_TOTAL_LIMIT_XOF,
    econome_limit: int = DEFAULT_ECONOME_LIMIT_XOF,
    other_envelope: int = DEFAULT_RESERVE_XOF,
) -> dict[str, Any]:
    """Calcule le statut budgétaire du marché.
    Pour l'économe : référence à 180 000 XOF (protéines), les 120 000 XOF restent secrets.
    Pour le responsable : vue complète à 300 000 XOF avec montant réel décaissé (protéines + 120 000).
    """
    is_supervisor = role in ("RESPONSABLE", "ADMIN")
    reference_limit = econome_limit if not is_supervisor else econome_limit

    ratio = total_budget_xof / reference_limit if reference_limit > 0 else 0.0
    percentage = min(100, int(ratio * 100))
    is_exceeded = total_budget_xof > (econome_limit + ECONOME_TOLERANCE_XOF)

    if total_budget_xof <= 0:
        level_text = "Panier vide — Ajustez les quantités requises"
        color_class = "slate"
    elif ratio < 0.70:
        level_text = "Capacité disponible — Approvisionnement standard"
        color_class = "emerald"
    elif not is_exceeded:
        level_text = "Niveau élevé — Proche de la capacité maximale autorisée"
        color_class = "amber"
    else:
        level_text = "Capacité maximale atteinte — Transmission bloquée"
        color_class = "rose"

    real_disbursement = (total_budget_xof + other_envelope) if is_supervisor else None
    remaining_total = max(0, total_limit - (total_budget_xof + other_envelope)) if is_supervisor else None

    return {
        "ratio": round(ratio, 4),
        "percentage": percentage,
        "is_exceeded": is_exceeded,
        "level_text": level_text,
        "color_class": color_class,
        "total_budget_xof": total_budget_xof,
        "econome_limit_xof": econome_limit,
        "total_limit_xof": total_limit if is_supervisor else econome_limit,
        "other_envelope_xof": other_envelope if is_supervisor else None,
        "real_disbursement_xof": real_disbursement,
        "remaining_budget_xof": remaining_total if is_supervisor else max(0, econome_limit - total_budget_xof),
        "remaining_econome_xof": max(0, econome_limit - total_budget_xof),
    }


def validate_market_budget(
    total_budget_xof: int,
    *,
    role: str = "ECONOME",
    total_limit: int = DEFAULT_TOTAL_LIMIT_XOF,
    econome_limit: int = DEFAULT_ECONOME_LIMIT_XOF,
    tolerance_xof: int = ECONOME_TOLERANCE_XOF,
) -> None:
    """Valide qu'un budget prévisionnel ne dépasse pas le plafond autorisé pour le rôle.
    Lève MarketBudgetExceededError en cas de dépassement.
    """
    if total_budget_xof > total_limit:
        raise MarketBudgetExceededError(
            f"Le budget prévisionnel ({total_budget_xof:,} XOF) dépasse le plafond absolu autorisé ({total_limit:,} XOF).",
            meta={"total_budget_xof": total_budget_xof, "limit_xof": total_limit},
        )

    if role in ("ECONOME", "ACHETEUR", "CAISSIER") and total_budget_xof > (econome_limit + tolerance_xof):
        raise MarketBudgetExceededError(
            "Le montant prévisionnel dépasse la capacité maximale autorisée pour les protéines.",
            meta={"limit_xof": econome_limit, "total_budget_xof": total_budget_xof},
        )


def get_market_budget_limits(db: Any) -> tuple[int, int, int]:
    """Retourne (total_limit, econome_limit, reserve) en interrogeant la table `settings` (AppSetting)
    avec repli sur les paramètres de configuration."""
    from caisse.config import get_settings
    from caisse.models.settings import AppSetting

    cfg = get_settings()
    total = cfg.MARKET_BUDGET_TOTAL_LIMIT_XOF
    econome = cfg.MARKET_BUDGET_ECONOME_LIMIT_XOF
    reserve = cfg.MARKET_BUDGET_RESERVE_XOF

    try:
        setting = db.query(AppSetting).filter(AppSetting.key == "market_budget").first()
        if setting and isinstance(setting.value, dict):
            total = int(setting.value.get("total_limit_xof", total))
            econome = int(setting.value.get("econome_limit_xof", econome))
            reserve = int(setting.value.get("reserve_xof", reserve))
    except Exception:
        pass

    return total, econome, reserve

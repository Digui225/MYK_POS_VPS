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

from typing import Any

from caisse.errors import MarketBudgetExceededError

DEFAULT_TOTAL_LIMIT_XOF = 300_000
DEFAULT_ECONOME_LIMIT_XOF = 145_000
DEFAULT_RESERVE_XOF = 155_000


def calculate_market_budget_status(
    total_budget_xof: int,
    *,
    role: str = "ECONOME",
    total_limit: int = DEFAULT_TOTAL_LIMIT_XOF,
    econome_limit: int = DEFAULT_ECONOME_LIMIT_XOF,
) -> dict[str, Any]:
    """Calcule le statut visuel du budget marché.
    Masque les montants financiers pour les rôles opérationnels (Économe, Acheteur, Caissier).
    """
    is_supervisor = role in ("RESPONSABLE", "ADMIN")
    reference_limit = total_limit if is_supervisor else econome_limit

    ratio = total_budget_xof / reference_limit if reference_limit > 0 else 0.0
    percentage = min(100, int(ratio * 100))
    is_exceeded = total_budget_xof > reference_limit

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

    base_status: dict[str, Any] = {
        "ratio": round(ratio, 4),
        "percentage": percentage,
        "is_exceeded": is_exceeded,
        "level_text": level_text,
        "color_class": color_class,
    }

    if is_supervisor:
        base_status.update(
            {
                "total_budget_xof": total_budget_xof,
                "econome_limit_xof": econome_limit,
                "total_limit_xof": total_limit,
                "remaining_budget_xof": max(0, total_limit - total_budget_xof),
                "remaining_econome_xof": max(0, econome_limit - total_budget_xof),
            }
        )

    return base_status


def validate_market_budget(
    total_budget_xof: int,
    *,
    role: str = "ECONOME",
    total_limit: int = DEFAULT_TOTAL_LIMIT_XOF,
    econome_limit: int = DEFAULT_ECONOME_LIMIT_XOF,
) -> None:
    """Valide qu'un budget prévisionnel ne dépasse pas le plafond autorisé pour le rôle.
    Lève MarketBudgetExceededError en cas de dépassement.
    """
    if total_budget_xof > total_limit:
        raise MarketBudgetExceededError(
            f"Le budget prévisionnel ({total_budget_xof:,} XOF) dépasse le plafond absolu autorisé ({total_limit:,} XOF).",
            meta={"total_budget_xof": total_budget_xof, "limit_xof": total_limit},
        )

    if role in ("ECONOME", "ACHETEUR", "CAISSIER") and total_budget_xof > econome_limit:
        raise MarketBudgetExceededError(
            "Le montant prévisionnel dépasse la capacité maximale autorisée.",
            meta={"limit_xof": econome_limit},
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

from enum import StrEnum


class UserRole(StrEnum):
    CAISSIER = "CAISSIER"
    RESPONSABLE = "RESPONSABLE"
    ADMIN = "ADMIN"


# Hiérarchie : un rôle hérite des droits des rôles inférieurs.
ROLE_RANK: dict[UserRole, int] = {UserRole.CAISSIER: 1, UserRole.RESPONSABLE: 2, UserRole.ADMIN: 3}


def role_at_least(role: UserRole, required: UserRole) -> bool:
    return ROLE_RANK[role] >= ROLE_RANK[required]


class CashSessionStatus(StrEnum):
    OPEN = "OPEN"
    CLOSING = "CLOSING"
    CLOSED = "CLOSED"


class CashMovementType(StrEnum):
    IN = "IN"
    OUT = "OUT"


class CategoryKind(StrEnum):
    FOOD = "FOOD"
    DRINK = "DRINK"
    OTHER = "OTHER"


class OrderStatus(StrEnum):
    OPEN = "OPEN"
    PARTIALLY_PAID = "PARTIALLY_PAID"
    PAID = "PAID"
    CANCELLED = "CANCELLED"
    REFUNDED = "REFUNDED"


ACTIVE_ORDER_STATUSES = (OrderStatus.OPEN, OrderStatus.PARTIALLY_PAID)


class PaymentMethod(StrEnum):
    CASH = "CASH"
    MOBILE_MONEY = "MOBILE_MONEY"
    CARD = "CARD"
    BANK_TRANSFER = "BANK_TRANSFER"
    CREDIT = "CREDIT"
    OTHER = "OTHER"


class MobileMoneyProvider(StrEnum):
    ORANGE = "ORANGE"
    MTN = "MTN"
    MOOV = "MOOV"
    WAVE = "WAVE"


class PaymentStatus(StrEnum):
    CAPTURED = "CAPTURED"
    VOIDED = "VOIDED"


class StockMovementType(StrEnum):
    PURCHASE_IN = "PURCHASE_IN"
    SALE_OUT = "SALE_OUT"  # sortie automatique à l'encaissement (fiche technique)
    RETURN_IN = "RETURN_IN"  # remise en stock : paiement annulé, la commande n'est plus soldée
    LOSS_OUT = "LOSS_OUT"
    ADJUSTMENT = "ADJUSTMENT"
    INVENTORY_COUNT = "INVENTORY_COUNT"  # écart constaté au comptage
    OPENING = "OPENING"  # stock de départ : premier comptage d'un article sans mouvement


class StockArticleCategory(StrEnum):
    PROTEINE = "PROTEINE"
    BOISSON = "BOISSON"
    EPICERIE = "EPICERIE"  # légumes, condiments, féculents
    EMBALLAGE = "EMBALLAGE"
    ENTRETIEN = "ENTRETIEN"
    ENERGIE = "ENERGIE"


class StockOutMode(StrEnum):
    RECIPE = "RECIPE"  # sorties automatiques depuis les plats vendus (fiches techniques)
    INVENTORY = "INVENTORY"  # consommation déduite des inventaires (légumes, gaz…)


class FneDocumentType(StrEnum):
    FNE = "FNE"
    REFUND = "REFUND"  # facture d'avoir FNE, rattachée à une FNE certifiée
    RNE = "RNE"
    DAILY_SUMMARY = "DAILY_SUMMARY"


class FneStatus(StrEnum):
    # 03-CONTRAT-API §4.6 (PENDING ajouté par ADR-15, absent de 01-BACKEND §4.5)
    DRAFT = "DRAFT"
    PENDING = "PENDING"
    QUEUED = "QUEUED"
    SUBMITTING = "SUBMITTING"
    CERTIFIED = "CERTIFIED"
    FAILED = "FAILED"
    MANUAL = "MANUAL"


class PrintJobType(StrEnum):
    RECEIPT = "RECEIPT"
    X_REPORT = "X_REPORT"
    Z_REPORT = "Z_REPORT"
    FNE = "FNE"
    ORDER_TICKET = "ORDER_TICKET"
    DRAWER = "DRAWER"  # ouverture manuelle du tiroir, sans ticket
    TEST = "TEST"


class PrintJobStatus(StrEnum):
    QUEUED = "QUEUED"
    PRINTING = "PRINTING"
    DONE = "DONE"
    FAILED = "FAILED"


class OutboxStatus(StrEnum):
    PENDING = "PENDING"
    PROCESSING = "PROCESSING"
    DONE = "DONE"
    FAILED = "FAILED"

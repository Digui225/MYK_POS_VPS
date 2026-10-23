from enum import StrEnum


class UserRole(StrEnum):
    ECONOME = "ECONOME"  # bons d'achat marché, prévisions, préparations cuisine
    CAISSIER = "CAISSIER"
    RESPONSABLE = "RESPONSABLE"
    ADMIN = "ADMIN"


# Hiérarchie : un rôle hérite des droits des rôles inférieurs.
ROLE_RANK: dict[UserRole, int] = {
    UserRole.ECONOME: 0,
    UserRole.CAISSIER: 1,
    UserRole.RESPONSABLE: 2,
    UserRole.ADMIN: 3,
}


def role_at_least(role: UserRole | str, required: UserRole) -> bool:
    r = UserRole(role) if isinstance(role, str) else role
    return ROLE_RANK.get(r, 0) >= ROLE_RANK[required]


class PurchaseStatus(StrEnum):
    SUBMITTED = "SUBMITTED"  # envoyée par l'acheteur, à valider
    APPROVED = "APPROVED"  # validée (quantités et prix éventuellement corrigés), à décaisser
    DISBURSED = "DISBURSED"  # argent remis à l'acheteur, achats en cours
    RECEIVED = "RECEIVED"  # achats réceptionnés : entrées de stock faites
    REJECTED = "REJECTED"  # refusée par un responsable
    CANCELLED = "CANCELLED"  # retirée par l'acheteur avant validation


class SessionStatus(StrEnum):
    OPEN = "OPEN"
    CLOSING = "CLOSING"
    CLOSED = "CLOSED"


class CashMovementType(StrEnum):
    IN = "IN"
    OUT = "OUT"


class OrderStatus(StrEnum):
    OPEN = "OPEN"
    PARTIALLY_PAID = "PARTIALLY_PAID"
    PAID = "PAID"
    CANCELLED = "CANCELLED"
    REFUNDED = "REFUNDED"


ACTIVE_ORDER_STATUSES = (OrderStatus.OPEN, OrderStatus.PARTIALLY_PAID)
CashSessionStatus = SessionStatus


class PaymentStatus(StrEnum):
    PENDING = "PENDING"
    CAPTURED = "CAPTURED"
    FAILED = "FAILED"
    REFUNDED = "REFUNDED"
    CANCELLED = "CANCELLED"


class PaymentMethod(StrEnum):
    CASH = "CASH"
    MOBILE_MONEY = "MOBILE_MONEY"
    CARD = "CARD"
    BANK_TRANSFER = "BANK_TRANSFER"
    CREDIT = "CREDIT"
    OTHER = "OTHER"


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
    REFUND = "REFUND"
    RNE = "RNE"
    DAILY_SUMMARY = "DAILY_SUMMARY"


class FneStatus(StrEnum):
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


class PrintJobStatus(StrEnum):
    QUEUED = "QUEUED"
    PRINTING = "PRINTING"
    DONE = "DONE"
    FAILED = "FAILED"

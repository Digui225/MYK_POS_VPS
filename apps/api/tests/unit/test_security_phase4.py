import pytest
from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.database import engine
from caisse.core.errors import CaisseException
from caisse.domain.enums import OrderStatus
from caisse.domain.order_rules import assert_order_editable
from caisse.models.customer import Customer
from caisse.repositories.customers import CustomerRepository


def test_sql_injection_resilience_in_customer_search(db_session: Session) -> None:
    """Vérifie que les recherches textuelles sont immunisées contre les injections SQL."""
    repo = CustomerRepository(db_session)

    # Insertion d'un client légitime
    legit_customer = Customer(
        id="cust-sql-01",
        name="Entreprise Test SARL",
        ncc="0123456A",
        phone="+2250700000000",
        is_active=True,
    )
    repo.add(legit_customer)
    db_session.commit()

    # Tentatives d'injections SQL malveillantes
    sql_injections = [
        "'; DROP TABLE users; --",
        "' OR '1'='1",
        "\" OR \"\"=\"",
        "admin'--",
        "UNION SELECT NULL, NULL, NULL--",
    ]

    for payload in sql_injections:
        # La recherche doit s'exécuter sans erreur de syntaxe SQL et ne rien renvoyer
        results = repo.search(query=payload)
        assert isinstance(results, list)
        assert legit_customer not in results


def test_order_immutability_rules_reject_modifications_after_payment() -> None:
    """Vérifie l'invariant : aucune modification permise après encaissement ou annulation."""
    # États non modifiables
    immutable_statuses = [
        OrderStatus.PAID,
        OrderStatus.CANCELLED,
        OrderStatus.REFUNDED,
    ]

    for imm_status in immutable_statuses:
        with pytest.raises(CaisseException) as exc_info:
            assert_order_editable(imm_status)
        assert exc_info.value.code == "ORDER_NOT_EDITABLE"
        assert exc_info.value.status_code == status.HTTP_409_CONFLICT

    # États modifiables
    assert_order_editable(OrderStatus.OPEN)
    assert_order_editable(OrderStatus.PARTIALLY_PAID)


def test_database_engine_security_configuration() -> None:
    """Vérifie que l'engine de base de données est configuré avec des paramètres sécurisés."""
    # Vérification du pool
    if hasattr(engine.pool, "_timeout"):
        assert engine.pool._timeout == 30  # pool_timeout
    if hasattr(engine.pool, "_recycle"):
        assert engine.pool._recycle == 1800  # pool_recycle
    assert engine.pool._pre_ping is True  # pool_pre_ping

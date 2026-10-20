from fastapi import APIRouter

from caisse.api.v1 import (
    auth,
    catalog,
    customers,
    fne,
    orders,
    payments,
    print_agent,
    printing,
    reports,
    sessions,
    settings,
    stock,
    tables,
    users,
)

api_router = APIRouter(prefix="/api/v1")
for module in (
    auth,
    users,
    catalog,
    tables,
    sessions,
    orders,
    payments,
    stock,
    reports,
    settings,
    customers,
    fne,
    printing,
    print_agent,
):
    api_router.include_router(module.router)

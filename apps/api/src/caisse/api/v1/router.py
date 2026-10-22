from fastapi import APIRouter

from caisse.api.v1.auth import router as auth_router
from caisse.api.v1.users import router as users_router
from caisse.api.v1.catalog import router as catalog_router
from caisse.api.v1.tables import router as tables_router
from caisse.api.v1.orders import router as orders_router
from caisse.api.v1.payments import router as payments_router
from caisse.api.v1.sessions import router as sessions_router
from caisse.api.v1.stock import router as stock_router
from caisse.api.v1.reports import router as reports_router
from caisse.api.v1.customers import router as customers_router
from caisse.api.v1.fne import router as fne_router
from caisse.api.v1.printing import router as printing_router
from caisse.api.v1.settings import router as settings_router
from caisse.api.v1.ws import router as ws_router
from caisse.api.v1.finance import router as finance_router
from caisse.api.v1.production import router as production_router

api_v1_router = APIRouter(prefix="/api/v1")

api_v1_router.include_router(auth_router)
api_v1_router.include_router(users_router)
api_v1_router.include_router(catalog_router)
api_v1_router.include_router(tables_router)
api_v1_router.include_router(orders_router)
api_v1_router.include_router(payments_router)
api_v1_router.include_router(sessions_router)
api_v1_router.include_router(stock_router)
api_v1_router.include_router(reports_router)
api_v1_router.include_router(finance_router)
api_v1_router.include_router(production_router)
api_v1_router.include_router(customers_router)
api_v1_router.include_router(fne_router)
api_v1_router.include_router(printing_router)
api_v1_router.include_router(settings_router)
api_v1_router.include_router(ws_router)


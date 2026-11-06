from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from caisse.core.database import get_db
from caisse.core.deps import require_role
from caisse.models.user import User
from caisse.schemas.salle import MyServiceResponse
from caisse.services.salle_service import SalleService

router = APIRouter(prefix="/salle", tags=["Salle (serveurs)"])


@router.get(
    "/my-service",
    response_model=MyServiceResponse,
    summary="Mon service : argent remis, notes en cours et fil du serveur connecté",
    description=(
        "Sur la session de caisse ouverte : argent remis à la caisse (paiements dont le serveur "
        "est « remis par »), notes réglées, notes en cours (avec celles sans table) et le fil des "
        "envois, demandes d'addition et règlements, du plus récent au plus ancien."
    ),
)
async def my_service(
    current_user: User = Depends(require_role("SERVEUR")),
    db: Session = Depends(get_db),
) -> MyServiceResponse:
    return SalleService(db).my_service(current_user)

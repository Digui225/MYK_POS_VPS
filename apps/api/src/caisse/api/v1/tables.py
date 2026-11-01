from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from caisse.core.database import get_db
from caisse.core.deps import get_current_user, require_role
from caisse.models.user import User
from caisse.schemas.tables import (
    CreateTableRequest,
    TableBoardResponse,
    TableResponse,
    UpdateTableRequest,
)
from caisse.services.table_service import TableService

router = APIRouter(prefix="/tables", tags=["Tables & Salle"])


@router.get("", response_model=list[TableResponse], summary="Lister les tables configurées")
async def list_tables(
    include_inactive: bool = Query(False, description="Inclure les tables désactivées"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[TableResponse]:
    service = TableService(db)
    return service.list_tables(include_inactive=include_inactive)


@router.post(
    "",
    response_model=TableResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Créer une table (Admin/Responsable)",
)
async def create_table(
    payload: CreateTableRequest,
    _user: User = Depends(require_role("ADMIN", "RESPONSABLE")),
    db: Session = Depends(get_db),
) -> TableResponse:
    service = TableService(db)
    table = service.create_table(payload)
    return TableResponse.model_validate(table)


@router.patch("/{table_id}", response_model=TableResponse, summary="Modifier une table (Admin/Responsable)")
async def update_table(
    table_id: str,
    payload: UpdateTableRequest,
    _user: User = Depends(require_role("ADMIN", "RESPONSABLE")),
    db: Session = Depends(get_db),
) -> TableResponse:
    service = TableService(db)
    table = service.update_table(table_id, payload)
    return TableResponse.model_validate(table)


@router.delete("/{table_id}", summary="Désactiver ou supprimer une table (Admin/Responsable)")
async def delete_table(
    table_id: str,
    _user: User = Depends(require_role("ADMIN", "RESPONSABLE")),
    db: Session = Depends(get_db),
) -> dict[str, str]:
    service = TableService(db)
    service.delete_table(table_id)
    return {"message": "Table désactivée avec succès"}


@router.get("/board", response_model=TableBoardResponse, summary="Vue agrégée temps réel de la salle")
async def get_table_board(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TableBoardResponse:
    service = TableService(db)
    return service.get_table_board()

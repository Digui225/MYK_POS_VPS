from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.errors import CaisseException
from caisse.models.order import Order
from caisse.models.table import RestaurantTable
from caisse.repositories.tables import TableRepository
from caisse.schemas.tables import (
    CreateTableRequest,
    TableBoardItem,
    TableBoardResponse,
    TableResponse,
    UpdateTableRequest,
)


class TableService:
    def __init__(self, db: Session):
        self.db = db
        self.repo = TableRepository(db)

    def list_tables(self, include_inactive: bool = False) -> list[TableResponse]:
        if include_inactive:
            tables = (
                self.db.query(RestaurantTable)
                .order_by(RestaurantTable.sort_order.asc(), RestaurantTable.label.asc())
                .all()
            )
        else:
            tables = self.repo.list_active_tables()

        return [
            TableResponse(
                id=t.id,
                label=t.label,
                zone=t.zone,
                seats=t.seats,
                sort_order=t.sort_order,
                is_active=t.is_active,
            )
            for t in tables
        ]

    def get_table_board(self) -> TableBoardResponse:
        board_data = self.repo.get_table_board_data()
        table_items = [TableBoardItem(**item) for item in board_data]
        open_orders_count = sum(1 for item in table_items if item.is_occupied)
        total_in_progress = sum(item.current_total_ttc_xof for item in table_items)

        return TableBoardResponse(
            tables=table_items,
            open_orders_count=open_orders_count,
            total_in_progress_xof=total_in_progress,
        )

    def create_table(self, payload: CreateTableRequest) -> RestaurantTable:
        existing = self.repo.get_by_label(payload.label.strip())
        if existing:
            raise CaisseException(
                code="TABLE_ALREADY_EXISTS",
                title="Table déjà existante",
                detail=f"Une table avec le nom '{payload.label.strip()}' existe déjà.",
                status_code=status.HTTP_409_CONFLICT,
            )

        table = RestaurantTable(
            label=payload.label.strip(),
            zone=payload.zone.strip() or "Salle",
            seats=payload.seats,
            sort_order=payload.sort_order,
            is_active=True,
        )
        self.repo.add(table)
        self.db.commit()
        self.db.refresh(table)
        return table

    def update_table(self, table_id: str, payload: UpdateTableRequest) -> RestaurantTable:
        table = self.repo.get_by_id(table_id)
        if not table:
            raise CaisseException(
                code="TABLE_NOT_FOUND",
                title="Table introuvable",
                detail=f"Aucune table avec l'identifiant '{table_id}' n'a été trouvée.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        if payload.label is not None and payload.label.strip() != table.label:
            existing = self.repo.get_by_label(payload.label.strip())
            if existing and existing.id != table.id:
                raise CaisseException(
                    code="TABLE_ALREADY_EXISTS",
                    title="Nom de table déjà utilisé",
                    detail=f"Une table avec le nom '{payload.label.strip()}' existe déjà.",
                    status_code=status.HTTP_409_CONFLICT,
                )
            table.label = payload.label.strip()

        if payload.zone is not None:
            table.zone = payload.zone.strip() or "Salle"

        if payload.seats is not None:
            table.seats = payload.seats

        if payload.sort_order is not None:
            table.sort_order = payload.sort_order

        if payload.is_active is not None and payload.is_active != table.is_active:
            if not payload.is_active:
                # Vérifier si une commande est en cours
                active_order = (
                    self.db.query(Order)
                    .filter(Order.table_id == table.id, Order.status.in_(["OPEN", "PARTIALLY_PAID"]))
                    .first()
                )
                if active_order:
                    raise CaisseException(
                        code="TABLE_HAS_ACTIVE_ORDER",
                        title="Table occupée",
                        detail=f"Impossible de désactiver la table '{table.label}' car une commande est en cours.",
                        status_code=status.HTTP_409_CONFLICT,
                    )
            table.is_active = payload.is_active

        self.db.commit()
        self.db.refresh(table)
        return table

    def delete_table(self, table_id: str) -> None:
        table = self.repo.get_by_id(table_id)
        if not table:
            raise CaisseException(
                code="TABLE_NOT_FOUND",
                title="Table introuvable",
                detail=f"Aucune table avec l'identifiant '{table_id}' n'a été trouvée.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        active_order = (
            self.db.query(Order)
            .filter(Order.table_id == table.id, Order.status.in_(["OPEN", "PARTIALLY_PAID"]))
            .first()
        )
        if active_order:
            raise CaisseException(
                code="TABLE_HAS_ACTIVE_ORDER",
                title="Table occupée",
                detail=f"Impossible de supprimer la table '{table.label}' car une commande est en cours.",
                status_code=status.HTTP_409_CONFLICT,
            )

        # Désactivation logique pour préserver l'historique des commandes passées
        table.is_active = False
        self.db.commit()

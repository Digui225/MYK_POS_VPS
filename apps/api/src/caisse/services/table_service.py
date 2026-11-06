from fastapi import status
from sqlalchemy.orm import Session

from caisse.core.errors import CaisseException
from caisse.domain.floor_plan_rules import Placement, find_overlaps, fits_grid
from caisse.infrastructure.websocket.manager import ws_manager
from caisse.models.order import Order
from caisse.models.table import RestaurantTable
from caisse.repositories.tables import TableRepository
from caisse.schemas.tables import (
    CreateTableRequest,
    TableBoardItem,
    TableBoardResponse,
    TablePlanUpdateRequest,
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

        return [TableResponse.model_validate(t) for t in tables]

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
            new_zone = payload.zone.strip() or "Salle"
            if new_zone != table.zone:
                # Changer de zone retire la table du plan : sa place n'a pas de sens dans l'autre zone
                table.plan_x = None
                table.plan_y = None
            table.zone = new_zone

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

    def save_plan(self, payload: TablePlanUpdateRequest) -> list[TableResponse]:
        """Enregistre en une fois la place de plusieurs tables sur le plan de salle.

        Les tables absentes de la requête gardent leur place. Le plan obtenu est refusé
        s'il fait sortir une table de la grille ou si deux tables actives d'une même zone
        se chevauchent : rien n'est alors enregistré.
        """
        ids = [p.table_id for p in payload.placements]
        if len(set(ids)) != len(ids):
            raise CaisseException(
                code="TABLE_PLAN_DUPLICATE",
                title="Table en double",
                detail="Une même table apparaît plusieurs fois dans le plan envoyé.",
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            )
        tables = {t.id: t for t in self.repo.get_many(ids)}
        missing = [table_id for table_id in ids if table_id not in tables]
        if missing:
            raise CaisseException(
                code="TABLE_NOT_FOUND",
                title="Table introuvable",
                detail=f"Aucune table avec l'identifiant '{missing[0]}' n'a été trouvée.",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        for placement in payload.placements:
            if (
                placement.plan_x is not None
                and placement.plan_y is not None
                and not fits_grid(placement.plan_x, placement.plan_y, placement.plan_w, placement.plan_h)
            ):
                raise CaisseException(
                    code="TABLE_PLAN_OUT_OF_BOUNDS",
                    title="Table hors du plan",
                    detail=f"La table '{tables[placement.table_id].label}' dépasse du plan de salle.",
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                )

        for placement in payload.placements:
            table = tables[placement.table_id]
            placed = placement.plan_x is not None and placement.plan_y is not None
            table.zone = placement.zone.strip() or "Salle"
            table.plan_x = placement.plan_x if placed else None
            table.plan_y = placement.plan_y if placed else None
            table.plan_w = placement.plan_w
            table.plan_h = placement.plan_h
            table.shape = placement.shape
        self.db.flush()

        overlaps = find_overlaps(
            Placement(t.id, t.label, t.zone, t.plan_x, t.plan_y, t.plan_w, t.plan_h)
            for t in self.repo.list_active_tables()
            if t.plan_x is not None and t.plan_y is not None
        )
        if overlaps:
            self.db.rollback()
            a, b = overlaps[0]
            raise CaisseException(
                code="TABLE_PLAN_OVERLAP",
                title="Tables superposées",
                detail=f"Les tables '{a.label}' et '{b.label}' se chevauchent ({a.zone}).",
                status_code=status.HTTP_409_CONFLICT,
                meta={"tables": [[x.table_id, y.table_id] for x, y in overlaps]},
            )

        self.db.commit()
        ws_manager.broadcast_sync("TABLE_PLAN_UPDATED", {"tables_count": len(ids)})
        return self.list_tables(include_inactive=True)

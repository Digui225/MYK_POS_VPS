from typing import Any

from sqlalchemy.orm import Session, joinedload

from caisse.models.order import Order
from caisse.models.table import RestaurantTable
from caisse.repositories.base import BaseRepository


class TableRepository(BaseRepository[RestaurantTable]):
    def __init__(self, db: Session):
        super().__init__(db, RestaurantTable)

    def list_active_tables(self) -> list[RestaurantTable]:
        return (
            self.db.query(RestaurantTable)
            .filter(RestaurantTable.is_active.is_(True))
            .order_by(RestaurantTable.sort_order.asc(), RestaurantTable.label.asc())
            .all()
        )

    def get_by_label(self, label: str) -> RestaurantTable | None:
        return self.db.query(RestaurantTable).filter(RestaurantTable.label == label).first()

    def get_table_board_data(self) -> list[dict[str, Any]]:
        tables = self.list_active_tables()
        table_ids = [t.id for t in tables]

        # Récupération en une seule requête de toutes les commandes actives
        active_orders = (
            self.db.query(Order)
            .options(joinedload(Order.opened_by), joinedload(Order.items))
            .filter(
                Order.table_id.in_(table_ids),
                Order.status.in_(["OPEN", "PARTIALLY_PAID"]),
            )
            .order_by(Order.opened_at.asc())
            .all()
        )
        orders_by_table_id: dict[str, list[Order]] = {}
        for o in active_orders:
            orders_by_table_id.setdefault(str(o.table_id), []).append(o)

        board_items = []
        for t in tables:
            t_orders = orders_by_table_id.get(str(t.id), [])
            if t_orders:
                active_orders_list = []
                total_table_ttc = 0
                all_items_summary = []
                total_items_count = 0

                for idx, o in enumerate(t_orders):
                    active_items = [it for it in o.items if not it.removed_at]
                    it_count = sum(it.quantity for it in active_items)
                    total_items_count += it_count
                    total_table_ttc += o.total_ttc_xof
                    last_cat = active_items[-1].category_snapshot if active_items else None
                    step = f"{last_cat} / En cours" if last_cat else "En cours"
                    note_lbl = o.note_label or f"Note {idx + 1}"

                    it_summary = [
                        {
                            "name": it.product_name_snapshot,
                            "quantity": it.quantity,
                            "line_total_xof": it.line_total_xof,
                            "unit_price_xof": it.unit_price_xof,
                            "note": it.note,
                        }
                        for it in active_items
                    ]
                    all_items_summary.extend(it_summary)

                    active_orders_list.append(
                        {
                            "order_id": o.id,
                            "order_number": o.order_number,
                            "note_label": note_lbl,
                            "total_ttc_xof": o.total_ttc_xof,
                            "guests_count": o.guests_count,
                            "opened_at": o.opened_at.isoformat() if o.opened_at else None,
                            "server_name": o.opened_by.full_name if o.opened_by else "Serveur",
                            "items_count": it_count,
                            "service_step": step,
                            "items_summary": it_summary,
                        }
                    )

                first_order = t_orders[0]
                board_items.append(
                    {
                        "id": t.id,
                        "label": t.label,
                        "zone": t.zone,
                        "seats": t.seats,
                        "is_occupied": True,
                        "current_order_id": first_order.id,
                        "current_order_number": first_order.order_number,
                        "current_total_ttc_xof": total_table_ttc,
                        "guests_count": sum(o.guests_count for o in t_orders),
                        "opened_at": first_order.opened_at.isoformat() if first_order.opened_at else None,
                        "server_name": first_order.opened_by.full_name if first_order.opened_by else "Serveur",
                        "items_count": total_items_count,
                        "service_step": active_orders_list[-1]["service_step"],
                        "items_summary": all_items_summary,
                        "active_orders_count": len(t_orders),
                        "active_orders": active_orders_list,
                    }
                )
            else:
                board_items.append(
                    {
                        "id": t.id,
                        "label": t.label,
                        "zone": t.zone,
                        "seats": t.seats,
                        "is_occupied": False,
                        "current_order_id": None,
                        "current_order_number": None,
                        "current_total_ttc_xof": 0,
                        "guests_count": None,
                        "opened_at": None,
                        "server_name": None,
                        "items_count": None,
                        "service_step": None,
                        "items_summary": [],
                        "active_orders_count": 0,
                        "active_orders": [],
                    }
                )
        return board_items

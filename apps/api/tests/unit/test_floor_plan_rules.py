from caisse.domain.floor_plan_rules import GRID_COLUMNS, Placement, find_overlaps, fits_grid


def _p(table_id: str, x: int, y: int, w: int = 2, h: int = 2, zone: str = "Salle") -> Placement:
    return Placement(table_id, table_id.upper(), zone, x, y, w, h)


def test_a_table_must_stay_inside_the_twelve_columns() -> None:
    assert fits_grid(0, 0, 2, 2)
    assert fits_grid(GRID_COLUMNS - 4, 10, 4, 2)  # rectangle collé au bord droit
    assert not fits_grid(GRID_COLUMNS - 1, 0, 2, 2)  # déborde à droite
    assert not fits_grid(-1, 0, 2, 2)
    assert not fits_grid(0, 0, 7, 2)  # plus grande que la taille maximale
    assert not fits_grid(0, 0, 0, 2)


def test_touching_tables_do_not_overlap() -> None:
    assert find_overlaps([_p("t1", 0, 0), _p("t2", 2, 0), _p("t3", 0, 2)]) == []


def test_overlap_is_detected_within_a_zone_only() -> None:
    overlaps = find_overlaps([_p("t1", 0, 0, 4, 2), _p("t2", 3, 1), _p("t3", 0, 0, zone="Terrasse")])
    assert [(a.table_id, b.table_id) for a, b in overlaps] == [("t1", "t2")]

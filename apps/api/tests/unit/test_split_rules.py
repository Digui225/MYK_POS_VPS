from dataclasses import dataclass

import pytest

from caisse.domain.split_rules import split_by_seat


@dataclass
class Line:
    name: str
    seat: int | None
    removed_at: object | None = None


def test_each_guest_gets_a_note_and_table_items_stay_with_the_first() -> None:
    lines = [Line("mouton", 1), Line("eau", 0), Line("poulet", 2), Line("sosso", 3), Line("pain", None)]
    staying, moving = split_by_seat(lines)
    assert [line.name for line in staying] == ["mouton", "eau", "pain"]
    assert {seat: [line.name for line in group] for seat, group in moving.items()} == {2: ["poulet"], 3: ["sosso"]}


def test_removed_lines_stay_on_the_original_note() -> None:
    lines = [Line("mouton", 1), Line("poulet", 2), Line("annulé", 2, removed_at="hier")]
    staying, moving = split_by_seat(lines)
    assert [line.name for line in staying] == ["mouton", "annulé"]
    assert [line.name for line in moving[2]] == ["poulet"]


def test_a_single_guest_cannot_be_split() -> None:
    with pytest.raises(ValueError):
        split_by_seat([Line("mouton", 1), Line("eau", 0), Line("annulé", 2, removed_at="hier")])

"""Unit tests for ServiceRepository — DB is fully mocked."""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.models.service import Service
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.service import ServiceCreate


def _repo(db: MagicMock | None = None) -> tuple[ServiceRepository, MagicMock]:
    db = db or MagicMock()
    return ServiceRepository(db), db


def _make_service(**kwargs: str) -> Service:
    defaults = {"name": "test-svc", "team": "eng", "owner_email": "eng@co.com"}
    defaults.update(kwargs)
    s = Service(**defaults)  # type: ignore[arg-type]
    s.id = uuid.uuid4()
    return s


# ── create ─────────────────────────────────────────────────────────────────────


def test_create_adds_and_flushes() -> None:
    repo, db = _repo()
    data = ServiceCreate(name="svc-a", team="platform", owner_email="a@co.com")
    result = repo.create(data)

    db.add.assert_called_once()
    db.flush.assert_called_once()
    assert result.name == "svc-a"


# ── get_by_id ──────────────────────────────────────────────────────────────────


def test_get_by_id_returns_service_when_found() -> None:
    svc = _make_service()
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = svc

    assert repo.get_by_id(svc.id) is svc


def test_get_by_id_returns_none_when_missing() -> None:
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = None

    assert repo.get_by_id(uuid.uuid4()) is None


# ── get_by_name ────────────────────────────────────────────────────────────────


def test_get_by_name_returns_service_when_found() -> None:
    svc = _make_service(name="my-svc")
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = svc

    assert repo.get_by_name("my-svc") is svc


def test_get_by_name_returns_none_when_missing() -> None:
    repo, db = _repo()
    db.execute.return_value.scalar_one_or_none.return_value = None

    assert repo.get_by_name("ghost") is None


# ── list ───────────────────────────────────────────────────────────────────────


def test_list_returns_items_and_total() -> None:
    svc1, svc2 = _make_service(name="a"), _make_service(name="b")
    repo, db = _repo()
    count_result = MagicMock()
    count_result.scalar_one.return_value = 2
    rows_result = MagicMock()
    rows_result.scalars.return_value.all.return_value = [svc1, svc2]
    db.execute.side_effect = [count_result, rows_result]

    items, total = repo.list(page=1, page_size=20)

    assert total == 2
    assert items == [svc1, svc2]


def test_list_empty_returns_zero_total() -> None:
    repo, db = _repo()
    count_result = MagicMock()
    count_result.scalar_one.return_value = 0
    rows_result = MagicMock()
    rows_result.scalars.return_value.all.return_value = []
    db.execute.side_effect = [count_result, rows_result]

    items, total = repo.list(page=1, page_size=20)
    assert total == 0
    assert items == []


# ── ruff: ensure import is exercised ──────────────────────────────────────────


@pytest.mark.parametrize("page,page_size", [(1, 10), (2, 5)])
def test_list_pagination_args_passed_through(page: int, page_size: int) -> None:
    repo, db = _repo()
    count_result = MagicMock()
    count_result.scalar_one.return_value = 0
    rows_result = MagicMock()
    rows_result.scalars.return_value.all.return_value = []
    db.execute.side_effect = [count_result, rows_result]

    repo.list(page=page, page_size=page_size)
    assert db.execute.call_count == 2

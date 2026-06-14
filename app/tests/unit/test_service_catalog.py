"""Unit tests for service_catalog service layer — DB is fully mocked."""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.core.exceptions import ConflictError, NotFoundError
from app.src.models.service import Service
from app.src.schemas.service import ServiceCreate
from app.src.services.service_catalog import create_service, get_service, list_services


def _make_service(**kwargs: str) -> Service:
    defaults = {"name": "test-svc", "team": "eng", "owner_email": "eng@co.com"}
    defaults.update(kwargs)
    s = Service(**defaults)  # type: ignore[arg-type]
    s.id = uuid.uuid4()
    return s


# ── create_service ─────────────────────────────────────────────────────────────


def test_create_service_adds_and_flushes() -> None:
    db = MagicMock()
    db.execute.return_value.scalar_one_or_none.return_value = None  # no conflict

    body = ServiceCreate(name="svc-a", team="platform", owner_email="a@co.com")
    result = create_service(db, body)

    db.add.assert_called_once()
    db.flush.assert_called_once()
    assert result.name == "svc-a"


def test_create_service_raises_conflict_when_name_exists() -> None:
    db = MagicMock()
    db.execute.return_value.scalar_one_or_none.return_value = _make_service(name="dup")

    body = ServiceCreate(name="dup", team="eng", owner_email="x@x.com")
    with pytest.raises(ConflictError) as exc_info:
        create_service(db, body)

    assert exc_info.value.field == "name"
    assert exc_info.value.status_code == 409
    db.add.assert_not_called()


# ── get_service ────────────────────────────────────────────────────────────────


def test_get_service_returns_service() -> None:
    svc = _make_service()
    db = MagicMock()
    db.execute.return_value.scalar_one_or_none.return_value = svc

    result = get_service(db, svc.id)
    assert result is svc


def test_get_service_raises_not_found() -> None:
    db = MagicMock()
    db.execute.return_value.scalar_one_or_none.return_value = None

    with pytest.raises(NotFoundError) as exc_info:
        get_service(db, uuid.uuid4())

    assert exc_info.value.status_code == 404
    assert exc_info.value.field == "service_id"


# ── list_services ──────────────────────────────────────────────────────────────


def test_list_services_returns_items_and_total() -> None:
    svc1, svc2 = _make_service(name="a"), _make_service(name="b")
    db = MagicMock()
    # Two execute calls: first returns total count, second returns rows.
    count_result = MagicMock()
    count_result.scalar_one.return_value = 2
    rows_result = MagicMock()
    rows_result.scalars.return_value.all.return_value = [svc1, svc2]
    db.execute.side_effect = [count_result, rows_result]

    items, total = list_services(db, page=1, page_size=20)

    assert total == 2
    assert items == [svc1, svc2]


def test_list_services_empty_returns_zero_total() -> None:
    db = MagicMock()
    count_result = MagicMock()
    count_result.scalar_one.return_value = 0
    rows_result = MagicMock()
    rows_result.scalars.return_value.all.return_value = []
    db.execute.side_effect = [count_result, rows_result]

    items, total = list_services(db, page=1, page_size=20)
    assert total == 0
    assert items == []

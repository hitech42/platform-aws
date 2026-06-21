"""Unit tests for ServiceCatalogService — repos and DB are fully mocked."""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.core.exceptions import ConflictError, NotFoundError
from app.src.models.service import Service
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.service import ServiceCreate
from app.src.services.service_catalog_service import ServiceCatalogService


def _make_service(**kwargs: str) -> Service:
    defaults = {"name": "test-svc", "team": "eng", "owner_email": "eng@co.com"}
    defaults.update(kwargs)
    s = Service(**defaults)  # type: ignore[arg-type]
    s.id = uuid.uuid4()
    return s


def _make_svc(
    repo: MagicMock | None = None, db: MagicMock | None = None
) -> tuple[ServiceCatalogService, MagicMock, MagicMock]:
    repo = repo or MagicMock(spec=ServiceRepository)
    db = db or MagicMock()
    return ServiceCatalogService(db=db, repo=repo), repo, db


# ── create_service ─────────────────────────────────────────────────────────────


def test_create_service_commits_and_refreshes() -> None:
    service = _make_service(name="svc-a")
    repo = MagicMock(spec=ServiceRepository)
    repo.get_by_name.return_value = None
    repo.create.return_value = service

    svc, _, db = _make_svc(repo=repo)
    body = ServiceCreate(name="svc-a", team="platform", owner_email="a@co.com")
    result = svc.create_service(body)

    db.commit.assert_called_once()
    db.refresh.assert_called_once_with(service)
    assert result is service


def test_create_service_raises_conflict_when_name_exists() -> None:
    repo = MagicMock(spec=ServiceRepository)
    repo.get_by_name.return_value = _make_service(name="dup")

    svc, _, db = _make_svc(repo=repo)
    with pytest.raises(ConflictError) as exc_info:
        svc.create_service(ServiceCreate(name="dup", team="eng", owner_email="x@x.com"))

    assert exc_info.value.field == "name"
    repo.create.assert_not_called()
    db.commit.assert_not_called()


# ── get_service ────────────────────────────────────────────────────────────────


def test_get_service_returns_service() -> None:
    service = _make_service()
    repo = MagicMock(spec=ServiceRepository)
    repo.get_by_id.return_value = service

    svc, _, _ = _make_svc(repo=repo)
    assert svc.get_service(service.id) is service


def test_get_service_raises_not_found() -> None:
    repo = MagicMock(spec=ServiceRepository)
    repo.get_by_id.return_value = None

    svc, _, _ = _make_svc(repo=repo)
    with pytest.raises(NotFoundError) as exc_info:
        svc.get_service(uuid.uuid4())

    assert exc_info.value.field == "service_id"
    assert exc_info.value.status_code == 404


# ── list_services ──────────────────────────────────────────────────────────────


def test_list_services_delegates_to_repo() -> None:
    expected = ([_make_service(name="a"), _make_service(name="b")], 2)
    repo = MagicMock(spec=ServiceRepository)
    repo.list.return_value = expected

    svc, _, _ = _make_svc(repo=repo)
    result = svc.list_services(page=1, page_size=20)

    repo.list.assert_called_once_with(1, 20)
    assert result == expected

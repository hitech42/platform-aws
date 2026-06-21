"""Dependency provider functions for the service layer.

All get_*_repository and get_*_service functions live here so that
dependency wiring is a service-layer concern — not a routing concern.

FastAPI deduplicates identical Depends() calls within a single request,
so all repositories that depend on get_db will share the same Session
(and therefore the same transaction) for the lifetime of the request.
"""

from fastapi import Depends
from sqlalchemy.orm import Session

from app.src.db.session import get_db
from app.src.repositories.config_repository import ConfigRepository
from app.src.repositories.request_event_repository import RequestEventRepository
from app.src.repositories.secret_request_repository import SecretRequestRepository
from app.src.repositories.service_repository import ServiceRepository
from app.src.services.narrative_service import NarrativeService
from app.src.services.secret_request_lifecycle_service import SecretRequestLifecycleService
from app.src.services.service_catalog_service import ServiceCatalogService

# ── Repository providers ──────────────────────────────────────────────────────


def get_service_repository(db: Session = Depends(get_db)) -> ServiceRepository:
    return ServiceRepository(db)


def get_secret_request_repository(
    db: Session = Depends(get_db),
) -> SecretRequestRepository:
    return SecretRequestRepository(db)


def get_request_event_repository(
    db: Session = Depends(get_db),
) -> RequestEventRepository:
    return RequestEventRepository(db)


def get_config_repository(db: Session = Depends(get_db)) -> ConfigRepository:
    return ConfigRepository(db)


# ── Service providers ─────────────────────────────────────────────────────────


def get_service_catalog_service(
    db: Session = Depends(get_db),
    repo: ServiceRepository = Depends(get_service_repository),
) -> ServiceCatalogService:
    return ServiceCatalogService(db=db, repo=repo)


def get_secret_request_lifecycle_service(
    db: Session = Depends(get_db),
    secret_request_repo: SecretRequestRepository = Depends(get_secret_request_repository),
    request_event_repo: RequestEventRepository = Depends(get_request_event_repository),
    service_repo: ServiceRepository = Depends(get_service_repository),
) -> SecretRequestLifecycleService:
    return SecretRequestLifecycleService(
        db=db,
        secret_request_repo=secret_request_repo,
        request_event_repo=request_event_repo,
        service_repo=service_repo,
    )


def get_narrative_service(
    secret_request_repo: SecretRequestRepository = Depends(get_secret_request_repository),
    request_event_repo: RequestEventRepository = Depends(get_request_event_repository),
    service_repo: ServiceRepository = Depends(get_service_repository),
    config_repo: ConfigRepository = Depends(get_config_repository),
) -> NarrativeService:
    return NarrativeService(
        secret_request_repo=secret_request_repo,
        request_event_repo=request_event_repo,
        service_repo=service_repo,
        config_repo=config_repo,
    )

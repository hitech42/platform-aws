"""Service-catalog business logic.

Keeps route handlers thin: all DB interaction and domain-rule enforcement lives here.
Functions flush but never commit — the route handler commits so it can control the
transaction boundary cleanly (commit → refresh → return).
"""

import uuid

import structlog
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.src.core.exceptions import ConflictError, NotFoundError
from app.src.models.service import Service
from app.src.schemas.service import ServiceCreate

log = structlog.get_logger(__name__)


def create_service(db: Session, body: ServiceCreate) -> Service:
    existing = db.execute(
        select(Service).where(Service.name == body.name)
    ).scalar_one_or_none()
    if existing is not None:
        raise ConflictError(
            f"A service named '{body.name}' already exists.", field="name"
        )

    service = Service(**body.model_dump())
    db.add(service)
    db.flush()
    log.info("service.created", name=service.name, id=str(service.id))
    return service


def get_service(db: Session, service_id: uuid.UUID) -> Service:
    service = db.execute(
        select(Service).where(Service.id == service_id)
    ).scalar_one_or_none()
    if service is None:
        raise NotFoundError(f"Service '{service_id}' not found.", field="service_id")
    return service


def list_services(
    db: Session, page: int, page_size: int
) -> tuple[list[Service], int]:
    total: int = db.execute(
        select(func.count()).select_from(Service)
    ).scalar_one()
    rows = db.execute(
        select(Service)
        .order_by(Service.created_at.asc(), Service.id.asc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()
    return list(rows), total

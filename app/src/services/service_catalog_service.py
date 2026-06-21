import uuid

import structlog
from sqlalchemy.orm import Session

from app.src.core.exceptions import ConflictError, NotFoundError
from app.src.models.service import Service
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.service import ServiceCreate

log = structlog.get_logger(__name__)


class ServiceCatalogService:
    def __init__(self, db: Session, repo: ServiceRepository) -> None:
        self._db = db
        self._repo = repo

    def create_service(self, data: ServiceCreate) -> Service:
        if self._repo.get_by_name(data.name) is not None:
            raise ConflictError(f"A service named '{data.name}' already exists.", field="name")
        service = self._repo.create(data)
        self._db.commit()
        self._db.refresh(service)
        log.info("service.created", name=service.name, id=str(service.id))
        return service

    def get_service(self, id: uuid.UUID) -> Service:
        service = self._repo.get_by_id(id)
        if service is None:
            raise NotFoundError(f"Service '{id}' not found.", field="service_id")
        return service

    def list_services(self, page: int, page_size: int) -> tuple[list[Service], int]:
        return self._repo.list(page, page_size)

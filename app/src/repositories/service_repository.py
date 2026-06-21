import uuid

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.src.models.service import Service
from app.src.schemas.service import ServiceCreate


class ServiceRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def create(self, data: ServiceCreate) -> Service:
        service = Service(**data.model_dump())
        self._db.add(service)
        self._db.flush()
        return service

    def get_by_id(self, id: uuid.UUID) -> Service | None:
        return self._db.execute(select(Service).where(Service.id == id)).scalar_one_or_none()

    def get_by_name(self, name: str) -> Service | None:
        return self._db.execute(select(Service).where(Service.name == name)).scalar_one_or_none()

    def list(self, page: int, page_size: int) -> tuple[list[Service], int]:
        total: int = self._db.execute(select(func.count()).select_from(Service)).scalar_one()
        rows = (
            self._db.execute(
                select(Service)
                .order_by(Service.created_at.asc(), Service.id.asc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total

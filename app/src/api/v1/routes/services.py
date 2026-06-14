import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.src.db.session import get_db
from app.src.schemas.common import Page
from app.src.schemas.service import ServiceCreate, ServiceRead
from app.src.services import service_catalog

router = APIRouter(prefix="/services", tags=["services"])


@router.post("", status_code=201, response_model=ServiceRead)
def create_service(
    body: ServiceCreate, db: Session = Depends(get_db)
) -> ServiceRead:
    service = service_catalog.create_service(db, body)
    db.commit()
    db.refresh(service)
    return ServiceRead.model_validate(service)


@router.get("", response_model=Page[ServiceRead])
def list_services(
    page: int = Query(1, ge=1, description="Page number (1-based)"),
    page_size: int = Query(20, ge=1, le=100, description="Items per page"),
    db: Session = Depends(get_db),
) -> Page[ServiceRead]:
    items, total = service_catalog.list_services(db, page, page_size)
    return Page(
        items=[ServiceRead.model_validate(s) for s in items],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get("/{service_id}", response_model=ServiceRead)
def get_service(
    service_id: uuid.UUID, db: Session = Depends(get_db)
) -> ServiceRead:
    service = service_catalog.get_service(db, service_id)
    return ServiceRead.model_validate(service)

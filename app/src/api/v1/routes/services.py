import uuid

from fastapi import APIRouter, Depends, Query

from app.src.schemas.common import Page
from app.src.schemas.service import ServiceCreate, ServiceRead
from app.src.services.dependencies import get_service_catalog_service
from app.src.services.service_catalog_service import ServiceCatalogService

router = APIRouter(prefix="/services", tags=["services"])


@router.post("", status_code=201, response_model=ServiceRead)
def create_service(
    body: ServiceCreate,
    svc: ServiceCatalogService = Depends(get_service_catalog_service),
) -> ServiceRead:
    service = svc.create_service(body)
    return ServiceRead.model_validate(service)


@router.get("", response_model=Page[ServiceRead])
def list_services(
    page: int = Query(1, ge=1, description="Page number (1-based)"),
    page_size: int = Query(20, ge=1, le=100, description="Items per page"),
    svc: ServiceCatalogService = Depends(get_service_catalog_service),
) -> Page[ServiceRead]:
    items, total = svc.list_services(page, page_size)
    return Page(
        items=[ServiceRead.model_validate(s) for s in items],
        page=page,
        page_size=page_size,
        total=total,
    )


@router.get("/{service_id}", response_model=ServiceRead)
def get_service(
    service_id: uuid.UUID,
    svc: ServiceCatalogService = Depends(get_service_catalog_service),
) -> ServiceRead:
    service = svc.get_service(service_id)
    return ServiceRead.model_validate(service)

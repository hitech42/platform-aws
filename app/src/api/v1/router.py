from fastapi import APIRouter

from app.src.api.v1.routes.services import router as services_router

v1_router = APIRouter()
v1_router.include_router(services_router)

# Future routers added here:
# from app.src.api.v1.routes.secret_requests import router as secret_requests_router
# v1_router.include_router(secret_requests_router)

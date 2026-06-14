from contextlib import asynccontextmanager
from collections.abc import AsyncGenerator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.src.api.v1.router import v1_router
from app.src.api.v1.routes.health import router as health_router
from app.src.core.config import settings
from app.src.core.logging import configure_logging


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    configure_logging(settings.log_level)
    yield


def create_app() -> FastAPI:
    app = FastAPI(
        title="Developer Self-Service Platform API",
        description="Internal self-service platform for dev teams to manage secrets and platform resources.",
        version="0.1.0",
        lifespan=lifespan,
    )

    # CORS: permissive for local dev — restrict `allow_origins` to specific domains in prod.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Health routes are mounted at root (unversioned) so load balancers can reach /healthz.
    app.include_router(health_router)
    app.include_router(v1_router, prefix="/api/v1")

    return app


app = create_app()

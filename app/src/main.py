from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# Configure logging before importing any module that may log at import time
# (e.g. llm_provider._load_anthropic_api_key). Without this, those early log
# calls use structlog's unconfigured default renderer instead of JSONRenderer,
# producing plain-text output that is invisible to CloudWatch JSON filters.
from app.src.core.config import settings
from app.src.core.logging import configure_logging

configure_logging(settings.log_level)

from app.src.api.v1.router import v1_router  # noqa: E402
from app.src.api.v1.routes.health import router as health_router  # noqa: E402
from app.src.core.exceptions import AppError  # noqa: E402
from app.src.core.middleware import RequestLoggingMiddleware  # noqa: E402

log = structlog.get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    yield


def _error_body(code: str, message: str, field: str | None = None) -> dict:  # type: ignore[type-arg]
    detail: dict = {"code": code, "message": message}  # type: ignore[type-arg]
    if field is not None:
        detail["field"] = field
    return {"error": detail}


def create_app() -> FastAPI:
    app = FastAPI(
        title="Developer Self-Service Platform API",
        description="Internal self-service platform for dev teams to manage secrets and resources.",
        version="0.1.0",
        lifespan=lifespan,
    )

    # ── Exception handlers ─────────────────────────────────────────────────────

    @app.exception_handler(AppError)
    async def app_error_handler(request: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(exc.code, exc.message, exc.field),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # Condense Pydantic's detailed error list into a single message that names
        # the first failing field; keeps the response shape consistent with AppError.
        errors = exc.errors()
        first = errors[0] if errors else {}
        field = ".".join(str(p) for p in first.get("loc", []) if p != "body")
        message = first.get("msg", "Invalid request")
        return JSONResponse(
            status_code=422,
            content=_error_body("VALIDATION_ERROR", message, field or None),
        )

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled_exception", exc_info=exc)
        return JSONResponse(
            status_code=500,
            content=_error_body("INTERNAL_ERROR", "An unexpected error occurred."),
        )

    # ── Middleware ─────────────────────────────────────────────────────────────

    # CORS: permissive for local dev — restrict `allow_origins` to specific domains in prod.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Request logging: added last so it is the outermost middleware — it times the
    # full request including CORS header injection.
    app.add_middleware(RequestLoggingMiddleware)

    # ── Routers ────────────────────────────────────────────────────────────────

    # Health routes are mounted at root (unversioned) so load balancers can reach /healthz.
    app.include_router(health_router)
    app.include_router(v1_router, prefix="/api/v1")

    return app


app = create_app()

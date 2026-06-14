from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.src.db.session import get_db


class HealthResponse(BaseModel):
    status: str


class ReadinessResponse(BaseModel):
    status: str
    db: str


router = APIRouter(tags=["health"])


@router.get("/healthz", response_model=HealthResponse)
async def liveness() -> HealthResponse:
    return HealthResponse(status="ok")


@router.get("/readyz", response_model=ReadinessResponse)
def readiness(response: Response, db: Session = Depends(get_db)) -> ReadinessResponse:
    """DB-backed readiness probe. Returns 503 if Postgres is unreachable.

    Uses a sync def (not async) because the SQLAlchemy session is synchronous —
    FastAPI runs sync routes in a threadpool automatically.
    """
    try:
        db.execute(text("SELECT 1"))
        return ReadinessResponse(status="ok", db="ok")
    except (SQLAlchemyError, Exception):
        response.status_code = 503
        return ReadinessResponse(status="error", db="unreachable")

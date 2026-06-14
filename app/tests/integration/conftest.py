"""Shared fixtures for integration tests.

These tests spin up an ephemeral Postgres container via testcontainers — they do NOT
use the developer's locally-running Postgres instance. This means they are self-contained
and can run in any environment with Docker available (CI, fresh dev machines, etc.).

Run the full integration suite:
    pytest app/tests/integration

Run just unit tests (no Docker required):
    pytest app/tests/unit
"""

from collections.abc import Generator
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker
from testcontainers.postgres import PostgresContainer

# Path to alembic.ini relative to this file:
# conftest.py → integration/ → tests/ → app/ → alembic.ini
ALEMBIC_INI = Path(__file__).parents[2] / "alembic.ini"


@pytest.fixture(scope="module")
def postgres_container() -> PostgresContainer:  # type: ignore[misc]
    """Start a fresh Postgres container once per test module."""
    with PostgresContainer("postgres:16-alpine") as container:
        yield container


@pytest.fixture(scope="module")
def db_engine(postgres_container: PostgresContainer) -> Engine:  # type: ignore[misc]
    """Run Alembic migrations against the container and return a connected engine."""
    url = postgres_container.get_connection_url()

    # Run migrations programmatically. env.py detects that the URL is already set
    # (not the placeholder) and will not override it with settings.database_url.
    cfg = Config(str(ALEMBIC_INI))
    cfg.set_main_option("sqlalchemy.url", url)
    # Set an absolute script_location so Alembic resolves the migrations directory
    # correctly regardless of the working directory pytest was invoked from.
    cfg.set_main_option("script_location", str(ALEMBIC_INI.parent / "src/db/migrations"))
    command.upgrade(cfg, "head")

    engine = create_engine(url, pool_pre_ping=True)
    yield engine
    engine.dispose()


@pytest.fixture
def db_session(db_engine: Engine) -> Session:  # type: ignore[misc]
    """Provide a session that is rolled back after each test (no data leaks)."""
    factory = sessionmaker(bind=db_engine)
    session = factory()
    yield session
    session.rollback()
    session.close()


@pytest.fixture
def committed_db(db_engine: Engine) -> Generator[Session, None, None]:  # type: ignore[misc]
    """Session for direct DB setup that commits immediately (no rollback on teardown).

    Use this when a test needs to insert raw rows that the `client` fixture's
    separate session must be able to see — e.g. a SecretRequest without any
    RequestEvents, which cannot be created via the normal API flow.
    """
    factory = sessionmaker(bind=db_engine)
    session = factory()
    yield session
    session.close()


@pytest.fixture
def client(db_engine: Engine) -> Generator[TestClient, None, None]:  # type: ignore[misc]
    """TestClient with get_db overridden to use the testcontainers Postgres engine."""
    from app.src.db.session import get_db
    from app.src.main import app as fastapi_app

    factory = sessionmaker(bind=db_engine)

    def override_get_db() -> Generator[Session, None, None]:
        db = factory()
        try:
            yield db
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    fastapi_app.dependency_overrides[get_db] = override_get_db
    with TestClient(fastapi_app) as c:
        yield c
    fastapi_app.dependency_overrides.clear()

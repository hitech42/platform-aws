"""Shared fixtures for integration tests.

Two execution modes are supported, selected by the DATABASE_URL environment variable:

* **Local dev** (DATABASE_URL not set): testcontainers spins up an ephemeral
  Postgres 16 container per test module. Requires Docker; does NOT touch any
  locally-running Postgres instance.

* **CI** (DATABASE_URL set): the external Postgres service container provided
  by GitHub Actions is used directly. testcontainers is bypassed entirely, so
  Docker-in-Docker is not required and startup is instantaneous.

Run the full integration suite:
    pytest app/tests/integration                         # local dev (Docker)
    DATABASE_URL=postgresql://... pytest app/tests/integration  # CI / external DB

Run just unit tests (no Docker required):
    pytest app/tests/unit
"""

import os
from collections.abc import Generator
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

# Path to alembic.ini relative to this file:
# conftest.py → integration/ → tests/ → app/ → alembic.ini
ALEMBIC_INI = Path(__file__).parents[2] / "alembic.ini"


def _run_migrations(url: str) -> None:
    cfg = Config(str(ALEMBIC_INI))
    cfg.set_main_option("sqlalchemy.url", url)
    # Absolute path so Alembic resolves the migration directory correctly
    # regardless of the working directory pytest was invoked from.
    cfg.set_main_option("script_location", str(ALEMBIC_INI.parent / "src/db/migrations"))
    command.upgrade(cfg, "head")


# ── db_engine fixture ─────────────────────────────────────────────────────────
#
# When DATABASE_URL is set (CI): use that URL, session-scoped (migrations run
# once per session against the shared service container).
#
# When DATABASE_URL is not set (local dev): spin up a testcontainers Postgres
# container, module-scoped (fresh DB per test module = stronger isolation).


if os.environ.get("DATABASE_URL"):
    # CI path — external Postgres service container is already running.
    _CI_URL: str = os.environ["DATABASE_URL"]

    @pytest.fixture(scope="session")
    def db_engine() -> Generator[Engine, None, None]:  # type: ignore[misc]
        """Use the externally-provided DATABASE_URL (set by GitHub Actions)."""
        _run_migrations(_CI_URL)
        engine = create_engine(_CI_URL, pool_pre_ping=True)
        yield engine
        engine.dispose()

else:
    # Local dev path — testcontainers spins up an ephemeral Postgres.
    from testcontainers.postgres import PostgresContainer

    @pytest.fixture(scope="module")  # type: ignore[no-redef]
    def db_engine() -> Generator[Engine, None, None]:  # type: ignore[misc]
        """Start an ephemeral Postgres container and run Alembic migrations."""
        with PostgresContainer("postgres:16-alpine") as container:
            url = container.get_connection_url()
            _run_migrations(url)
            engine = create_engine(url, pool_pre_ping=True)
            yield engine
            engine.dispose()


# ── per-test session fixtures ─────────────────────────────────────────────────


@pytest.fixture
def db_session(db_engine: Engine) -> Generator[Session, None, None]:  # type: ignore[misc]
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
    """TestClient with get_db overridden to use the test Postgres engine."""
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

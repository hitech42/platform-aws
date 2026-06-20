from collections.abc import Generator
from typing import Any

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import ConnectionPoolEntry, NullPool

from app.src.core.config import settings
from app.src.db.iam_auth import generate_iam_auth_token


def get_connect_args() -> dict[str, Any]:
    # connect_timeout: seconds to wait for TCP connection — prevents health checks
    # from hanging indefinitely when Postgres is unreachable.
    return {"connect_timeout": 5}


def _build_engine() -> Engine:
    url = make_url(settings.database_url)

    if settings.db_auth_mode != "iam":
        return create_engine(
            url,
            connect_args=get_connect_args(),
            pool_pre_ping=True,
        )

    # NullPool: IAM auth tokens expire after 15 minutes, so every physical
    # connection must be opened with a freshly generated token rather than
    # reusing a token issued for an earlier pooled connection.
    engine = create_engine(
        url,
        connect_args=get_connect_args(),
        poolclass=NullPool,
    )

    @event.listens_for(engine, "do_connect")
    def _inject_iam_token(
        dialect: Any, conn_rec: ConnectionPoolEntry, cargs: list[Any], cparams: dict[str, Any]
    ) -> None:
        cparams["password"] = generate_iam_auth_token(url)

    return engine


engine = _build_engine()

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()

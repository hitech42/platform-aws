from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.src.core.config import settings


def get_connect_args() -> dict:  # type: ignore[type-arg]
    if settings.db_auth_mode == "iam":
        # TODO: generate a short-lived RDS IAM auth token here using:
        #   boto3.client("rds").generate_db_auth_token(Host, Port, DBUser, Region)
        # Then pass it as the password via connect_args={"password": token}.
        # The engine must also be created without connection pooling (pool_size=0)
        # because tokens expire after 15 minutes.
        raise NotImplementedError("IAM DB auth is not yet implemented")
    return {}


engine = create_engine(
    settings.database_url,
    connect_args=get_connect_args(),
    pool_pre_ping=True,
    echo=settings.environment == "dev",
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

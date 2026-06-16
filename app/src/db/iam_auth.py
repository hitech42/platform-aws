"""RDS IAM authentication token generation.

Shared by the app's engine (db/session.py) and the Alembic migration env.py —
both need a token generated immediately before opening a physical connection
when DB_AUTH_MODE=iam, since tokens expire after 15 minutes.
"""

from typing import Any

import boto3
from sqlalchemy.engine import URL

from app.src.core.config import settings


def _rds_client() -> Any:
    kwargs: dict[str, Any] = {"region_name": settings.aws_default_region}
    if settings.aws_endpoint_url:
        kwargs["endpoint_url"] = settings.aws_endpoint_url
    if settings.aws_access_key_id:
        kwargs["aws_access_key_id"] = settings.aws_access_key_id
    if settings.aws_secret_access_key:
        kwargs["aws_secret_access_key"] = settings.aws_secret_access_key
    return boto3.client("rds", **kwargs)


def generate_iam_auth_token(url: URL) -> str:
    token: str = _rds_client().generate_db_auth_token(
        DBHostname=url.host,
        Port=url.port or 5432,
        DBUsername=url.username,
        Region=settings.aws_default_region,
    )
    return token

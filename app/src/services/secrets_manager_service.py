"""Thin boto3 wrapper for AWS Secrets Manager.

The same code path is used against LocalStack (local) and real AWS (staging/prod)
by reading endpoint_url from settings — no conditional branching outside _client().

Secret names follow the convention: platform/{service_name}/{environment}/{logical_name}
"""

import secrets
from typing import Any

import boto3
import structlog
from botocore.exceptions import ClientError

from app.src.core.config import settings
from app.src.core.exceptions import ConflictError, ValidationError

log = structlog.get_logger(__name__)


class SecretsManagerService:
    def _client(self) -> Any:
        kwargs: dict[str, Any] = {"region_name": settings.aws_default_region}
        if settings.aws_endpoint_url:
            kwargs["endpoint_url"] = settings.aws_endpoint_url
        if settings.aws_access_key_id:
            kwargs["aws_access_key_id"] = settings.aws_access_key_id
        if settings.aws_secret_access_key:
            kwargs["aws_secret_access_key"] = settings.aws_secret_access_key
        return boto3.client("secretsmanager", **kwargs)

    def create_app_secret(
        self,
        *,
        service_name: str,
        logical_name: str,
        environment: str,
        generate_value: bool,
        description: str | None = None,
    ) -> str:
        """Create a secret in Secrets Manager and return its ARN.

        Raises:
            ValidationError: if generate_value is False (caller-supplied values not supported yet).
            ConflictError: if the secret name already exists in Secrets Manager.
            ClientError: for any other AWS error (propagated as-is).
        """
        if not generate_value:
            raise ValidationError(
                "Caller-supplied secret values are not supported; set generate_value=true.",
                field="generate_value",
            )

        secret_name = f"platform/{service_name}/{environment}/{logical_name}"
        secret_value = secrets.token_urlsafe(32)

        client = self._client()
        try:
            response = client.create_secret(
                Name=secret_name,
                SecretString=secret_value,
                Description=(
                    description
                    or f"Managed by platform API — {service_name}/{environment}/{logical_name}"
                ),
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ResourceExistsException":
                raise ConflictError(
                    f"Secret '{secret_name}' already exists in Secrets Manager.",
                    field="logical_name",
                ) from exc
            raise

        arn: str = response["ARN"]
        log.info("secret.created", secret_name=secret_name, arn=arn)
        return arn

"""LLM provider abstraction for narrative generation.

Two concrete providers are supported:
- BedrockNarrativeProvider  — AWS Bedrock Runtime Converse API.
- AnthropicAPINarrativeProvider — Anthropic Python SDK (direct API).

Both are pre-instantiated at module import time so there is zero per-request
overhead for provider construction.  The active provider is selected once per
request (or from the 30-second TTL cache) via get_active_provider().

Anthropic API key loading order (runs once at import time):
  1. settings.anthropic_api_key  (ANTHROPIC_API_KEY env var / .env file)
  2. AWS Secrets Manager at /{environment}/platform/anthropic-api-key
     — skipped when aws_endpoint_url is set (LocalStack path; real secret
       does not exist there).

LocalStack behaviour:
  BedrockNarrativeProvider returns a plaintext stub — LocalStack CE does not
  include Bedrock, and pointing the client at it would produce connection
  errors rather than a useful response.
  AnthropicAPINarrativeProvider works normally via the real Anthropic API if
  ANTHROPIC_API_KEY is set in the local environment; otherwise it raises
  NarrativeError on the first call (caught and surfaced as narrative=null).
"""

from typing import Any, Protocol, runtime_checkable

import anthropic
import boto3
import structlog
from botocore.exceptions import ClientError

from app.src.core.config import settings
from app.src.core.exceptions import NarrativeError
from app.src.core.runtime_config.llm_provider_config import llm_provider_config
from app.src.repositories.config_repository import ConfigRepository

log = structlog.get_logger(__name__)

BEDROCK_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
ANTHROPIC_MODEL_ID = "claude-haiku-4-5-20251001"

_BEDROCK_STUB = (
    "[stub] Bedrock not available in local dev (AWS_ENDPOINT_URL is set). "
    "Risk flags above are deterministic and accurate."
)


@runtime_checkable
class NarrativeProvider(Protocol):
    def generate_narrative(self, prompt: str) -> str: ...


class BedrockNarrativeProvider:
    """Calls AWS Bedrock Runtime Converse API to generate a narrative."""

    def _get_client(self) -> Any:
        kwargs: dict[str, Any] = {"region_name": settings.aws_default_region}
        if settings.aws_access_key_id:
            kwargs["aws_access_key_id"] = settings.aws_access_key_id
        if settings.aws_secret_access_key:
            kwargs["aws_secret_access_key"] = settings.aws_secret_access_key
        # endpoint_url is intentionally NOT forwarded — LocalStack CE has no Bedrock.
        return boto3.client("bedrock-runtime", **kwargs)

    def generate_narrative(self, prompt: str) -> str:
        if settings.aws_endpoint_url:
            log.warning(
                "bedrock.stub",
                reason="AWS_ENDPOINT_URL is set; Bedrock not available in LocalStack CE",
                model_id=BEDROCK_MODEL_ID,
            )
            return _BEDROCK_STUB

        client = self._get_client()
        log.info("bedrock.request", model_id=BEDROCK_MODEL_ID, prompt=prompt)
        try:
            response = client.converse(
                modelId=BEDROCK_MODEL_ID,
                messages=[{"role": "user", "content": [{"text": prompt}]}],
                inferenceConfig={"maxTokens": 300, "temperature": 0.3},
            )
            narrative = str(response["output"]["message"]["content"][0]["text"]).strip()
            log.info("bedrock.response", model_id=BEDROCK_MODEL_ID, narrative=narrative)
            return narrative
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            msg = exc.response["Error"]["Message"]
            log.warning(
                "bedrock.error",
                error_code=code,
                error_message=msg,
                model_id=BEDROCK_MODEL_ID,
            )
            raise NarrativeError(f"{code}: {msg}") from exc
        except Exception as exc:
            description = f"Unexpected error: {type(exc).__name__}: {exc}"
            log.warning("bedrock.error", error=description, model_id=BEDROCK_MODEL_ID)
            raise NarrativeError(description) from exc


class AnthropicAPINarrativeProvider:
    """Calls the Anthropic Messages API directly via the anthropic Python SDK."""

    def __init__(self, api_key: str | None) -> None:
        self._api_key = api_key
        # Client is created lazily to avoid AuthenticationError at startup when
        # no key is configured (e.g. in local dev with bedrock selected).
        self._client: anthropic.Anthropic | None = None

    def _get_client(self) -> anthropic.Anthropic:
        if self._client is None:
            self._client = anthropic.Anthropic(api_key=self._api_key)
        return self._client

    def generate_narrative(self, prompt: str) -> str:
        try:
            client = self._get_client()
            log.info("anthropic.request", model_id=ANTHROPIC_MODEL_ID, prompt=prompt)
            response = client.messages.create(
                model=ANTHROPIC_MODEL_ID,
                max_tokens=300,
                messages=[{"role": "user", "content": prompt}],
            )
            narrative = response.content[0].text.strip()  # type: ignore[union-attr]
            log.info("anthropic.response", model_id=ANTHROPIC_MODEL_ID, narrative=narrative)
            return narrative
        except anthropic.APIError as exc:
            log.warning("anthropic.error", error=str(exc), model_id=ANTHROPIC_MODEL_ID)
            raise NarrativeError(str(exc)) from exc
        except Exception as exc:
            description = f"Unexpected error: {type(exc).__name__}: {exc}"
            log.warning("anthropic.error", error=description, model_id=ANTHROPIC_MODEL_ID)
            raise NarrativeError(description) from exc


def _load_anthropic_api_key() -> str | None:
    """Fetch the Anthropic API key once at startup.

    Returns immediately from settings when the env var is present.
    Fetches from Secrets Manager only on real AWS (aws_endpoint_url unset).
    Logs a warning and returns None on any failure — the provider will then
    raise NarrativeError on first use, surfaced as narrative=null.
    """
    if settings.anthropic_api_key:
        return settings.anthropic_api_key
    if settings.aws_endpoint_url:
        return None
    try:
        sm_client = boto3.client("secretsmanager", region_name=settings.aws_default_region)
        secret_name = f"/{settings.environment}/platform/anthropic-api-key"
        response = sm_client.get_secret_value(SecretId=secret_name)
        return str(response["SecretString"])
    except Exception as exc:
        log.warning("llm_provider.anthropic_key_fetch_failed", error=str(exc))
        return None


_ANTHROPIC_API_KEY: str | None = _load_anthropic_api_key()
_bedrock_provider = BedrockNarrativeProvider()
_anthropic_provider = AnthropicAPINarrativeProvider(_ANTHROPIC_API_KEY)


def get_active_provider(config_repo: ConfigRepository) -> NarrativeProvider:
    """Return the pre-instantiated provider selected by the cached runtime config."""
    provider_name = llm_provider_config.get(config_repo)
    if provider_name == "bedrock":
        return _bedrock_provider
    return _anthropic_provider

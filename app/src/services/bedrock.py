"""Thin boto3 wrapper for AWS Bedrock Runtime.

Follows the same pattern as secrets_manager.py:
  - A single _client() factory that reads endpoint_url from settings.
  - LocalStack community edition does not include Bedrock; when
    AWS_ENDPOINT_URL is set the call is short-circuited and a clearly
    labelled stub response is returned so local dev never breaks.
  - All Bedrock errors (throttling, access denied, model not enabled) are
    caught and surfaced as a (None, error_message) tuple so callers can
    degrade gracefully — the summary endpoint must still return correct
    deterministic facts even when Bedrock is unavailable.

Design principle: Bedrock is given pre-computed facts; it is asked only to
phrase them as readable prose.  It is never asked to determine whether a
fact is true.
"""

from typing import Any

import boto3
import structlog
from botocore.exceptions import ClientError

from app.src.core.config import settings
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.models.service import Service

log = structlog.get_logger(__name__)

# Claude Haiku 4.5 via Bedrock cross-region inference — cheapest fast model.
# Must be enabled in Bedrock console → Model access before first use.
BEDROCK_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001:0"

_STUB_RESPONSE = (
    "[stub] Bedrock not available in local dev (AWS_ENDPOINT_URL is set). "
    "Risk flags above are deterministic and accurate."
)


def _client() -> Any:
    kwargs: dict[str, Any] = {"region_name": settings.aws_default_region}
    if settings.aws_access_key_id:
        kwargs["aws_access_key_id"] = settings.aws_access_key_id
    if settings.aws_secret_access_key:
        kwargs["aws_secret_access_key"] = settings.aws_secret_access_key
    # Note: endpoint_url is intentionally NOT forwarded to bedrock-runtime even
    # when set — LocalStack CE does not support Bedrock, so we stub instead of
    # pointing at LocalStack and getting a connection error.
    return boto3.client("bedrock-runtime", **kwargs)


def _build_prompt(
    events: list[RequestEvent],
    risk_flags: dict[str, Any],
    secret_request: SecretRequest,
    service: Service,
) -> str:
    timeline = "\n".join(
        f"  - {e.status} at {e.timestamp.strftime('%Y-%m-%d %H:%M:%S UTC')} by {e.actor}"
        + (f" ({e.detail[:120]})" if e.detail else "")
        for e in events
    )

    active_flags: list[str] = []
    if risk_flags["ownership_mismatch"]:
        active_flags.append("- Ownership mismatch: requester is not the registered service owner")
    if risk_flags["naming_violations"]:
        for v in risk_flags["naming_violations"]:
            active_flags.append(f"- Naming violation: {v}")
    if risk_flags["is_production"]:
        active_flags.append("- Production environment: this secret targets prod")

    flags_section = "\n".join(active_flags) if active_flags else "- None: all checks passed"

    # The prompt text is a multi-line string; long lines here are prose sent to
    # the model, not Python code — ruff E501 is suppressed for this block.
    return (  # noqa: E501
        "Write a brief, factual 2-3 sentence audit summary of this secret provisioning"
        " request for a platform engineering reviewer."
        " Use only the facts provided below — do not infer or add information not stated.\n\n"
        f"Service: {service.name} (team: {service.team})\n"
        f"Secret requested: {secret_request.logical_name} for {secret_request.environment}\n"
        f"Final status: {secret_request.status}\n\n"
        f"Timeline:\n{timeline}\n\n"
        "Pre-determined flags (state these factually if true, omit if false"
        " — do not editorialize or speculate beyond what is listed):\n"
        f"{flags_section}"
    )


def generate_request_narrative(
    events: list[RequestEvent],
    risk_flags: dict[str, Any],
    secret_request: SecretRequest,
    service: Service,
) -> tuple[str | None, str | None]:
    """Generate a natural-language narrative by sending pre-computed facts to Bedrock.

    Returns:
        (narrative, error) — exactly one of the two will be None.
        On success:  (narrative_text, None)
        On failure:  (None, error_description)

    When AWS_ENDPOINT_URL is set (LocalStack), returns the stub immediately
    without attempting any network call.
    """
    if settings.aws_endpoint_url:
        log.warning(
            "bedrock.stub",
            reason="AWS_ENDPOINT_URL is set; Bedrock not available in LocalStack CE",
            model_id=BEDROCK_MODEL_ID,
        )
        return _STUB_RESPONSE, None

    prompt = _build_prompt(events, risk_flags, secret_request, service)

    client = _client()
    try:
        response = client.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": 300, "temperature": 0.3},
        )
        narrative: str = response["output"]["message"]["content"][0]["text"].strip()
        return narrative, None

    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        msg = exc.response["Error"]["Message"]
        error_description = f"{code}: {msg}"
        log.warning(
            "bedrock.error",
            error_code=code,
            error_message=msg,
            model_id=BEDROCK_MODEL_ID,
        )
        return None, error_description

    except Exception as exc:
        error_description = f"Unexpected error: {type(exc).__name__}: {exc}"
        log.warning("bedrock.error", error=error_description, model_id=BEDROCK_MODEL_ID)
        return None, error_description

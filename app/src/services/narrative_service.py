"""Narrative service: orchestrates risk checks + LLM narrative for the summary endpoint.

build_prompt() lives here (moved from services/bedrock.py, which is deleted in
Stage 3).  Until Stage 3, bedrock.py keeps its own copy so the route's import is
unbroken; the two copies are identical.
"""

import uuid
from typing import Any

import structlog

from app.src.core.config import settings
from app.src.core.exceptions import NarrativeError, NotFoundError
from app.src.models.request_event import RequestEvent
from app.src.models.secret_request import SecretRequest
from app.src.models.service import Service
from app.src.repositories.config_repository import ConfigRepository
from app.src.repositories.request_event_repository import RequestEventRepository
from app.src.repositories.secret_request_repository import SecretRequestRepository
from app.src.repositories.service_repository import ServiceRepository
from app.src.schemas.secret_request import (
    NarrativeSource,
    RiskFlagsRead,
    SecretRequestSummaryRead,
)
from app.src.services.llm_provider import BedrockNarrativeProvider, get_active_provider
from app.src.services.risk_checks import compute_risk_flags

log = structlog.get_logger(__name__)


class NarrativeService:
    def __init__(
        self,
        secret_request_repo: SecretRequestRepository,
        request_event_repo: RequestEventRepository,
        service_repo: ServiceRepository,
        config_repo: ConfigRepository,
    ) -> None:
        self._secret_request_repo = secret_request_repo
        self._request_event_repo = request_event_repo
        self._service_repo = service_repo
        self._config_repo = config_repo

    @staticmethod
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
            active_flags.append(
                "- Ownership mismatch: requester is not the registered service owner"
            )
        if risk_flags["naming_violations"]:
            for v in risk_flags["naming_violations"]:
                active_flags.append(f"- Naming violation: {v}")
        if risk_flags["is_production"]:
            active_flags.append("- Production environment: this secret targets prod")

        flags_section = "\n".join(active_flags) if active_flags else "- None: all checks passed"

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

    def generate_summary(self, secret_request_id: uuid.UUID) -> SecretRequestSummaryRead:
        req = self._secret_request_repo.get_by_id(secret_request_id)
        if req is None:
            raise NotFoundError(
                f"Secret request '{secret_request_id}' not found.", field="request_id"
            )

        service = self._service_repo.get_by_id(req.service_id)
        assert service is not None  # service_id is a FK; service always exists

        events = self._request_event_repo.list_for_request(secret_request_id)

        requested_by = next(
            (e.actor for e in events if e.status == "PENDING"),
            "unknown",
        )

        risk_flags = compute_risk_flags(req, service, requested_by)

        provider = get_active_provider(self._config_repo)
        prompt = self._build_prompt(events, risk_flags, req, service)

        narrative: str | None = None
        error: str | None = None
        try:
            narrative = provider.generate_narrative(prompt)
        except NarrativeError as exc:
            error = exc.message

        generated_by: NarrativeSource | None
        if error is not None:
            generated_by = None
        elif isinstance(provider, BedrockNarrativeProvider) and settings.aws_endpoint_url:
            generated_by = "stub"
        elif isinstance(provider, BedrockNarrativeProvider):
            generated_by = "bedrock"
        else:
            generated_by = "anthropic_api"

        return SecretRequestSummaryRead(
            id=req.id,
            facts=RiskFlagsRead(**risk_flags),
            narrative=narrative,
            narrative_generated_by=generated_by,
            narrative_error=error,
        )

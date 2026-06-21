"""Deterministic risk checks for secret requests.

All methods are pure — no I/O, no AWS calls, no DB access.
RiskCheckService.compute_risk_flags() is the single entry point used by the summary endpoint.

Design principle: these methods determine facts (ownership match, naming
compliance, environment risk). Bedrock is never consulted to determine facts;
it only receives the pre-computed output of these methods to narrate as prose.
"""

import re
from typing import Any

from app.src.models.secret_request import SecretRequest
from app.src.models.service import Service

RiskFlags = dict[str, Any]


class RiskCheckService:
    _NAME_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")

    @staticmethod
    def check_ownership_mismatch(requested_by: str, service_owner_email: str) -> bool:
        """Return True if requested_by does not match the service owner's email.

        "unknown" is treated as an unconditional mismatch — it's the placeholder
        written when no authenticated identity is available (see session-3 note in
        SecretRequestBody.requested_by) and should always be flagged for review.
        """
        if requested_by.lower() == "unknown":
            return True
        return requested_by.lower() != service_owner_email.lower()

    @staticmethod
    def check_naming_convention(logical_name: str, environment: str) -> list[str]:
        """Return a list of naming violation reasons (empty = compliant).

        Rules:
        - Must match ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ (lowercase, hyphen-separated,
          starts with a letter).
        - Must not embed the environment string — the environment is already a
          separate field in the data model and duplicating it in the name is
          both redundant and a common source of inconsistency.
        """
        violations: list[str] = []
        if not RiskCheckService._NAME_RE.match(logical_name):
            violations.append("name must be lowercase, hyphen-separated")
        if environment in logical_name:
            violations.append("name should not embed the environment, it's a separate field")
        return violations

    @staticmethod
    def check_production_risk(environment: str) -> bool:
        """Return True if the request targets the production environment.

        Production requests always surface in the summary regardless of other flags,
        giving reviewers explicit visibility into prod-bound provisioning.
        """
        return environment == "prod"

    @staticmethod
    def compute_risk_flags(
        secret_request: SecretRequest,
        service: Service,
        requested_by: str,
    ) -> RiskFlags:
        """Combine all risk checks into a single structured result.

        requested_by is passed explicitly by the caller (extracted from the first
        PENDING RequestEvent actor) because it is not stored on SecretRequest itself.

        Returns:
            {
                "ownership_mismatch": bool,
                "naming_violations": list[str],
                "is_production": bool,
                "has_any_flag": bool,   # true if any check is non-empty/true
            }
        """
        ownership_mismatch = RiskCheckService.check_ownership_mismatch(
            requested_by, service.owner_email
        )
        naming_violations = RiskCheckService.check_naming_convention(
            secret_request.logical_name, secret_request.environment
        )
        is_production = RiskCheckService.check_production_risk(secret_request.environment)
        has_any_flag = ownership_mismatch or bool(naming_violations) or is_production
        return {
            "ownership_mismatch": ownership_mismatch,
            "naming_violations": naming_violations,
            "is_production": is_production,
            "has_any_flag": has_any_flag,
        }

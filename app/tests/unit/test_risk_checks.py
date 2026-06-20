"""Unit tests for deterministic risk checks.

Pure functions — no mocks, no I/O, no DB, no AWS.
"""

import uuid
from unittest.mock import MagicMock

import pytest

from app.src.services.risk_checks import (
    check_naming_convention,
    check_ownership_mismatch,
    check_production_risk,
    compute_risk_flags,
)


# ── check_ownership_mismatch ──────────────────────────────────────────────────


def test_ownership_match_same_case() -> None:
    assert check_ownership_mismatch("alice@example.com", "alice@example.com") is False


def test_ownership_match_case_insensitive() -> None:
    assert check_ownership_mismatch("Alice@Example.com", "alice@example.com") is False


def test_ownership_mismatch_different_user() -> None:
    assert check_ownership_mismatch("bob@example.com", "alice@example.com") is True


def test_ownership_mismatch_unknown_lowercase() -> None:
    assert check_ownership_mismatch("unknown", "alice@example.com") is True


def test_ownership_mismatch_unknown_mixed_case() -> None:
    # "Unknown", "UNKNOWN" etc. must all be flagged
    assert check_ownership_mismatch("Unknown", "alice@example.com") is True
    assert check_ownership_mismatch("UNKNOWN", "alice@example.com") is True


def test_ownership_mismatch_unknown_even_if_owner_is_also_unknown() -> None:
    # "unknown" is unconditionally a mismatch regardless of owner_email value
    assert check_ownership_mismatch("unknown", "unknown") is True


# ── check_naming_convention ───────────────────────────────────────────────────


def test_naming_valid() -> None:
    assert check_naming_convention("db-password", "dev") == []


def test_naming_valid_single_word() -> None:
    assert check_naming_convention("apikey", "staging") == []


def test_naming_valid_with_numbers() -> None:
    assert check_naming_convention("oauth2-token", "prod") == []


def test_naming_uppercase_violation() -> None:
    violations = check_naming_convention("DB-Password", "dev")
    assert len(violations) == 1
    assert "lowercase" in violations[0]


def test_naming_starts_with_number_violation() -> None:
    violations = check_naming_convention("1secret", "dev")
    assert len(violations) == 1
    assert "lowercase" in violations[0]


def test_naming_underscore_violation() -> None:
    violations = check_naming_convention("db_password", "dev")
    assert len(violations) == 1
    assert "lowercase" in violations[0]


def test_naming_embeds_environment_violation() -> None:
    violations = check_naming_convention("db-password-prod", "prod")
    assert len(violations) == 1
    assert "environment" in violations[0]


def test_naming_both_violations() -> None:
    # "Dev-secret-dev": uppercase start → regex violation; contains "dev" → env violation
    violations = check_naming_convention("Dev-secret-dev", "dev")
    assert len(violations) == 2


def test_naming_environment_not_flagged_when_absent() -> None:
    assert check_naming_convention("db-password", "prod") == []


def test_naming_environment_check_is_substring() -> None:
    # "staging" inside "staging-token" should be flagged
    violations = check_naming_convention("staging-token", "staging")
    assert any("environment" in v for v in violations)


# ── check_production_risk ─────────────────────────────────────────────────────


def test_production_risk_prod() -> None:
    assert check_production_risk("prod") is True


def test_production_risk_dev() -> None:
    assert check_production_risk("dev") is False


def test_production_risk_staging() -> None:
    assert check_production_risk("staging") is False


# ── compute_risk_flags ────────────────────────────────────────────────────────


def _make_request(logical_name: str = "db-password", environment: str = "dev") -> MagicMock:
    req = MagicMock()
    req.logical_name = logical_name
    req.environment = environment
    return req


def _make_service(owner_email: str = "alice@example.com") -> MagicMock:
    svc = MagicMock()
    svc.owner_email = owner_email
    return svc


def test_compute_no_flags() -> None:
    flags = compute_risk_flags(
        _make_request("db-password", "dev"),
        _make_service("alice@example.com"),
        requested_by="alice@example.com",
    )
    assert flags["ownership_mismatch"] is False
    assert flags["naming_violations"] == []
    assert flags["is_production"] is False
    assert flags["has_any_flag"] is False


def test_compute_ownership_mismatch_sets_has_any_flag() -> None:
    flags = compute_risk_flags(
        _make_request("db-password", "dev"),
        _make_service("alice@example.com"),
        requested_by="bob@example.com",
    )
    assert flags["ownership_mismatch"] is True
    assert flags["has_any_flag"] is True


def test_compute_naming_violation_sets_has_any_flag() -> None:
    flags = compute_risk_flags(
        _make_request("DB_Password", "dev"),
        _make_service("alice@example.com"),
        requested_by="alice@example.com",
    )
    assert len(flags["naming_violations"]) > 0
    assert flags["has_any_flag"] is True


def test_compute_production_sets_has_any_flag() -> None:
    flags = compute_risk_flags(
        _make_request("db-password", "prod"),
        _make_service("alice@example.com"),
        requested_by="alice@example.com",
    )
    assert flags["is_production"] is True
    assert flags["has_any_flag"] is True


def test_compute_unknown_requester_triggers_mismatch() -> None:
    flags = compute_risk_flags(
        _make_request(),
        _make_service("alice@example.com"),
        requested_by="unknown",
    )
    assert flags["ownership_mismatch"] is True
    assert flags["has_any_flag"] is True


def test_compute_all_flags() -> None:
    flags = compute_risk_flags(
        _make_request("DB_Password_Prod", "prod"),
        _make_service("alice@example.com"),
        requested_by="unknown",
    )
    assert flags["ownership_mismatch"] is True
    assert len(flags["naming_violations"]) >= 1
    assert flags["is_production"] is True
    assert flags["has_any_flag"] is True

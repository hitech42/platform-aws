"""Unit tests for engine construction in db/session.py — IAM token calls are mocked."""

from typing import Any
from unittest.mock import patch

import pytest
from sqlalchemy import event
from sqlalchemy.pool import NullPool

from app.src.db import session as session_module


def test_password_mode_does_not_use_null_pool(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(session_module.settings, "db_auth_mode", "password")
    monkeypatch.setattr(
        session_module.settings, "database_url", "postgresql://app:pw@localhost:5432/platform"
    )

    engine = session_module._build_engine()

    assert not isinstance(engine.pool, NullPool)


def test_iam_mode_uses_null_pool(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(session_module.settings, "db_auth_mode", "iam")
    monkeypatch.setattr(
        session_module.settings,
        "database_url",
        "postgresql://platform_app@db.example.com:5432/platform",
    )

    engine = session_module._build_engine()

    assert isinstance(engine.pool, NullPool)


def test_iam_mode_injects_fresh_token_on_connect(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(session_module.settings, "db_auth_mode", "iam")
    monkeypatch.setattr(
        session_module.settings,
        "database_url",
        "postgresql://platform_app@db.example.com:5432/platform",
    )

    with patch(
        "app.src.db.session.generate_iam_auth_token", return_value="fresh-token"
    ) as mock_generate:
        engine = session_module._build_engine()

        captured: dict[str, Any] = {}

        @event.listens_for(engine, "do_connect")
        def _capture(
            dialect: Any, conn_rec: Any, cargs: list[Any], cparams: dict[str, Any]
        ) -> None:
            captured.update(cparams)
            raise RuntimeError("stop before a real network connection is attempted")

        with pytest.raises(RuntimeError):
            engine.connect()

    assert captured.get("password") == "fresh-token"
    mock_generate.assert_called_once()

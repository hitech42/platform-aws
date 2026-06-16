"""Unit tests for RDS IAM auth token generation — boto3 is fully mocked."""

from unittest.mock import MagicMock, patch

import pytest
from sqlalchemy.engine import make_url

from app.src.db.iam_auth import generate_iam_auth_token


def test_generate_iam_auth_token_calls_rds_client_with_correct_args() -> None:
    mock_client = MagicMock()
    mock_client.generate_db_auth_token.return_value = "fake-token"

    with patch("app.src.db.iam_auth.boto3.client", return_value=mock_client):
        url = make_url("postgresql://platform_app@db.example.com:5432/platform")
        token = generate_iam_auth_token(url)

    assert token == "fake-token"
    call_kwargs = mock_client.generate_db_auth_token.call_args.kwargs
    assert call_kwargs["DBHostname"] == "db.example.com"
    assert call_kwargs["Port"] == 5432
    assert call_kwargs["DBUsername"] == "platform_app"


def test_generate_iam_auth_token_defaults_port_when_missing() -> None:
    mock_client = MagicMock()
    mock_client.generate_db_auth_token.return_value = "fake-token"

    with patch("app.src.db.iam_auth.boto3.client", return_value=mock_client):
        url = make_url("postgresql://platform_app@db.example.com/platform")
        generate_iam_auth_token(url)

    call_kwargs = mock_client.generate_db_auth_token.call_args.kwargs
    assert call_kwargs["Port"] == 5432


def test_endpoint_url_forwarded_to_boto3(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.db.iam_auth.settings.aws_endpoint_url", "http://localhost:4566")

    captured_kwargs: dict[str, object] = {}

    def fake_boto_client(service: str, **kwargs: object) -> MagicMock:
        captured_kwargs.update(kwargs)
        mock = MagicMock()
        mock.generate_db_auth_token.return_value = "fake-token"
        return mock

    with patch("app.src.db.iam_auth.boto3.client", side_effect=fake_boto_client):
        generate_iam_auth_token(make_url("postgresql://app@db.example.com:5432/platform"))

    assert captured_kwargs["endpoint_url"] == "http://localhost:4566"


def test_no_endpoint_url_when_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.db.iam_auth.settings.aws_endpoint_url", None)

    captured_kwargs: dict[str, object] = {}

    def fake_boto_client(service: str, **kwargs: object) -> MagicMock:
        captured_kwargs.update(kwargs)
        mock = MagicMock()
        mock.generate_db_auth_token.return_value = "fake-token"
        return mock

    with patch("app.src.db.iam_auth.boto3.client", side_effect=fake_boto_client):
        generate_iam_auth_token(make_url("postgresql://app@db.example.com:5432/platform"))

    assert "endpoint_url" not in captured_kwargs

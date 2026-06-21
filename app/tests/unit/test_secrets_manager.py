"""Unit tests for the SecretsManagerService wrapper — boto3 is fully mocked."""

from unittest.mock import MagicMock, patch

import pytest
from botocore.exceptions import ClientError

from app.src.core.exceptions import ConflictError, ValidationError
from app.src.services.secrets_manager_service import SecretsManagerService


def _make_client_error(code: str) -> ClientError:
    return ClientError(
        error_response={"Error": {"Code": code, "Message": "mocked"}},
        operation_name="CreateSecret",
    )


# ── generate_value guard ───────────────────────────────────────────────────────


def test_generate_value_false_raises_validation_error() -> None:
    with pytest.raises(ValidationError) as exc_info:
        SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="db-pass",
            environment="dev",
            generate_value=False,
        )
    assert exc_info.value.field == "generate_value"
    assert exc_info.value.status_code == 422


# ── happy path ────────────────────────────────────────────────────────────────


def test_create_app_secret_returns_arn() -> None:
    expected_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:platform/svc/dev/db-pass"
    mock_client = MagicMock()
    mock_client.create_secret.return_value = {
        "ARN": expected_arn,
        "Name": "platform/svc/dev/db-pass",
    }

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        arn = SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="db-pass",
            environment="dev",
            generate_value=True,
        )

    assert arn == expected_arn


def test_create_app_secret_uses_correct_secret_name() -> None:
    mock_client = MagicMock()
    mock_client.create_secret.return_value = {"ARN": "arn:aws:sm:::secret:x"}

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        SecretsManagerService().create_app_secret(
            service_name="payments",
            logical_name="stripe-key",
            environment="staging",
            generate_value=True,
        )

    call_kwargs = mock_client.create_secret.call_args.kwargs
    assert call_kwargs["Name"] == "platform/payments/staging/stripe-key"


def test_create_app_secret_uses_provided_description() -> None:
    mock_client = MagicMock()
    mock_client.create_secret.return_value = {"ARN": "arn:aws:sm:::secret:x"}

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="key",
            environment="dev",
            generate_value=True,
            description="Custom description",
        )

    call_kwargs = mock_client.create_secret.call_args.kwargs
    assert call_kwargs["Description"] == "Custom description"


def test_create_app_secret_generates_default_description_when_none() -> None:
    mock_client = MagicMock()
    mock_client.create_secret.return_value = {"ARN": "arn:aws:sm:::secret:x"}

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="key",
            environment="dev",
            generate_value=True,
        )

    call_kwargs = mock_client.create_secret.call_args.kwargs
    assert "svc" in call_kwargs["Description"]
    assert "dev" in call_kwargs["Description"]


def test_create_app_secret_value_not_logged(caplog: pytest.LogCaptureFixture) -> None:
    secret_value_holder: list[str] = []

    def capture_create(**kwargs: object) -> dict[str, str]:
        secret_value_holder.append(str(kwargs.get("SecretString", "")))
        return {"ARN": "arn:aws:sm:::secret:x"}

    mock_client = MagicMock()
    mock_client.create_secret.side_effect = capture_create

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        with caplog.at_level("DEBUG"):
            SecretsManagerService().create_app_secret(
                service_name="svc",
                logical_name="key",
                environment="dev",
                generate_value=True,
            )

    assert secret_value_holder, "create_secret was not called"
    generated_value = secret_value_holder[0]
    assert generated_value not in caplog.text


# ── error handling ────────────────────────────────────────────────────────────


def test_resource_exists_raises_conflict_error() -> None:
    mock_client = MagicMock()
    mock_client.create_secret.side_effect = _make_client_error("ResourceExistsException")

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        with pytest.raises(ConflictError) as exc_info:
            SecretsManagerService().create_app_secret(
                service_name="svc",
                logical_name="db-pass",
                environment="dev",
                generate_value=True,
            )

    assert exc_info.value.status_code == 409
    assert exc_info.value.field == "logical_name"


def test_other_client_error_propagates() -> None:
    mock_client = MagicMock()
    mock_client.create_secret.side_effect = _make_client_error("AccessDeniedException")

    with patch("app.src.services.secrets_manager_service.boto3.client", return_value=mock_client):
        with pytest.raises(ClientError):
            SecretsManagerService().create_app_secret(
                service_name="svc",
                logical_name="key",
                environment="dev",
                generate_value=True,
            )


# ── endpoint_url forwarding ────────────────────────────────────────────────────


def test_endpoint_url_forwarded_to_boto3(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.src.services.secrets_manager_service.settings.aws_endpoint_url",
        "http://localhost:4566",
    )

    captured_kwargs: dict[str, object] = {}

    def fake_boto_client(service: str, **kwargs: object) -> MagicMock:
        captured_kwargs.update(kwargs)
        mock = MagicMock()
        mock.create_secret.return_value = {"ARN": "arn:aws:sm:::secret:x"}
        return mock

    _target = "app.src.services.secrets_manager_service.boto3.client"
    with patch(_target, side_effect=fake_boto_client):
        SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="key",
            environment="dev",
            generate_value=True,
        )

    assert captured_kwargs["endpoint_url"] == "http://localhost:4566"


def test_no_endpoint_url_when_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.src.services.secrets_manager_service.settings.aws_endpoint_url", None)

    captured_kwargs: dict[str, object] = {}

    def fake_boto_client(service: str, **kwargs: object) -> MagicMock:
        captured_kwargs.update(kwargs)
        mock = MagicMock()
        mock.create_secret.return_value = {"ARN": "arn:aws:sm:::secret:x"}
        return mock

    _target = "app.src.services.secrets_manager_service.boto3.client"
    with patch(_target, side_effect=fake_boto_client):
        SecretsManagerService().create_app_secret(
            service_name="svc",
            logical_name="key",
            environment="dev",
            generate_value=True,
        )

    assert "endpoint_url" not in captured_kwargs

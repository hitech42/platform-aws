from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Database
    database_url: str = "postgresql://app:localdev@localhost:5432/platform"
    db_auth_mode: Literal["password", "iam"] = "password"

    # AWS
    aws_endpoint_url: str | None = None
    aws_default_region: str = "us-east-1"
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None

    # App
    log_level: str = "INFO"
    environment: Literal["dev", "staging", "prod"] = "dev"


settings = Settings()

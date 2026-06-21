"""TTL-cached accessor for the llm_provider runtime configuration key.

Ops can flip the active provider via a psql UPDATE against the config table;
the change propagates to all in-flight requests within CACHE_TTL_SECONDS (30 s)
with no redeploy or container restart required.

Failure precedence when the DB is unreachable:
  1. Stale cached value (returned with a warning).
  2. _DEFAULT_PROVIDER ("anthropic_api") when no cached value exists at all.
"""

import time

import structlog

from app.src.repositories.config_repository import ConfigRepository

log = structlog.get_logger(__name__)

CACHE_TTL_SECONDS: int = 30


class LLMProviderConfig:
    """TTL-cached reader for the llm_provider key in the config table.

    A module-level singleton (``llm_provider_config``) is used by the
    application.  Tests can either reset the singleton's cache via
    ``_reset_cache()`` or construct independent instances with a custom TTL.
    """

    _VALID_PROVIDERS: frozenset[str] = frozenset({"bedrock", "anthropic_api"})
    _DEFAULT_PROVIDER: str = "anthropic_api"

    def __init__(self, ttl_seconds: int = CACHE_TTL_SECONDS) -> None:
        self._ttl = ttl_seconds
        self._cached_value: str | None = None
        self._cached_at: float | None = None

    def _reset_cache(self) -> None:
        """Reset the in-memory cache. For unit tests only."""
        self._cached_value = None
        self._cached_at = None

    def _is_fresh(self) -> bool:
        return self._cached_at is not None and (time.monotonic() - self._cached_at) < self._ttl

    def _validate(self, raw: str) -> str:
        if raw in self._VALID_PROVIDERS:
            return raw
        log.warning(
            "llm_provider_config.invalid_value",
            key="llm_provider",
            value=raw,
            valid=sorted(self._VALID_PROVIDERS),
            fallback=self._DEFAULT_PROVIDER,
        )
        return self._DEFAULT_PROVIDER

    def get(self, config_repo: ConfigRepository) -> str:
        """Return the active LLM provider name, using the cache when TTL has not expired."""
        if self._is_fresh():
            return self._cached_value  # type: ignore[return-value]  # fresh → never None

        try:
            value = config_repo.get_value("llm_provider")
            raw = value if value is not None else self._DEFAULT_PROVIDER
            validated = self._validate(raw)
            self._cached_value = validated
            self._cached_at = time.monotonic()
            return validated

        except Exception as exc:
            log.warning(
                "llm_provider_config.db_error",
                key="llm_provider",
                error=str(exc),
                stale_cache=self._cached_value,
            )
            if self._cached_value is not None:
                return self._cached_value
            return self._DEFAULT_PROVIDER


llm_provider_config = LLMProviderConfig()

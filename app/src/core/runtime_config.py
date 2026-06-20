"""Runtime configuration service with short-TTL in-memory caching.

Reads key/value pairs from the public.config table and caches them in memory
for CACHE_TTL_SECONDS (default 30).  Ops can flip the active LLM provider
via a psql UPDATE with no redeploy or container restart — the change propagates
to all requests within the TTL window.

Cache design: two module-level variables (_cached_value, _cached_at) rather than
a class.  There is exactly one thing being cached (llm_provider) and module-level
state is trivial to reset in unit tests via _reset_cache().  A class would add
ceremony with no benefit for a single-key cache.

Failure precedence when the DB is unreachable:
  1. Stale cached value (returned with a warning).
  2. _DEFAULT_PROVIDER ("anthropic_api") if no cached value exists at all.
"""

import time

import structlog
from sqlalchemy.orm import Session

from app.src.models.config import Config

log = structlog.get_logger(__name__)

CACHE_TTL_SECONDS: int = 30
_VALID_PROVIDERS: frozenset[str] = frozenset({"bedrock", "anthropic_api"})
_DEFAULT_PROVIDER: str = "anthropic_api"

# Both are None until the first successful DB fetch.
_cached_value: str | None = None
_cached_at: float | None = None  # time.monotonic() of last successful fetch


def _reset_cache() -> None:
    """Reset the in-memory cache. For unit tests only."""
    global _cached_value, _cached_at
    _cached_value = None
    _cached_at = None


def _is_cache_fresh() -> bool:
    return _cached_at is not None and (time.monotonic() - _cached_at) < CACHE_TTL_SECONDS


def _validate(raw: str) -> str:
    if raw in _VALID_PROVIDERS:
        return raw
    log.warning(
        "runtime_config.invalid_value",
        key="llm_provider",
        value=raw,
        valid=sorted(_VALID_PROVIDERS),
        fallback=_DEFAULT_PROVIDER,
    )
    return _DEFAULT_PROVIDER


def get_llm_provider(db: Session) -> str:
    """Return the active LLM provider, using the in-memory cache when fresh.

    Uses db.get() for a direct primary-key lookup — equivalent to
    SELECT value FROM config WHERE key = 'llm_provider' with no full scan.
    """
    global _cached_value, _cached_at

    if _is_cache_fresh():
        return _cached_value  # type: ignore[return-value]  # fresh → never None

    try:
        row = db.get(Config, "llm_provider")
        raw = row.value if row else _DEFAULT_PROVIDER
        validated = _validate(raw)
        _cached_value = validated
        _cached_at = time.monotonic()
        return validated

    except Exception as exc:
        log.warning(
            "runtime_config.db_error",
            key="llm_provider",
            error=str(exc),
            stale_cache=_cached_value,
        )
        if _cached_value is not None:
            return _cached_value
        return _DEFAULT_PROVIDER

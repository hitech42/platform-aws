"""Request logging middleware.

Emits one structured log event per request with HTTP-level fields. Business-level
events (state transitions, provisioning outcomes) are logged by the service/route layer.

Health endpoints (/healthz, /readyz) are logged at DEBUG rather than INFO because
the ALB hits them every few seconds and INFO-level noise would flood CloudWatch Logs.

The middleware reads optional fields set by route handlers on request.state:
  from_status  — status of a secret request before the current operation
  to_status    — status after the operation completes

These are set only by the approve route so that the single request log event for
that endpoint captures the full lifecycle transition (e.g. PENDING → PROVISIONED).
"""

import re
import time
from typing import Any

import structlog
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response

log = structlog.get_logger(__name__)

_HEALTH_PATHS: frozenset[str] = frozenset({"/healthz", "/readyz"})

# Matches the UUID segment in paths like /secret-requests/{uuid} and
# /secret-requests/{uuid}/events and /secret-requests/{uuid}/approve.
_SECRET_REQUEST_ID_RE = re.compile(
    r"/secret-requests/"
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
)


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        start = time.monotonic()
        response = await call_next(request)
        duration_ms = round((time.monotonic() - start) * 1000)

        path = request.url.path
        fields: dict[str, Any] = {
            "method": request.method,
            "path": path,
            "status_code": response.status_code,
            "duration_ms": duration_ms,
        }

        m = _SECRET_REQUEST_ID_RE.search(path)
        if m:
            fields["secret_request_id"] = m.group(1)

        from_status: str | None = getattr(request.state, "from_status", None)
        to_status: str | None = getattr(request.state, "to_status", None)
        if from_status is not None:
            fields["from_status"] = from_status
        if to_status is not None:
            fields["to_status"] = to_status

        if path in _HEALTH_PATHS:
            log.debug("request", **fields)
        else:
            log.info("request", **fields)

        return response

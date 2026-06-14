# structlog is preferred over python-json-logger because:
# 1. Context binding (structlog.contextvars) lets you attach request_id once per request
#    and it appears on every log line — essential for tracing in CloudWatch Logs Insights.
# 2. Renderer pipeline is composable: pretty-print in dev, strict JSON in prod, same call sites.
# 3. Ships with PEP 561 stubs so mypy is happy with no extra packages.
import logging
import sys

import structlog

# Module-level list used as the structlog processor chain. Using a stable list
# object (modified in-place on each configure_logging call) ensures that
# structlog.testing.capture_logs() — which modifies the current processors list
# in-place — correctly intercepts log calls even when configure_logging has been
# called multiple times (e.g. integration tests followed by unit tests in the
# same process).
_PROCESSORS: list[structlog.types.Processor] = []


def configure_logging(log_level: str = "INFO") -> None:
    level = getattr(logging, log_level.upper(), logging.INFO)

    shared_processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
    ]

    # Populate _PROCESSORS in-place so any bound loggers that already hold a
    # reference to this list see the updated chain without needing to rebind.
    _PROCESSORS.clear()
    _PROCESSORS.extend(
        [
            *shared_processors,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ]
    )

    structlog.configure(
        processors=_PROCESSORS,
        wrapper_class=structlog.stdlib.BoundLogger,
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )

    formatter = structlog.stdlib.ProcessorFormatter(
        # JSON in prod/staging for CloudWatch; pretty-print in dev for readability.
        processor=(
            structlog.processors.JSONRenderer()
            if log_level.upper() != "DEBUG"
            else structlog.dev.ConsoleRenderer()
        ),
        foreign_pre_chain=shared_processors,
    )

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # Silence overly verbose third-party loggers.
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)

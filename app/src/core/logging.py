# structlog is preferred over python-json-logger because:
# 1. Context binding (structlog.contextvars) lets you attach request_id once per request
#    and it appears on every log line — essential for tracing in CloudWatch Logs Insights.
# 2. Renderer pipeline is composable: pretty-print in dev, strict JSON in prod, same call sites.
# 3. Ships with PEP 561 stubs so mypy is happy with no extra packages.
import logging
import sys

import structlog


def configure_logging(log_level: str = "INFO") -> None:
    level = getattr(logging, log_level.upper(), logging.INFO)

    shared_processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
    ]

    structlog.configure(
        processors=[
            *shared_processors,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
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

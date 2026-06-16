import sys
from logging.config import fileConfig
from pathlib import Path

from alembic import context
from sqlalchemy import engine_from_config, pool
from sqlalchemy.engine import make_url

# Add the project root (parent of app/) to sys.path so `app.src.*` imports resolve
# regardless of which directory alembic is invoked from.
PROJECT_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(PROJECT_ROOT))

from app.src.core.config import settings  # noqa: E402
from app.src.db.iam_auth import generate_iam_auth_token  # noqa: E402
from app.src.models import Base  # noqa: E402  — imports all models so metadata is populated

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Override the placeholder URL with the value from app settings, but only if the
# caller has not already set a real URL (e.g. the integration test harness sets the
# testcontainers URL via cfg.set_main_option() before calling command.upgrade()).
_configured_url = config.get_main_option("sqlalchemy.url")
if not _configured_url or _configured_url == "driver://placeholder/placeholder":
    config.set_main_option("sqlalchemy.url", settings.database_url)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    # The migration task is a one-shot process, so a single token generated
    # just before connecting is sufficient — no refresh logic needed here
    # (contrast with the long-lived app engine in db/session.py).
    connect_args: dict[str, str] = {}
    if settings.db_auth_mode == "iam":
        url_str = config.get_main_option("sqlalchemy.url")
        assert url_str is not None  # set above, either by the test harness or settings.database_url
        connect_args["password"] = generate_iam_auth_token(make_url(url_str))

    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
        connect_args=connect_args,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()

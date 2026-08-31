# Repository Guidelines

## Project Structure & Module Organization

This repository has two main areas: `app/` for the FastAPI service and `infra/` for Terraform. Application code lives under `app/src/` and follows a layered structure: `api/v1/routes/` for HTTP handlers, `services/` for business logic, `repositories/` for database access, `models/` for SQLAlchemy ORM models, `schemas/` for Pydantic contracts, and `db/` for sessions and Alembic migrations. Tests live in `app/tests/unit/` and `app/tests/integration/`. Infrastructure code is split into reusable modules under `infra/modules/` and environment entrypoints under `infra/envs/dev/`.

## Build, Test, and Development Commands

Set up the Python environment with `python3.12 -m venv .venv`, `source .venv/bin/activate`, and `pip install "app/[dev]"`. Start local dependencies with `docker compose up -d`, then apply migrations from `app/` with `alembic upgrade head`. Run the API from the repo root with `uvicorn app.src.main:app --reload`. Key checks:

- `./.venv/bin/pytest app/tests/unit -v` runs fast unit tests.
- `./.venv/bin/pytest app/tests/integration -v` runs Docker-backed integration tests.
- `cd app && ruff check src/ tests/ && ruff format src/ tests/ && mypy src/` runs linting, formatting, and strict type checks.

## Coding Style & Naming Conventions

Target Python 3.12, 4-space indentation, and absolute imports such as `from app.src.core.config import settings`. Keep route handlers thin; put business rules in service classes and persistence in repositories. Repositories should flush but never commit. Use `ruff` for style enforcement, 100-character line length, and `mypy --strict` for type safety. Prefer descriptive snake_case module names like `secret_request_repository.py`.

## Testing Guidelines

Place unit tests in `app/tests/unit/` and integration tests in `app/tests/integration/`. Name files `test_<feature>.py`. Mock AWS and database boundaries in unit tests; use `testcontainers` for integration coverage. Aim for strong coverage on service and route layers, and add tests in the same change as the feature or bug fix.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, and `test:`. Keep commit subjects imperative and specific, for example `refactor: add repository layer`. Pull requests should describe the behavior change, note schema or Terraform impacts, link the relevant issue when available, and include API examples or screenshots when the change affects developer-facing workflows.

## Security & Configuration Tips

Do not commit real secrets. Use `.env.example` as the local template and prefer `AWS_ENDPOINT_URL` for LocalStack-based development. Follow the existing least-privilege Terraform approach and avoid wildcard IAM permissions.

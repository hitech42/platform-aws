# Developer Self-Service Platform API — Project Conventions

## Project Overview

This service lets internal dev teams self-serve platform requests without opening tickets. The first capability is **secret management**: teams request application secrets in AWS Secrets Manager, which flows through a lifecycle: `PENDING → APPROVED → PROVISIONING → PROVISIONED | FAILED`. Every state transition is written to a Postgres audit table so there is a full, immutable history of who requested what, who approved it, and when provisioning completed or failed. Future capabilities (service accounts, infra templates, etc.) will follow the same request-lifecycle pattern.

## Tech Stack

| Layer | Technology | Version |
|---|---|---|
| Runtime | Python | 3.12 |
| Framework | FastAPI | ≥0.111 |
| ORM | SQLAlchemy | 2.x |
| Migrations | Alembic | ≥1.13 |
| Settings | pydantic-settings | 2.x |
| Logging | structlog | ≥24 |
| AWS SDK | boto3 | ≥1.34 |
| Lint/format | ruff | ≥0.4 |
| Type check | mypy (strict) | ≥1.10 |
| Tests | pytest + pytest-asyncio | ≥8 / ≥0.23 |
| HTTP client (tests) | httpx | ≥0.27 |
| DB containers (tests) | testcontainers | ≥4.5 |
| Local AWS emulation | LocalStack | 3.x |

## Directory Layout

```
.                        ← project root (run uvicorn / alembic from here or app/)
├── app/
│   ├── src/             ← application source; import as app.src.*
│   │   ├── main.py      ← create_app() factory
│   │   ├── api/v1/      ← versioned routers; health routes mounted at root
│   │   ├── core/        ← config (pydantic-settings) + logging (structlog)
│   │   ├── db/          ← SQLAlchemy engine, session factory, Alembic migrations
│   │   ├── models/      ← SQLAlchemy ORM models (Base lives here)
│   │   ├── schemas/     ← Pydantic request/response schemas
│   │   └── services/    ← business logic; one module per domain
│   ├── tests/
│   │   ├── unit/        ← mock external deps (boto3, DB)
│   │   └── integration/ ← use testcontainers (Postgres + LocalStack)
│   ├── pyproject.toml
│   └── alembic.ini      ← run `alembic` from app/
└── docker-compose.yml   ← LocalStack; Postgres profile-gated (run natively for dev)
```

## Code Style

- **Formatter / linter**: `ruff` — run `ruff check . && ruff format .` before committing.
- **Type checker**: `mypy --strict` — all public functions must have full type annotations.
- **Imports**: absolute (`from app.src.core.config import settings`), never relative.
- **Commit messages**: Conventional Commits — `feat:`, `fix:`, `test:`, `docs:`, `chore:`, `refactor:`.

## Testing Conventions

- **Unit tests** (`tests/unit/`): fast, no I/O. Mock boto3 clients and DB sessions with `unittest.mock`.
- **Integration tests** (`tests/integration/`): use `testcontainers` to spin up real Postgres and LocalStack. Each test suite manages its own container lifecycle.
- **Asyncio**: `pytest-asyncio` with `asyncio_mode = "auto"` — all async test functions are discovered automatically.
- **Coverage target**: aim for ≥80 % on service and route layers; migrations and config are excluded.
- Write tests alongside new functionality — do not batch them into a separate PR.

## API Conventions

- All feature endpoints are versioned under `/api/v1/`.
- Health endpoints (`/healthz`, `/readyz`) are unversioned (mounted at root) for load-balancer compatibility.
- **Error response shape** (all 4xx/5xx):
  ```json
  {
    "error": {
      "code": "SECRET_NOT_FOUND",
      "message": "Human-readable description.",
      "field": "name"   // optional, for validation errors
    }
  }
  ```
- All request and response bodies must have a corresponding Pydantic schema in `app/src/schemas/`.
- Use `response_model=` on every route so OpenAPI output is always accurate.

## AWS / LocalStack Conventions

- Every `boto3` client must accept an optional `endpoint_url` sourced from `settings.aws_endpoint_url`. This ensures the same code path is used against LocalStack locally and real AWS in staging/prod.
- IAM: least-privilege only — no `"*"` actions or resources in Terraform policies.
- `DB_AUTH_MODE=iam` is the target for AWS deployments (RDS IAM auth via token). The `get_connect_args()` stub in `db/session.py` is the extension point.

## Updating This File

Update `CLAUDE.md` whenever a new convention is established, a technology version changes, or a new layer is added to the architecture. It should always reflect the current state of the project, not historical decisions (use `DECISIONS.md` for those).

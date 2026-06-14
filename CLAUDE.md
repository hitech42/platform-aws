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
- **`client` fixture** (`tests/integration/conftest.py`): use this instead of constructing `TestClient` manually. It overrides `get_db` to point at the testcontainers engine and clears overrides after each test. Secrets Manager calls must still be mocked with `unittest.mock.patch`.
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

### Implemented endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Liveness — always 200 |
| `GET` | `/readyz` | Readiness — 200 if DB reachable, 503 otherwise |
| `POST` | `/api/v1/services` | Register a service (201) |
| `GET` | `/api/v1/services` | List services — paginated (`page`, `page_size`) |
| `GET` | `/api/v1/services/{id}` | Get service by ID |
| `POST` | `/api/v1/services/{id}/secret-requests` | Create a secret request (PENDING) |
| `GET` | `/api/v1/secret-requests/{id}` | Get secret request by ID |
| `GET` | `/api/v1/secret-requests/{id}/events` | Audit trail for a request |
| `POST` | `/api/v1/secret-requests/{id}/approve` | Approve → provision → PROVISIONED or FAILED |

### Exception-handling pattern

Raise typed domain exceptions from the service layer; never raise `HTTPException` there. The global handler in `main.py` maps each subclass to its HTTP status code and error body:

```python
# app/src/core/exceptions.py
class AppError(Exception):          # base; status_code=500, code="INTERNAL_ERROR"
class NotFoundError(AppError):      # 404, code="NOT_FOUND"
class ConflictError(AppError):      # 409, code="CONFLICT"
class InvalidStateError(AppError):  # 409, code="INVALID_STATE"
class ValidationError(AppError):    # 422, code="VALIDATION_ERROR"
```

This keeps the service layer free of FastAPI imports and makes domain errors unit-testable without an HTTP client.

## Service Layer Conventions

- Service functions **flush but never commit** — the route handler commits and then refreshes the object to load any server-generated values (`created_at`, `updated_at`).
- The pattern is always: `service_fn(db, ...)` → `db.commit()` → `db.refresh(obj)` → `return schema.model_validate(obj)`.
- For operations that call an external service (Secrets Manager) after a DB state change, commit the intermediate DB state first so it is durable even if the external call fails.

## State Machine

`app/src/services/request_lifecycle.py` owns all status transitions:

```
PENDING → APPROVED → PROVISIONING → PROVISIONED
                                  ↘ FAILED
```

`VALID_TRANSITIONS` is a `dict[str, frozenset[str]]` that maps each status to the set of allowed next statuses. The `transition(db, request, new_status, actor, detail)` function:
1. Raises `InvalidStateError` if the transition is not in `VALID_TRANSITIONS`.
2. Updates `request.status` in place.
3. Inserts an immutable `RequestEvent` row (actor + detail + timestamp).
4. Calls `db.flush()` — does not commit.

The `approve` route commits twice: once after `PROVISIONING` (before the AWS call) and once after `PROVISIONED`/`FAILED`. Any exception from Secrets Manager is caught and written as a `FAILED` event rather than propagated as a 500.

## Secrets Manager Conventions

- Secret names follow `platform/{service_name}/{environment}/{logical_name}`.
- Only `generate_value=True` is supported; requests with `generate_value=False` are rejected with 422 at creation time.
- Random values are generated with `secrets.token_urlsafe(32)` — never logged.
- `create_app_secret` raises `ConflictError` on `ResourceExistsException` and re-raises all other `ClientError`s unchanged.

## AWS / LocalStack Conventions

- Every `boto3` client must accept an optional `endpoint_url` sourced from `settings.aws_endpoint_url`. This ensures the same code path is used against LocalStack locally and real AWS in staging/prod.
- IAM: least-privilege only — no `"*"` actions or resources in Terraform policies.
- `DB_AUTH_MODE=iam` is the target for AWS deployments (RDS IAM auth via token). The `get_connect_args()` stub in `db/session.py` is the extension point.

## Data Layer

### Tables

| Table | Purpose |
|---|---|
| `services` | Catalog of registered internal services/teams |
| `secret_requests` | One row per request to provision a secret; tracks current status |
| `request_events` | Immutable audit log — one row per status transition |

### `secret_requests.status` lifecycle

```
PENDING → APPROVED → PROVISIONING → PROVISIONED
                                  ↘ FAILED
```

Valid values (enforced by CHECK constraint): `PENDING`, `APPROVED`, `PROVISIONING`, `PROVISIONED`, `FAILED`.

### `secret_requests.environment`

Valid values (enforced by CHECK constraint): `dev`, `staging`, `prod`.  
Stored as `VARCHAR` with a CHECK constraint (not a PostgreSQL native ENUM type) so adding a new environment only requires `ALTER TABLE ... ADD CHECK / DROP CONSTRAINT`, avoiding the un-transactable `ALTER TYPE ... ADD VALUE` that native ENUMs require.

### UUID strategy

All primary keys use `sqlalchemy.Uuid` (SQLAlchemy 2.x portable type, resolves to native `UUID` on PostgreSQL/Aurora). Python-side `default=uuid.uuid4` generates the UUID at `session.flush()` time; `server_default=gen_random_uuid()` is a DDL fallback for raw-SQL inserts. **The UUID is `None` until the object is flushed** — this is expected SQLAlchemy column-default behaviour, not a bug.

### Integration test approach

Integration tests use `testcontainers[postgres]` to spin up an ephemeral Postgres container and run Alembic migrations against it. They are self-contained (no locally-running Postgres needed) and can run in any environment with Docker.

```bash
pytest app/tests/unit          # fast, no Docker
pytest app/tests/integration   # requires Docker
pytest app/tests               # both
```

The `conftest.py` in `app/tests/integration/` sets `script_location` to an absolute path so the tests work regardless of pytest invocation CWD.

## Updating This File

Update `CLAUDE.md` whenever a new convention is established, a technology version changes, or a new layer is added to the architecture. It should always reflect the current state of the project, not historical decisions (use `DECISIONS.md` for those).

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

Integration tests support two execution modes, selected by the `DATABASE_URL` environment variable:

- **Local dev** (`DATABASE_URL` not set): `testcontainers` spins up an ephemeral Postgres 16 container per test module. Requires Docker; does not touch a locally-running Postgres.
- **CI** (`DATABASE_URL` set): the external Postgres service container provided by GitHub Actions is used directly. testcontainers is bypassed entirely.

```bash
pytest app/tests/unit          # fast, no Docker
pytest app/tests/integration   # requires Docker (local dev path)
pytest app/tests               # both
DATABASE_URL=postgresql://... pytest app/tests/integration  # CI / external DB
```

The `conftest.py` in `app/tests/integration/` sets `script_location` to an absolute path so the tests work regardless of pytest invocation CWD. The conditional fixture definition at module level (`if os.environ.get("DATABASE_URL"): ... else: ...`) provides clean dual-mode support with different scopes: `session` for CI (migrations once per suite), `module` for local dev (fresh DB per test module).

## Observability

### Request logging

`app/src/core/middleware.py` contains `RequestLoggingMiddleware` (a `BaseHTTPMiddleware` subclass added last in `main.py`, so it wraps all other middleware). It emits one structured log event per request:

```json
{
  "event": "request",
  "method": "POST",
  "path": "/api/v1/secret-requests/…/approve",
  "status_code": 200,
  "duration_ms": 42,
  "secret_request_id": "…",   // present when path matches UUID pattern
  "from_status": "PENDING",   // present when approve route sets request.state
  "to_status": "PROVISIONED"  // present when approve route sets request.state
}
```

Health paths (`/healthz`, `/readyz`) are logged at `DEBUG` to suppress noise in CloudWatch when load-balancer health checks run every few seconds.

### Provisioning outcome events

The `approve` route emits a dedicated `secret_provisioning_outcome` log event after every Secrets Manager call so CloudWatch Logs metric filters can count successes and failures without parsing request logs:

```python
# success
log.info("secret_provisioning_outcome", outcome="provisioned", request_id=…, environment=…, arn=…)
# failure
log.warning("secret_provisioning_outcome", outcome="failed", request_id=…, environment=…, error=…)
```

Example CloudWatch Logs metric filter patterns:
- Success counter: `{ $.event = "secret_provisioning_outcome" && $.outcome = "provisioned" }`
- Failure alarm: `{ $.event = "secret_provisioning_outcome" && $.outcome = "failed" }`

**Do not implement actual CloudWatch API calls in application code** — metric filters on the log group are the ops-team's responsibility and keep the app free of CloudWatch SDK dependencies.

### structlog processor list stability

`configure_logging()` maintains a module-level `_PROCESSORS` list that is always cleared and repopulated **in place**. This is required because `structlog.testing.capture_logs()` modifies `get_config()["processors"]` in place, and `cache_logger_on_first_use=True` causes bound loggers to hold a reference to the list object passed at `configure()` time. If `configure_logging()` created a new list each call, cached loggers would hold a stale reference that `capture_logs()` would never modify.

## CI / GitHub Actions

`.github/workflows/app-ci.yml` triggers on pull requests that touch `app/**` or the workflow file itself. Three sequential jobs:

| Job | What runs | Docker required |
|---|---|---|
| `lint` | `ruff check` + `ruff format --check` + `mypy --strict src/` | No |
| `unit` | `pytest app/tests/unit` | No |
| `integration` | `pytest app/tests/integration` with Postgres 16 + LocalStack 3 service containers | Service containers (no Docker-in-Docker) |

The integration job passes `DATABASE_URL`, `AWS_ENDPOINT_URL`, and fake AWS credentials as environment variables; `conftest.py` picks up `DATABASE_URL` to bypass testcontainers.

To reproduce CI checks locally:
```bash
cd app/
ruff check . && ruff format --check . && mypy --strict src/
pytest tests/unit -v
pytest tests/integration -v   # uses testcontainers locally
```

## Infrastructure (Terraform)

### Tool versions

| Tool | Version |
|---|---|
| Terraform | ≥ 1.7 |
| AWS provider | ~> 5.0 |

### Module layout

```
infra/
├── bootstrap/          ← one-time manual apply; local backend; state stored in repo
│   ├── main.tf         ← S3 bucket + DynamoDB lock table
│   ├── variables.tf
│   └── outputs.tf
├── modules/
│   ├── network/        ← VPC, 4 subnets, IGW, security groups
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── tests/network.tftest.hcl
│   └── iam/            ← GitHub OIDC provider, deploy role, ECS task role shells
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── tests/iam.tftest.hcl
└── envs/
    └── dev/            ← root module wiring network + iam
        ├── backend.tf
        ├── providers.tf
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── terraform.tfvars
        └── tests/envs_dev.tftest.hcl
```

### Network topology

Each environment gets **4 subnets across 2 AZs** (see ADR-005):

| Subnet type | Count | Purpose | `map_public_ip_on_launch` |
|---|---|---|---|
| Public | 2 | ALB + ECS Fargate tasks | `true` |
| Private | 2 | Aurora Serverless v2 | `false` |

Internet isolation for Aurora is enforced by the **private route table** (no default route, no NAT Gateway). The `db` security group adds a defence-in-depth layer (port 5432 from `ecs_service_sg` only, no CIDR inbound).

ECS tasks run in public subnets without a NAT Gateway: they get public IPs and reach ECR / Secrets Manager / CloudWatch via the IGW directly. This is the trade-off for dev cost savings; staging/prod should add a NAT Gateway and move ECS to private subnets.

### IAM policy evolution

The GitHub Actions deploy role (`{project_name}-{environment}-github-deploy`) is built incrementally across sessions:

| Session | Permissions added |
|---|---|
| E1 (this session) | S3 + DynamoDB (state backend), EC2 VPC/subnet/SG/IGW/route-table, IAM OIDC + scoped role management |
| E2 | ECS, ECR, ALB, Secrets Manager |
| E3 | Aurora/RDS, KMS |
| E4 | CloudWatch Logs/metrics |

`ec2:Describe*` and VPC-mutate actions use `Resource: "*"` because EC2 does not support resource-level ARNs for Describe operations, and tag-based conditions require the resources to exist before the policy can reference them. Add tag-based conditions in staging/prod once VPC IDs are known (see TODO in `infra/modules/iam/main.tf`).

### Terraform tests

Tests live in a `tests/` subdirectory of the config they test (`terraform test` only discovers `.tftest.hcl` in the config directory or its `tests/` subdir).

All tests use `mock_provider "aws" {}` — no real AWS credentials required.

- **Network tests** (`command = plan`): fast; no resources are created.
- **IAM tests** (`command = apply`): required because `assume_role_policy` embeds a computed OIDC provider ARN; the value is unknown at plan time even with a mock provider.
- **Override `data.aws_availability_zones.available`**: every network test run must supply `override_data` with mock AZ names — the mock provider returns `null` for unset list attributes, which causes `element()` to panic.
- **`coalesce(value, [])`**: wrap mock-provider list attributes that may be `null` (e.g., `cidr_blocks`, `ipv6_cidr_blocks` on security group rules) before calling `length()`.

To run tests:

```bash
# Network module
cd infra/modules/network
terraform init -backend=false && terraform test

# IAM module
cd infra/modules/iam
terraform init -backend=false && terraform test

# envs/dev root module
cd infra/envs/dev
terraform init -backend=false && terraform test
```

### Terraform fmt and validate

Before committing any Terraform changes:

```bash
terraform -chdir=infra fmt -recursive -check   # must be clean
terraform -chdir=infra/envs/dev validate       # must succeed
```

## Updating This File

Update `CLAUDE.md` whenever a new convention is established, a technology version changes, or a new layer is added to the architecture. It should always reflect the current state of the project, not historical decisions (use `DECISIONS.md` for those).

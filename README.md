# Developer Self-Service Platform API

An internal FastAPI service that lets dev teams self-serve platform requests — starting with requesting and managing application secrets in AWS Secrets Manager — with a full audit trail stored in Postgres. Built for deployment on ECS Fargate + Aurora Serverless v2, with LocalStack for local AWS emulation.

## Status

**Core API implemented.** The full secret-request lifecycle is operational:

- Service catalog (register/list/get teams and services)
- Secret-request lifecycle (`PENDING → APPROVED → PROVISIONING → PROVISIONED | FAILED`)
- Immutable audit trail (one event row per state transition)
- AWS Secrets Manager provisioning via `approve` endpoint
- 123 tests passing (unit + integration via testcontainers)
- GitHub Actions CI on every PR (lint, unit, integration)

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Python | 3.12+ | Tested with 3.12 |
| PostgreSQL | 14+ | Running natively on `localhost:5432` |
| Docker | 24+ | For LocalStack only |
| Docker Compose | v2 | Bundled with Docker Desktop |

## Setup

### 1. Create and activate a virtual environment

```bash
python3.12 -m venv .venv
source .venv/bin/activate
```

### 2. Install dependencies

```bash
pip install --upgrade pip
pip install "app/[dev]"
```

### 3. Configure environment

```bash
cp .env.example .env
# Edit .env if your local Postgres credentials differ from the defaults.
```

### 4. Create the local database

```bash
psql -U postgres -c "CREATE USER app WITH PASSWORD 'localdev';"
psql -U postgres -c "CREATE DATABASE platform OWNER app;"
```

### 5. Start LocalStack (for AWS Secrets Manager emulation)

```bash
docker compose up -d localstack
# Wait for LocalStack to report healthy:
docker compose ps
```

### 6. Run database migrations

```bash
cd app/
alembic upgrade head
cd ..
```

To roll back all migrations:
```bash
cd app/ && alembic downgrade base && cd ..
```

### 7. Run the application

```bash
uvicorn app.src.main:app --reload
```

The API is available at `http://localhost:8000`.

- Swagger UI: `http://localhost:8000/docs`
- ReDoc: `http://localhost:8000/redoc`

### 8. Verify health endpoints

```bash
curl -s http://localhost:8000/healthz | python3 -m json.tool
# {"status": "ok"}

curl -s http://localhost:8000/readyz | python3 -m json.tool
# {"status": "ok"}
```

## API Reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Liveness probe — always 200 |
| `GET` | `/readyz` | Readiness probe — 200 if DB reachable, 503 otherwise |
| `POST` | `/api/v1/services` | Register a service |
| `GET` | `/api/v1/services` | List services (query params: `page`, `page_size`) |
| `GET` | `/api/v1/services/{id}` | Get a service by ID |
| `POST` | `/api/v1/services/{id}/secret-requests` | Create a secret request |
| `GET` | `/api/v1/secret-requests/{id}` | Get a secret request |
| `GET` | `/api/v1/secret-requests/{id}/events` | Audit trail for a request |
| `POST` | `/api/v1/secret-requests/{id}/approve` | Approve and provision the secret |

All error responses use the standard shape:
```json
{ "error": { "code": "NOT_FOUND", "message": "...", "field": "id" } }
```

Interactive docs (Swagger UI and ReDoc) are available at `/docs` and `/redoc` when the server is running.

## Running Tests

```bash
# Unit tests only — fast, no Docker required
.venv/bin/pytest app/tests/unit -v

# Integration tests — requires Docker (testcontainers spins up Postgres automatically)
.venv/bin/pytest app/tests/integration -v

# Full suite
.venv/bin/pytest app/tests -v
```

> Secrets Manager calls are mocked in integration tests. To test against a real LocalStack
> instance, start it with `docker compose up -d localstack` and set `AWS_ENDPOINT_URL=http://localhost:4566` in `.env`.

## Linting & Type Checking

```bash
cd app/
ruff check src/ tests/
ruff format src/ tests/
mypy src/
```

## CI

GitHub Actions runs three jobs on every PR that touches `app/**`:

1. **Lint & typecheck** — ruff + mypy
2. **Unit tests** — fast, no Docker
3. **Integration tests** — Postgres 16 and LocalStack 3 via service containers; testcontainers is bypassed in CI (the workflow sets `DATABASE_URL`)

To reproduce CI locally from the repo root:
```bash
cd app/
ruff check . && ruff format --check . && mypy --strict src/
pytest tests/unit -v
pytest tests/integration -v   # uses testcontainers; requires Docker
```

## IntelliJ / PyCharm

Mark `app/src/` as a **Sources Root** (right-click → Mark Directory as → Sources Root). Set the project root as a content root so `app.src.*` imports resolve correctly without needing to set `PYTHONPATH` manually.

## Infrastructure Setup (Terraform)

> **Prerequisite**: Terraform ≥ 1.7 installed. The AWS CLI must be configured with credentials that have enough permissions to create S3 buckets, DynamoDB tables, VPCs, and IAM roles.

### Step 1 — Bootstrap remote state

The bootstrap module creates the S3 bucket and DynamoDB table that all other Terraform state will use. It uses a **local backend** because the state bucket doesn't exist yet. Run it once per AWS account.

```bash
cd infra/bootstrap/

terraform init
terraform plan -var="project_name=cvs-platform"
# Review the plan — it creates an S3 bucket and a DynamoDB table only.
terraform apply -var="project_name=cvs-platform"
```

Note the two outputs — you'll need them in the next step:

```
state_bucket_name     = "cvs-platform-tfstate-<account-id>"
state_lock_table_name = "cvs-platform-tfstate-lock"
```

Commit the generated `infra/bootstrap/terraform.tfstate` — it is intentionally not gitignored.

### Step 2 — Fill in backend.tf and terraform.tfvars

Edit `infra/envs/dev/backend.tf` and replace the placeholder with the bootstrap output:

```hcl
bucket = "cvs-platform-tfstate-<account-id>"
```

State locking uses S3 native locking (`use_lockfile = true`) — no DynamoDB entry needed here.

Edit `infra/envs/dev/terraform.tfvars` and replace the `REPLACE_WITH_*` placeholders:

```hcl
github_org        = "your-org"
github_repo       = "your-repo"
state_bucket_name = "cvs-platform-tfstate-<account-id>"
```

If the GitHub OIDC provider already exists in this account (from another project), set `create_oidc_provider = false`.

### Step 3 — Init and plan envs/dev

```bash
cd infra/envs/dev/

terraform init   # downloads providers, configures S3 backend
terraform plan
```

**What to look for in the plan output:**

- `Plan: N to add, 0 to change, 0 to destroy` — no unexpected destroys.
- Resources created should include: `aws_vpc`, 2× `aws_subnet` (public), 2× `aws_subnet` (private), `aws_internet_gateway`, 2× `aws_route_table`, 4× `aws_route_table_association`, 3× `aws_security_group`, `aws_iam_openid_connect_provider` (if `create_oidc_provider = true`), 3× `aws_iam_role`, 1× `aws_iam_role_policy`.
- No resources touching ECS, Aurora, ALB, or CloudWatch — those come in later sessions.

### Step 4 — Apply (manual, after reviewing the plan)

```bash
terraform apply
```

After apply, note the outputs — you'll wire them into the CI workflow (E2) and Aurora config (E3):

```
vpc_id                     = "vpc-..."
public_subnet_ids          = ["subnet-...", "subnet-..."]
private_subnet_ids         = ["subnet-...", "subnet-..."]
alb_sg_id                  = "sg-..."
ecs_service_sg_id          = "sg-..."
db_sg_id                   = "sg-..."
github_actions_role_arn    = "arn:aws:iam::...:role/cvs-platform-dev-github-deploy"
ecs_task_execution_role_arn = "arn:aws:iam::...:role/cvs-platform-dev-ecs-task-execution"
ecs_task_role_arn           = "arn:aws:iam::...:role/cvs-platform-dev-ecs-task"
```

### Running Terraform tests (no AWS credentials needed)

```bash
cd infra/modules/network && terraform init -backend=false && terraform test
cd infra/modules/iam    && terraform init -backend=false && terraform test
cd infra/envs/dev       && terraform init -backend=false && terraform test
```

All tests use `mock_provider "aws" {}`.

---

## Docker (optional)

```bash
docker build -f app/Dockerfile -t cvs-platform-api app/
docker run --rm -p 8000:8000 --env-file .env cvs-platform-api
```

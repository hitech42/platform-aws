# Developer Self-Service Platform API

An internal FastAPI service that lets dev teams self-serve platform requests — starting with requesting and managing application secrets in AWS Secrets Manager — with a full audit trail stored in Postgres. Built for deployment on ECS Fargate + RDS PostgreSQL (db.t4g.micro), with LocalStack for local AWS emulation.

**Implemented**

- Core Challenge: Self-service for engineering teams to request, approve, and retreieve the application secrets in AWS Secrets Manager
  - AI-Native Development using Claude Code
  - Terraform CI/CD with reusable modules, tests, and using SSM and Secrets Manager
  - No wildcard policies
  - ECS Fargate service exposed via load balancer, resides inside VPC
  - Documented with README.md, DECISIONS.md, CLAUDE.md
- Option 3: Show Off Dev Skills in Your App
  - Built with Python and Postgres
  - IAM authentication for Postgres
  - Input validation
  - Health check endpoints
  - Observability metrics via CloudWatch with SNS/Email alarms: memory, CPU, storage, ALB P95 latency, ALB 5xx errors, cost, secret provisioning errors, RDS connections etc.
- Some of Option 1: More Complex Terraform
  - Everything is split in modules: data, ECS Service, IAM, KMS, network, observability
- Some of Option: 2 Show Off AI Maturity
  - A Summary endpoint that narrates risk facts
  - Uses either AWS Bedrock or native Anthropic API depending on availability, utilizing hot-switch via DB config with no redeploy

**Left several PRs open**

  - Staging environment via Terraform
  - Correction of ECS memory alarm metric in Terraform
  - Intentionally bad code to showcase: resolve ECS task definition image placeholder via SSM Parameter Store

## Status

**Core API implemented.** The full secret-request lifecycle is operational:

- Service catalog (register, list, and look up services)
- Secret-request lifecycle (`PENDING → APPROVED → PROVISIONING → PROVISIONED | FAILED`)
- Immutable audit trail (one event row per state transition)
- AWS Secrets Manager provisioning via `approve` endpoint
- AI-powered request summary (`GET /summary`) — deterministic risk facts + LLM narrative (Bedrock or Anthropic API, runtime-switchable via DB config, no redeploy)
- 175 tests passing (unit + integration via testcontainers)
- GitHub Actions CI on every PR (lint, unit, integration)

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Python | 3.12+ | Tested with 3.12 |
| Docker | 24+ | For LocalStack and Postgres (both containerised) |
| Docker Compose | v2 | Bundled with Docker Desktop |

## Roadmap / Work in Progress
- Staging environment (E5)

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
# Default credentials in .env.example match the Docker Compose services — no edits needed for local dev.
```

### 4. Start services (Postgres + LocalStack)

```bash
docker compose up -d
# Wait for both services to report healthy:
docker compose ps
```

### 5. Run database migrations

```bash
cd app/
alembic upgrade head
cd ..
```

To roll back all migrations:
```bash
cd app/ && alembic downgrade base && cd ..
```

### 6. Run the application

```bash
uvicorn app.src.main:app --reload
```

The API is available at `http://localhost:8000`.

- Swagger UI: `http://localhost:8000/docs`
- ReDoc: `http://localhost:8000/redoc`

### 7. Verify health endpoints

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
| `GET` | `/api/v1/secret-requests/{id}/summary` | Deterministic risk facts + LLM narrative |

> **`/summary` providers**: the active LLM provider is read from the `config` table (`key = 'llm_provider'`). Switch at runtime without a restart — change takes effect within 30 seconds:
> ```sql
> -- switch to Bedrock (default on AWS)
> UPDATE config SET value = 'bedrock' WHERE key = 'llm_provider';
> -- switch to Anthropic API (requires ANTHROPIC_API_KEY env var in local dev)
> UPDATE config SET value = 'anthropic_api' WHERE key = 'llm_provider';
> ```
> In local dev with `AWS_ENDPOINT_URL` set, the Bedrock provider returns a labeled `[stub]` (LocalStack has no Bedrock). The `anthropic_api` provider calls the real Anthropic API — set `ANTHROPIC_API_KEY` in `.env` to use it. The `facts` block is always computed from Postgres regardless of which provider is active or whether it fails.

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

> **Prerequisite**: Terraform ≥ 1.10 and AWS CLI ≥ 2.x installed. The AWS CLI must be configured with credentials that have sufficient permissions (see IAM module outputs for the deploy role ARN).

### Step 1 — Bootstrap remote state

The bootstrap module creates the S3 bucket that all other Terraform state will use. It uses a **local backend** because the state bucket doesn't exist yet. Run it once per AWS account.

```bash
cd infra/bootstrap/

terraform init
terraform plan -var="project_name=cvs-platform"
# Review the plan — it creates one S3 bucket only.
terraform apply -var="project_name=cvs-platform"
```

Note the output — you'll need it in the next step:

```
state_bucket_name = "cvs-platform-tfstate-<region>-<random-id>"
```

Commit the generated `infra/bootstrap/terraform.tfstate` — it is intentionally not gitignored.

### Step 2 — Fill in backend.tf and terraform.tfvars

Edit `infra/envs/dev/backend.tf` and replace the placeholder with the bootstrap output:

```hcl
bucket = "cvs-platform-tfstate-<region>-<random-id>"
```

State locking uses S3 native locking (`use_lockfile = true`) — no DynamoDB entry needed here.

Edit `infra/envs/dev/terraform.tfvars` and replace the `REPLACE_WITH_*` placeholders:

```hcl
github_org        = "your-org"
github_repo       = "your-repo"
state_bucket_name = "cvs-platform-tfstate-<region>-<random-id>"
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
- Expected resource types: VPC (subnets, IGW, route tables, security groups), IAM (OIDC provider, roles, policies), KMS key + alias, RDS PostgreSQL instance + subnet group, ECS cluster + service + task definition, ECR repository, ALB + listener + target group, CloudWatch log group, SNS billing alarm, SNS alerts topic + email subscription, 9 CloudWatch metric alarms, 1 CloudWatch Logs metric filter, CloudWatch dashboard.

> **Cost notice**: The KMS key ($1/month), RDS db.t4g.micro instance (~$14/month after the 12-month free tier), and ALB (~$16/month at baseline) begin accruing cost from the moment of apply, even with zero traffic. A CloudWatch billing alarm is included in this plan.

### Step 4 — Apply (manual, after reviewing the plan)

```bash
terraform apply
```

After apply, note these key outputs:

```
vpc_id                      = "vpc-..."
public_subnet_ids           = ["subnet-...", "subnet-..."]
github_actions_role_arn     = "arn:aws:iam::...:role/cvs-platform-dev-github-deploy"
ecs_task_execution_role_arn = "arn:aws:iam::...:role/cvs-platform-dev-ecs-task-execution"
ecs_task_role_arn           = "arn:aws:iam::...:role/cvs-platform-dev-ecs-task"
db_endpoint                 = "cvs-platform-dev.xxxx.us-east-1.rds.amazonaws.com"
db_resource_id              = "db-XXXXX"
kms_key_arn                 = "arn:aws:kms:us-east-1:...:key/..."
ecr_repository_url          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/cvs-platform-dev"
ecs_cluster_name            = "cvs-platform-dev"
ecs_service_name            = "cvs-platform-dev"
alb_dns_name                = "cvs-platform-dev-alb-xxxx.us-east-1.elb.amazonaws.com"
alerts_topic_arn            = "arn:aws:sns:us-east-1:...:cvs-platform-dev-alerts"
dashboard_url               = "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=CVSPlatformDev"
```

### Step 5 — Bootstrap the IAM database user (one-time, after first apply)

After the RDS instance is running, create the application Postgres user, grant it the
`rds_iam` role so the app can authenticate via IAM token (no password ever set), and grant
it `CREATE`/`USAGE` on the `public` schema (PostgreSQL 15+ no longer grants this to `PUBLIC`
by default — without it, Alembic's first migration fails with "permission denied for schema
public").

Standard RDS (unlike Aurora) has no Data API, so this connects via `psql` and **requires TCP
access to port 5432 from within the VPC** — an EC2 bastion, SSM port forwarding, or a one-off
ECS Fargate task in the same VPC.

```bash
# From the repo root, run from a host with VPC network access:
bash infra/scripts/setup-db-user.sh
```

The script reads Terraform outputs automatically (db endpoint, master secret ARN, db name, username).

**Prerequisites**: `aws` CLI ≥ 2.x, `psql`, `jq`; IAM permission `secretsmanager:GetSecretValue`
on the master secret ARN (`rds!*` namespace).

Re-run this script if the RDS instance is ever destroyed and recreated. It is idempotent —
running it when the user already exists is safe.

### Step 6 — Confirm SNS email subscriptions (after first apply)

After `terraform apply`, AWS sends a confirmation email to the address in `alert_email` (from `terraform.tfvars`) for both the billing alarm topic and the operational alerts topic. **Alarms that fire before confirmation are silently dropped.**

Confirm both subscriptions immediately by clicking the links in the two emails with subject `AWS Notification - Subscription Confirmation`.

To verify subscription status:
```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=infra/envs/dev output -raw alerts_topic_arn)"
```

The `SubscriptionArn` field should show the full ARN (not `PendingConfirmation`).

### Running Terraform tests (no AWS credentials needed)

```bash
cd infra/modules/network      && terraform init -backend=false && terraform test
cd infra/modules/iam          && terraform init -backend=false && terraform test
cd infra/modules/kms          && terraform init -backend=false && terraform test
cd infra/modules/data         && terraform init -backend=false && terraform test
cd infra/modules/observability && terraform init -backend=false && terraform test
cd infra/envs/dev             && terraform init -backend=false && terraform test
```

All 33 tests use `mock_provider "aws" {}` — no real AWS credentials required.

### Observability

After apply, the following observability resources are active:

**CloudWatch Alarms** — all routed to `cvs-platform-dev-alerts` SNS topic:

| Alarm | Namespace | Threshold |
|---|---|---|
| `cvs-platform-dev-ecs-cpu-high` | `AWS/ECS` | CPU > 80% for 10 min |
| `cvs-platform-dev-ecs-memory-high` | `ECS/ContainerInsights` | Memory > 80% for 10 min |
| `cvs-platform-dev-rds-cpu-high` | `AWS/RDS` | CPU > 80% for 10 min |
| `cvs-platform-dev-rds-storage-low` | `AWS/RDS` | Free storage < 2 GiB |
| `cvs-platform-dev-rds-connections-high` | `AWS/RDS` | Connections > 20 for 10 min |
| `cvs-platform-dev-alb-5xx-high` | `AWS/ApplicationELB` | 5xx count > 10 per 5 min |
| `cvs-platform-dev-alb-latency-p95-high` | `AWS/ApplicationELB` | p95 latency > 2s for 10 min |
| `cvs-platform-dev-alb-no-healthy-hosts` | `AWS/ApplicationELB` | Healthy hosts < 1 (60s period) |
| `cvs-platform-dev-secret-provisioning-failures` | `CVSPlatform/Application` | Any failure (≥ 1 per 5 min) |

**CloudWatch Dashboard** — `CVSPlatformDev`:  
Open via the `dashboard_url` Terraform output or navigate to CloudWatch → Dashboards in the AWS console.

**CloudWatch Logs metric filter** — counts `secret_provisioning_outcome` failure events in `/ecs/cvs-platform-dev` and emits to `CVSPlatform/Application` custom namespace.

### Tearing Down Infrastructure

**Order matters** — destroy envs/dev before bootstrap, and delete secrets manually before the KMS key is destroyed (Secrets Manager holds a reference to the CMK).

```bash
# 1. Delete any secrets created by the app (they hold a reference to the KMS key)
aws secretsmanager list-secrets --filters Key=name,Values=platform/ \
  --query 'SecretList[*].ARN' --output text | \
  xargs -n1 aws secretsmanager delete-secret --force-delete-without-recovery --secret-id

# 2. Destroy all envs/dev resources (RDS, ECS, ALB, alarms, dashboard, etc.)
terraform -chdir=infra/envs/dev destroy

# 3. Destroy bootstrap state bucket (only after all other state is removed)
terraform -chdir=infra/bootstrap destroy -var="project_name=cvs-platform"
```

> The RDS instance has `deletion_protection = false` and `skip_final_snapshot = true` in dev — it will be deleted immediately without a snapshot. Change these in staging/prod.

---

## Docker (optional)

```bash
docker build -f app/Dockerfile -t cvs-platform-api app/
docker run --rm -p 8000:8000 --env-file .env cvs-platform-api
```

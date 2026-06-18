# Architecture Decision Records

---

## ADR-001: Local Development Strategy — Native Postgres + LocalStack + Native App Process

**Date**: 2026-06-13
**Status**: Accepted

### Context

Local dev environments for services with AWS and database dependencies can be run in two broad modes:

1. **Fully containerised**: the app process, Postgres, and LocalStack all run in Docker Compose. The developer connects to the running container or uses remote debug.
2. **Hybrid native**: Postgres runs natively on the developer's machine, LocalStack runs in Docker for AWS emulation, and the app process runs natively (e.g., launched directly from IntelliJ).

### Decision

We use the **hybrid native** approach: Postgres runs natively on `localhost:5432`, LocalStack runs in Docker (port 4566), and the FastAPI app runs as a native process.

The `docker-compose.yml` includes a commented-out / profile-gated Postgres service for reproducibility — any contributor who cannot install Postgres natively can opt in with `--profile postgres`. LocalStack is always in Docker because the LocalStack team ships only a Docker image.

### Rationale

- **Debugger attach**: IntelliJ's Python debugger (`pydevd`) attaches to a local process with zero friction. Attaching to an in-container process requires Docker debug ports, SSH tunnels, or remote-interpreter setup — all meaningful extra configuration.
- **Hot reload speed**: `uvicorn --reload` with a native process has lower latency than bind-mount reload inside Docker, especially on macOS where Docker filesystem events are slower.
- **Simplicity**: fewer moving parts for the common case (one developer, one machine). The developer does not need Docker to be running just to iterate on application logic.
- **Parity with CI**: CI runs tests against real Postgres (via testcontainers) and LocalStack (via testcontainers or a service container), so the test suite catches any local/CI divergence regardless of how local Postgres is run.

### Trade-offs

- **Onboarding friction**: a new contributor must install Postgres natively, which is a few extra steps compared to `docker compose up`. Mitigated by documenting the `--profile postgres` opt-in and providing a one-liner to create the `app` user and `platform` database.
- **Version drift**: a developer with a different Postgres minor version could see different behaviour. Mitigated by specifying the target version in CI and in the commented-out Docker service (`postgres:16-alpine`).
- **Windows**: native Postgres on Windows has more gotchas than macOS/Linux. Accepted risk — the primary dev target is macOS.

---

## ADR-002: Synchronous SQLAlchemy Engine and Session

**Date**: 2026-06-14
**Status**: Accepted

### Context

FastAPI is built on asyncio and supports both synchronous (`def`) and asynchronous (`async def`) route handlers. SQLAlchemy 2.x ships both a synchronous and an asynchronous API (`AsyncSession` / `create_async_engine`). The choice between them has implications for driver selection, testability, and concurrency model.

### Decision

Use the **synchronous** SQLAlchemy engine (`create_engine`) and session (`Session`) with synchronous `def` route handlers. The database driver is `psycopg2`.

### Rationale

- **Internal tool, low concurrency**: this service handles infrequent self-service requests from internal teams, not high-throughput public traffic. A thread pool is more than sufficient.
- **FastAPI compensates correctly**: `def` route handlers are automatically run in a thread pool executor (`asyncio.run_in_executor`), so blocking DB calls do not block the event loop. The behaviour is correct without requiring async machinery.
- **boto3 is synchronous**: boto3 has no native async support. Switching to `AsyncSession` would make DB calls non-blocking but leave Secrets Manager calls blocking on the event loop — partial async with no full benefit.
- **Simpler code and tests**: no `async`/`await` through the service layer, no `AsyncSession` context managers, no `asyncpg` driver quirks. Unit tests mock a plain `Session` with `unittest.mock.MagicMock`.

### Migration path if async becomes necessary

1. Swap `psycopg2-binary` → `asyncpg` in `pyproject.toml`.
2. Replace `create_engine` / `sessionmaker` / `Session` with `create_async_engine` / `async_sessionmaker` / `AsyncSession` in `db/session.py`.
3. Change `get_db` to an `async` generator yielding `AsyncSession`.
4. Add `await` to all DB execute calls in the service layer.
5. Swap `boto3` → `aioboto3` in `services/secrets_manager.py`.
6. Change route handlers to `async def`.

The service layer and route structure do not change shape — only the DB and AWS call mechanics change.

### Trade-offs

- **Thread pool overhead**: under very high concurrency, spinning up threads per request is less efficient than cooperative async I/O. Not a concern at current scale.
- **Mixed sync/async risk**: if a future developer adds `async def` routes and inadvertently calls sync SQLAlchemy directly (without a thread pool), it will block the event loop silently. Code review must catch this if async routes are ever introduced.

---

## ADR-003: Row-level Locking for the Approve Endpoint

**Date**: 2026-06-14
**Status**: Accepted

### Context

The `POST /secret-requests/{id}/approve` endpoint reads the current status, validates the transition, updates the row, and then calls Secrets Manager. Under concurrent requests (e.g., two approvers clicking "approve" at the same time), a naive read-then-write would result in a race: both requests could read `PENDING`, both pass the state check, and both call Secrets Manager — creating a duplicate secret and two `PROVISIONING` events.

### Decision

`secret_requests_svc.get_request` accepts an optional `for_update=True` parameter. When set, the SQLAlchemy query adds `.with_for_update()`, which emits `SELECT … FOR UPDATE`. This acquires a row-level exclusive lock for the duration of the transaction. The second concurrent request blocks at the lock and resumes after the first commits. At that point the row's status is `PROVISIONING`, the state machine rejects `PENDING → APPROVED`, and the route returns 409.

### Rationale

- **Correctness with minimal complexity**: `SELECT FOR UPDATE` is supported by all Postgres versions we target (14+) with no schema changes. The state machine then acts as a second safety net — even without the lock, a `PENDING → APPROVED` transition is only allowed once.
- **No NOWAIT**: we deliberately omit `NOWAIT` so the second request blocks and waits for the first to commit rather than immediately failing. Approve operations are infrequent and human-initiated; the brief wait (milliseconds in practice) is preferable to a spurious error that forces the user to retry.
- **No optimistic locking**: a version column would require an extra migration and client-side retry logic. Pessimistic locking on a single row is simpler and appropriate for a low-throughput internal tool.

### Trade-offs

- **Lock contention**: if the Secrets Manager call hangs, the lock is held for the duration. Acceptable because (1) approvals are rare, (2) Secrets Manager has its own timeout, and (3) a stuck approve is better than double-provisioning.
- **Deadlock risk**: the approve route only ever locks one row at a time, so deadlock is not possible.

---

## ADR-004: Dual-mode Integration Tests (testcontainers vs GitHub Actions service containers)

**Date**: 2026-06-14
**Status**: Accepted

### Context

Integration tests need a real Postgres database. Two approaches exist for providing one:

1. **testcontainers**: the test suite spins up an ephemeral Docker container on demand. Works anywhere Docker is available; requires Docker-in-Docker or privileged mode in CI.
2. **GitHub Actions service containers**: the workflow declares Postgres as a service container before the job steps run. Available immediately when steps start; no Docker-in-Docker needed; faster startup.

### Decision

Support both modes via a single `conftest.py` that branches on the `DATABASE_URL` environment variable:

- **Local dev** (`DATABASE_URL` unset): `testcontainers` spins up `postgres:16-alpine`, scope `module` (fresh DB per test module for strong isolation).
- **CI** (`DATABASE_URL` set by the workflow): the service container is used directly, scope `session` (migrations run once per suite since the container is already running and shared).

The branch uses Python-level `if/else` at module load time so the fixture is defined with the correct scope before pytest collects tests.

### Rationale

- **Local dev requires zero setup**: contributors need only Docker; no local Postgres required.
- **CI avoids Docker-in-Docker**: GitHub Actions service containers run as sibling containers, not nested Docker. This is simpler, faster, and more reliable than `testcontainers` inside a CI job.
- **Single test file**: the same test files run in both modes with no conditional logic inside tests themselves.

### Trade-offs

- **Two scopes in the same codebase**: `module` vs `session` scope means isolation characteristics differ between local dev and CI. A test that leaks state across modules would pass locally but fail in CI (or vice versa). Mitigated by the rollback-after-each-test pattern in `db_session`.
- **Environment variable coupling**: forgetting to set `DATABASE_URL` in a new CI job would silently fall back to testcontainers, which fails if Docker-in-Docker is not available. The workflow sets the variable explicitly to prevent this.

---

## ADR-005: 4-Subnet Network Topology (2 Public + 2 Private)

**Date**: 2026-06-14
**Status**: Accepted

### Context

Each environment needs subnets for at least three tiers: load balancer (public), compute (ECS Fargate), and database (Aurora). The question is how many subnets to provision and which tiers share them.

Two layouts were considered:

1. **2 public subnets only**: ALB, ECS tasks, and Aurora all in the same public subnets. Simpler and cheaper; security group rules still restrict DB access. Unsuitable because Aurora Serverless v2 requires two private subnets (it will not launch in public subnets in a multi-AZ config).
2. **4 subnets (2 public + 2 private), no NAT Gateway**: public subnets for ALB + ECS, private subnets for Aurora. ECS tasks get public IPs and egress via the IGW directly.

### Decision

Use **4 subnets (2 public + 2 private) across 2 AZs**. No NAT Gateway in dev.

### Rationale

- **Aurora placement**: Aurora Serverless v2 requires at least two subnets in different AZs. The subnets must be in a DB subnet group; keeping them private (no default route) is the standard pattern.
- **Cost**: A NAT Gateway costs ~$32/month plus data-transfer fees. For a dev environment with low traffic, this is eliminated by running ECS tasks in public subnets with public IPs. ECS tasks can reach ECR, Secrets Manager, and CloudWatch via the IGW.
- **Security**: Aurora is isolated in private subnets whose route table has no default route (no internet egress, no internet ingress path). The `db_sg` security group adds port 5432 from `ecs_service_sg` only as a second layer.
- **High availability**: 2 AZs is sufficient for dev. The module uses `data.aws_availability_zones.available` to select AZs dynamically rather than hardcoding region-specific names.

### Trade-offs

- **ECS tasks have public IPs**: any security group misconfiguration that opens inbound ports would expose ECS tasks directly. Mitigated by `ecs_service_sg` (inbound from `alb_sg` only on the app port). Staging and prod should add a NAT Gateway and place ECS tasks in private subnets.
- **Aurora egress**: Aurora in private subnets with no NAT cannot reach the internet. This is intentional — RDS/Aurora does not need internet egress. IAM auth tokens are generated client-side.

### Migration to NAT Gateway (for staging/prod)

Add `aws_eip` + `aws_nat_gateway` in a public subnet, add a default route `0.0.0.0/0 → NAT` to the private route table, and move ECS task subnets to private. ECS tasks no longer need `map_public_ip_on_launch = true`.

---

## ADR-006: HTTP-only ALB in Dev (no HTTPS)

**Date**: 2026-06-14
**Status**: Accepted

### Context

Production and staging ALBs must use HTTPS (TLS termination at the ALB). Setting up HTTPS requires a domain name registered in Route 53 and an ACM certificate validated against it. For a dev environment that is accessed only via the ALB DNS name or internal tooling, this is unnecessary ceremony.

### Decision

The `alb_sg` security group in the network module opens **port 80 (HTTP) only** in dev. HTTPS (port 443) is not opened and no ACM certificate is provisioned.

### Rationale

- **No domain name yet**: the dev environment has no Route 53 hosted zone. ACM certificate validation via DNS requires a hosted zone to exist. Provisioning one adds cost and complexity that is not justified before the service is functional.
- **Internal use only**: dev is accessed by engineers running tests or demos, not by end users or external systems. HTTP is acceptable in this context.
- **Deferred, not permanent**: HTTPS is the right target for staging/prod. The `alb_sg` module variable `alb_ingress_port` (to be added in E2 with the actual ALB resource) will accept 443 in staging/prod.

### Trade-offs

- **Plaintext traffic**: credentials or tokens in HTTP request/response bodies are transmitted unencrypted. Acceptable in dev because traffic stays within the VPC or developer's machine; mitigated by not routing dev through the public internet for sensitive operations.
- **Behaviour gap**: the dev environment does not perfectly mirror staging/prod. Any bug related to TLS termination, HTTPS redirects, or certificate validation would not surface in dev.

---

## ADR-007: SSE-S3 Encryption for Bootstrap State Bucket

**Date**: 2026-06-14
**Status**: Accepted

### Context

The Terraform state S3 bucket must be encrypted at rest. Two AWS-native options are available:

1. **SSE-S3**: encryption keys managed entirely by S3. No additional cost; no key management overhead.
2. **SSE-KMS**: encryption keys managed in AWS KMS. Enables key rotation, key policy auditing, and cross-account access patterns. Costs ~$1/month per CMK plus per-request fees.

### Decision

Use **SSE-S3** (`AES256`) for the bootstrap state bucket.

### Rationale

- **No application KMS key exists yet**: creating a dedicated KMS CMK for Terraform state would be a separate bootstrapping step. The CMK itself would then need its own state, creating a circular dependency.
- **IAM already controls access**: the S3 bucket has `block_public_access` enabled and access is controlled entirely by IAM policies (only the GitHub Actions deploy role and the human operator have access). SSE-S3 satisfies the encryption-at-rest requirement without adding a second access-control layer.
- **No independent security benefit**: SSE-KMS adds value when the KMS key policy is used to grant access separately from the S3 bucket policy (e.g., cross-account, or when IAM is not sufficient). Neither scenario applies here.
- **Upgrade path**: S3 allows switching the default encryption from SSE-S3 to SSE-KMS at any time without object migration — new objects use the new default; existing objects are re-encrypted on next write.

### Trade-offs

- **No KMS audit trail**: CloudTrail does not record SSE-S3 key use (there are no KMS API calls). SSE-KMS would provide per-request audit visibility. Accepted — S3 access logs and CloudTrail S3 data events are sufficient for this use case.
- **No key rotation control**: SSE-S3 key rotation is managed by AWS and is not configurable. SSE-KMS CMKs can be rotated on a custom schedule. Accepted at this stage.

---

## ADR-008: Aurora PostgreSQL Serverless v2 for the Application Database

**Date**: 2026-06-14
**Status**: Superseded by [ADR-012](#adr-012-standard-rds-postgresql-instead-of-aurora-serverless-v2)

### Context

The application needs a managed relational database (PostgreSQL). Options considered:

1. **RDS PostgreSQL (provisioned)**: always-on, fixed instance size, predictable cost (~$15–30/month for `db.t3.micro`).
2. **Aurora PostgreSQL Serverless v2**: scales ACUs up/down automatically; can scale to 0.5 ACU at idle (≈$0.06/ACU-hour).
3. **Aurora PostgreSQL Serverless v1** (legacy): scales to zero but cold-start latency is high (seconds); `engine_mode = "serverless"`; Data API only (no persistent connections); deprecated for new clusters.

### Decision

Use **Aurora PostgreSQL Serverless v2** (`engine_mode = "provisioned"` with `serverlessv2_scaling_configuration`, `min_capacity = 0.5`, `max_capacity = 1.0` in dev).

**Gotcha to preserve**: Serverless v2 uses `engine_mode = "provisioned"` in the Terraform `aws_rds_cluster` resource — **not** `"serverless"`. The `serverlessv2_scaling_configuration` block declares the scaling profile. `"serverless"` in the Terraform API refers to the legacy v1 API; using it would create a v1 cluster.

### Rationale

- **Cost at dev scale**: at 0.5 ACU idle, the cluster costs ~$0.06/hour — roughly comparable to a `db.t3.micro` RDS instance but with zero operational overhead for sizing.
- **Scales up for load tests**: `max_capacity = 1.0` ACU can be raised to 4–16 for staging/prod or load testing with a single variable change.
- **IAM auth support**: Serverless v2 supports `iam_database_authentication_enabled = true`, which is required for the application's passwordless authentication model.
- **RDS Data API**: `enable_http_endpoint = true` allows `aws rds-data execute-statement` from any machine with IAM credentials — used by the IAM DB user bootstrap script without needing VPC connectivity.
- **Managed master credential**: `manage_master_user_password = true` delegates master password rotation to AWS (Secrets Manager, encrypted with the platform CMK). The password never appears in Terraform state.

### Trade-offs

- **Minimum cost**: at 0.5 ACU the cluster cannot scale below that, so cost is ~$0.06/hour even when completely idle. Unlike Serverless v1, it does not scale to zero.
- **Cold-scale latency**: scaling from 0.5 to higher ACUs takes seconds. Acceptable for an internal tool with no strict latency SLA.
- **Data API throughput**: the Data API (used only by the bootstrap script, not the running app) has per-request overhead. The app connects via a direct TCP connection using IAM token auth, not the Data API.

---

## ADR-009: manage_master_user_password — No Passwords in Terraform State

**Date**: 2026-06-14
**Status**: Accepted

### Context

When provisioning a database cluster, Terraform must supply a master password. The naive approach is `master_password = var.db_password`, which stores the password in plaintext in `terraform.tfstate`. Even with S3-at-rest encryption, state files are sensitive artifacts; exposing admin credentials in state is a well-known Terraform anti-pattern.

### Decision

Set `manage_master_user_password = true` on `aws_db_instance.postgres`. AWS creates and rotates the master credential as a Secrets Manager secret (in the `rds!*` namespace, encrypted with the platform CMK). Terraform never sees or stores the password.

### Rationale

- **No plaintext credential in state**: `terraform.tfstate` contains only the Secrets Manager secret ARN (`master_user_secret[0].secret_arn`), not the password value.
- **Automatic rotation**: AWS rotates the master credential on a configurable schedule. No Terraform or operator action is required.
- **Break-glass access**: the master credential is available in Secrets Manager for DBA / break-glass access — but scoped to the `rds!*` namespace. The ECS task role explicitly excludes `rds!*` from its `secretsmanager:GetSecretValue` permission, so the app cannot access the admin password.
- **App never uses the master credential**: the application connects as `platform_app` via IAM token auth (`rds-db:connect`). The master credential is for administrative operations only.

### Trade-offs

- **Bootstrap dependency**: the bootstrap script (`infra/scripts/setup-db-user.sh`) uses the master credential (via psql) to `CREATE USER platform_app` and `GRANT rds_iam`. This one-time step must run after `terraform apply` and before the app can connect. If the secret rotates during the bootstrap step, the script may need to re-authenticate — acceptable since rotation is daily by default.
- **Terraform state still contains the secret ARN**: the ARN is exposed in state and in the `master_secret_arn` output. The ARN does not grant access (IAM is required), so it is not treated as sensitive.

---

## ADR-010: RDS Data API for IAM DB User Bootstrap

**Date**: 2026-06-14
**Status**: Superseded by [ADR-012](#adr-012-standard-rds-postgresql-instead-of-aurora-serverless-v2)

### Context

After the Aurora cluster is provisioned, a one-time SQL operation is required:

```sql
CREATE USER platform_app;
GRANT rds_iam TO platform_app;
```

Options for running this SQL:

1. **Manual psql**: operator connects via a bastion host or VPN. Requires network connectivity into the private subnet.
2. **Lambda in the VPC**: a Lambda function runs the SQL via `psycopg2`. Requires a Lambda, IAM role, and VPC attachment — significant infrastructure for a one-time step.
3. **RDS Data API** (`aws rds-data execute-statement`): HTTP/IAM-based SQL execution. No VPC connectivity required; runs from any machine with IAM credentials.

### Decision

Use the **RDS Data API** via `infra/scripts/setup-db-user.sh`. The script is idempotent (the `CREATE USER` error is swallowed; `GRANT rds_iam` is safe to re-run).

### Rationale

- **No VPC connectivity needed**: the script runs from the operator's machine or a CI job. No bastion, no VPN, no Lambda.
- **Least new infrastructure**: `enable_http_endpoint = true` on the cluster (already required for dev flexibility) is the only prerequisite.
- **Simplicity**: a 30-line shell script that reads Terraform outputs directly. Outputs the cluster ARN, master secret ARN, and database name; calls `aws rds-data execute-statement` twice.
- **Idempotent**: can be re-run safely if something went wrong. `CREATE USER` failure is ignored; `GRANT rds_iam` is a no-op if already granted.

### Trade-offs

- **Data API must remain enabled**: `enable_http_endpoint = true` must not be set to `false` in dev while the platform_app user might need to be recreated. In staging/prod where the operator has VPN or bastion access, it can be disabled after bootstrap.
- **Manual step**: the bootstrap script is not triggered automatically by Terraform. The operator must run it after `terraform apply`. This is documented in `README.md` and the CLAUDE.md `post-apply steps` section.

---

## ADR-011: S3 Native State Locking (use_lockfile) Instead of DynamoDB

**Date**: 2026-06-14
**Status**: Accepted

### Context

Terraform requires state locking to prevent concurrent `apply` operations from corrupting shared state. Historically, the recommended AWS pattern used an S3 bucket for state storage and a DynamoDB table for lock tokens (a conditional-write on a known key).

Starting with Terraform 1.10, the S3 backend supports **native state locking** via a `.tflock` file written atomically to S3 using conditional writes (`If-None-Match`). No DynamoDB table is required.

### Decision

Use `use_lockfile = true` in `infra/envs/dev/backend.tf` and remove the DynamoDB table from `infra/bootstrap/`. The bootstrap module now provisions only an S3 bucket.

### Rationale

- **One fewer resource**: eliminating the DynamoDB table removes ~$0/month cost (it was on the free tier, but the bootstrap module is simpler with one resource instead of two).
- **One fewer IAM permission category**: the GitHub Actions deploy role no longer needs `dynamodb:GetItem / PutItem / DeleteItem` on the lock table.
- **S3 conditional writes are equivalent**: `If-None-Match: *` on a `PutObject` call provides the same mutual-exclusion guarantee as a DynamoDB conditional write. AWS has had atomic conditional-write support in S3 since 2024.
- **Terraform 1.10 is current**: the project already targets `>= 1.10` (`required_version` in `providers.tf`). There is no compatibility constraint preventing adoption.

### Trade-offs

- **Requires Terraform ≥ 1.10**: earlier Terraform versions do not support `use_lockfile`. Operators must upgrade before running `terraform init` in this repository.
- **S3 bucket must support conditional writes**: requires a standard S3 bucket (not a bucket with Object Lock or Requester Pays enabled in certain configurations). The bootstrap bucket has neither constraint.
- **Lock file visible in S3**: the `.tflock` file appears in the S3 console during active applies. This is cosmetically different from DynamoDB but functionally equivalent.

---

## ADR-012: Standard RDS PostgreSQL Instead of Aurora Serverless v2

**Date**: 2026-06-15
**Status**: Accepted
**Supersedes**: ADR-008 (Aurora Serverless v2), ADR-010 (RDS Data API bootstrap)

### Context

ADR-008 chose Aurora PostgreSQL Serverless v2. When `terraform apply` was run against a real AWS free-plan account, two problems surfaced:

1. **`FreeTierRestrictionError`**: AWS free-plan accounts require the `WithExpressConfiguration` API parameter to create Aurora clusters. The Terraform AWS provider (5.100.0) has no schema support for this attribute — `terraform validate` rejects it as an unknown argument. There is no workaround within Terraform configuration; a console-create + import flow would be required.

2. **Aurora Express Configuration removes VPC placement**: the AWS console screenshot of the Express Configuration flow showed that it uses engine v17 with no VPC selection, no subnet group, and AWS/RDS-owned encryption keys. The entire defence-in-depth stack (VPC isolation + security groups + CMK + IAM auth) is reduced to IAM auth as the sole access control layer. This is a security regression, not a cosmetic one.

Options reconsidered:

1. **Console-create Aurora + Terraform import**: works around the provider gap, but produces a cluster that `terraform plan` will perpetually show as drifted on the Express-only attributes. Fragile for CI.
2. **Aurora outside free tier**: Aurora Serverless v2 is simply not free-tier eligible on AWS free-plan accounts. Estimated cost: ~$22–30/month at idle (0.5 ACU).
3. **Standard RDS PostgreSQL (`aws_db_instance`)**: fully supported by provider 5.x, free-tier eligible (`db.t4g.micro` + 20 GiB gp2), and supports the full defence-in-depth stack (VPC + SGs + CMK + IAM auth).

### Decision

Switch the data module from `aws_rds_cluster` + `aws_rds_cluster_instance` to a single `aws_db_instance` with `engine = "postgres"`, `instance_class = "db.t4g.micro"`, `allocated_storage = 20`, `storage_type = "gp2"`.

Bootstrap script (`infra/scripts/setup-db-user.sh`) switches from `aws rds-data execute-statement` (Data API, Aurora-only) to `psql` + `aws secretsmanager get-secret-value`.

### Rationale

- **Free-tier eligible**: `db.t4g.micro` + 20 GiB gp2 are within the AWS free-tier allowance for 12 months. Aurora (any mode) is not.
- **Full defence-in-depth preserved**: VPC private subnet isolation + `db` security group (port 5432, `ecs_service_sg` only) + `publicly_accessible = false` + CMK encryption + IAM database authentication — all supported on standard RDS.
- **No Terraform provider gap**: `aws_db_instance` has been in the provider since v1; all attributes used here are fully supported in 5.x.
- **Same IAM auth model**: `iam_database_authentication_enabled = true` and `manage_master_user_password = true` are supported on standard RDS. The `rds-db:connect` IAM permission and `rds!*` Secrets Manager namespace both work identically — only the resource ID format changes from `cluster-XXXXX` to `db-XXXXX`.
- **Simpler data model**: one resource (`aws_db_instance`) instead of two (`aws_rds_cluster` + `aws_rds_cluster_instance`). No reader endpoint, no ACU scaling variables.

### Trade-offs

- **No automatic scaling**: `db.t4g.micro` is a fixed instance class. If the workload grows, an instance resize is required (`ModifyDBInstance` with a brief maintenance window). Acceptable for an internal tool at dev scale.
- **Bootstrap requires VPC access**: the Data API allowed running `CREATE USER` from any machine with IAM credentials. Standard RDS has no Data API; the bootstrap script now requires TCP access to port 5432 from within the VPC. In dev, the operator needs either an EC2 bastion, SSM port forwarding, or a one-off ECS Fargate task (natural option after E3). This is documented in `infra/scripts/setup-db-user.sh`.
- **No reader endpoint**: `aws_db_instance` exposes a single endpoint. For staging/prod, consider a Multi-AZ deployment or a read replica with its own endpoint.

---

## ADR-013: Separate SNS Topics for Billing Alarms vs. Operational Alerts

**Date**: 2026-06-17
**Status**: Accepted

### Context

The platform has two categories of operational alarm: a billing alarm (spend > $10/month) and nine service-health alarms (CPU, memory, storage, latency, errors, availability, provisioning failures). These could share a single SNS topic or use separate topics.

### Decision

Use **two separate SNS topics**: `cvs-platform-dev-billing-alarm` (created in `envs/dev/main.tf`) and `cvs-platform-dev-alerts` (created in `modules/observability/main.tf`).

### Rationale

- **Different subscribers**: billing watchers (finance / account owner) and on-call engineers are different people. A shared topic either wakes up engineers for billing threshold events or sends service outage alerts to finance — both are noise for the recipient.
- **Different urgency**: a billing breach at 2 AM is not actionable until business hours. A zero-healthy-hosts alarm at 2 AM requires immediate response. Mixing them into one subscriber list forces everyone onto the same escalation policy.
- **Independent subscription lifecycle**: adding a PagerDuty webhook for operational alerts should not affect billing alert delivery, and vice versa. Separate topics make each subscription independently manageable.
- **Module boundary**: the billing alarm is a root-level resource in `envs/dev` (cost governance at the account level). Operational alerts belong inside the observability module (service health). Co-locating them in one topic would blur that boundary and make the billing alarm depend on the observability module.

### Trade-offs

- **Two confirmation emails**: after `terraform apply`, the operator must confirm two SNS subscriptions. Documented in `README.md` Step 6.
- **One more resource**: an extra SNS topic costs nothing (SNS topics are free; charges are per message). The operational cost is zero.

---

## ADR-014: CloudWatch Logs Metric Filter as the App↔Infra Alerting Bridge

**Date**: 2026-06-17
**Status**: Accepted

### Context

The application needs to signal provisioning failures to the operations team. Several options exist:

1. **Direct CloudWatch metric from the app**: `boto3` PutMetricData call inside `approve()`. Couples the app to CloudWatch SDK; adds a network call on the hot path; requires extra IAM permissions on the task role.
2. **CloudWatch Logs metric filter**: Terraform resource that reads structured log lines already written by structlog and increments a custom metric. No app code changes required.
3. **Lambda triggered by log subscription**: more powerful but far more infrastructure for a simple counter.

### Decision

Use a **CloudWatch Logs metric filter** (`aws_cloudwatch_log_metric_filter`) that matches the structured JSON log event `{ $.event = "secret_provisioning_outcome" && $.outcome = "failed" }` already emitted by the `approve` route via structlog. The filter increments `CVSPlatform/Application::SecretProvisioningFailures` by 1 per match.

### Rationale

- **No app code changes**: the app already calls `log.warning("secret_provisioning_outcome", outcome="failed", ...)` — structlog renders this as JSON that CloudWatch can parse. The metric filter is purely infrastructure.
- **Clean separation of concerns**: the app's responsibility is to emit the right log event; infra's responsibility is to turn log events into metrics and alarms. Neither layer intrudes on the other.
- **CLAUDE.md design intent realized**: the observability section of CLAUDE.md described this exact full chain (`structlog event → awslogs → metric filter → alarm → SNS → email`). The metric filter is the realization of the "Do not implement actual CloudWatch API calls in application code" rule.
- **Lower latency than PutMetricData**: metric filter data is available within ~1 minute of the log line appearing in CloudWatch (same as any log delivery delay). This is fast enough for the alarm's 5-minute evaluation window.

### Trade-offs

- **Log delivery lag**: if the ECS task is terminated before the log driver flushes its buffer, the last few log lines may be lost. Acceptable: a lost provisioning-failure log means no alarm, but the request's FAILED status in the database is durable (committed before the log call). Ops can query the DB to detect silent failures.
- **Filter pattern fragility**: if the structlog event name or the `outcome` key ever changes, the metric filter stops matching and the alarm never fires. The filter pattern and the log.warning call are tested together in integration tests; the filter string is documented in CLAUDE.md.

---

## ADR-015: p95 Latency as the ALB Latency SLI (Not Average)

**Date**: 2026-06-17
**Status**: Accepted

### Context

The ALB latency alarm needs a statistic to compare against the 2-second threshold. Two candidates:

1. **Average** (`statistic = "Average"`): the mean response time over the evaluation period.
2. **p95** (`extended_statistic = "p95"`): the 95th-percentile response time — the slowest response experienced by 1 in 20 requests.

### Decision

Use **`extended_statistic = "p95"`** on the `alb_latency_p95` alarm with `threshold = 2.0` seconds.

### Rationale

- **Average hides tail latency**: if 5% of requests take 10 seconds but 95% complete in 200 ms, the average may be well under 2 seconds and the alarm never fires — despite 1 in 20 users experiencing an unacceptable wait. Averages systematically hide the worst user experience.
- **p95 is a standard SLI**: SRE practice uses percentile latency (p50, p95, p99) as the primary latency signal because it characterises the distribution, not just the center. Google SRE Book uses p99 as the canonical SLO metric; p95 is a reasonable threshold for an internal tool with no formal SLA.
- **Secrets Manager calls cause bimodal distribution**: the `approve` endpoint makes a Secrets Manager API call synchronously. Slow SM calls (cold-start, throttling, network hiccup) produce a bimodal response-time distribution: a fast cluster (~200ms) and a slow tail (1–10s). p95 catches the tail; average does not.
- **`extended_statistic` is the correct Terraform attribute**: CloudWatch percentile statistics are not `statistic` values — they require the `extended_statistic` argument (e.g. `"p95"`, `"p99.9"`). Using `statistic = "p95"` would be silently ignored or rejected.

### Trade-offs

- **p95 is noisier than average**: a single slow batch of requests can push p95 above threshold without a genuine latency problem. Mitigated by requiring 2 consecutive evaluation periods (`evaluation_periods = 2`) before the alarm fires.
- **`treat_missing_data = "notBreaching"`**: when there is no traffic (no data points), the alarm stays OK rather than entering INSUFFICIENT_DATA and paging on-call. This is correct for an internal tool with intermittent traffic but means a complete traffic blackout would not trigger the alarm — the `alb_healthy_hosts` alarm covers that case.

---

## ADR-016: Separate ECR Repository Per Environment

**Date**: 2026-06-13
**Status**: Accepted

### Context

Container images built from the same commit need to reach different environments (dev, staging). Options:

1. **Shared ECR repository, environment-tagged images**: `cvs-platform:dev-<sha>`, `cvs-platform:staging-<sha>`. One repo, tag prefix per environment.
2. **Separate ECR repository per environment**: `cvs-platform` (dev), `cvs-platform-staging` (staging). Separate IAM policies per repo.

### Decision

Use **a separate ECR repository per environment**, named `{project_name}-{environment}`. The dev environment already owns `cvs-platform`; staging provisions `cvs-platform-staging` via its own `module.ecs_service` call.

### Rationale

- **Least-privilege IAM**: the staging deploy role can be scoped to `cvs-platform-staging` only, and the dev deploy role to `cvs-platform` only. With a shared repo, both roles would need access to the same ARN and tag-based restrictions on ECR are cumbersome.
- **No accidental overwrite**: a push from `develop` cannot overwrite a staging image because the two push targets are different repositories. With a shared repo and the same commit SHA as the tag, a concurrent push from both branches would be a no-op, but the risk of a bad tag convention producing a collision grows as the team scales.
- **Clear lifecycle ownership**: staging images are deleted in `terraform-destroy-staging.yml` (which lists images in `cvs-platform-staging`) without any risk of touching dev images.
- **Symmetric with all other environment-scoped resources**: ECS cluster, service, task family, log group, and RDS instance all follow the `{project_name}-{environment}` naming pattern. ECR following the same pattern keeps the convention uniform.

### Trade-offs

- **Images are rebuilt, not promoted**: the same application commit is built twice (once per environment push). There is no "promote this exact image binary to staging." In practice the Dockerfile is deterministic and the two builds produce identical layer content (modulo build timestamp metadata). For strict binary promotion, a more advanced pipeline would tag the dev image with `staging` rather than rebuilding.
- **More repos as environments multiply**: each new environment adds one ECR repository. Manageable at the current scale (dev + staging); if many ephemeral preview environments are needed, a different strategy (shared repo with environment prefix tags) would be revisited.

---

## ADR-017: GitHub OIDC Provider as Account-Wide Singleton

**Date**: 2026-06-13
**Status**: Accepted

### Context

The IAM module creates a GitHub Actions OIDC identity provider (`aws_iam_openid_connect_provider`) when `create_oidc_provider = true`. The dev environment applies this with `create_oidc_provider = true`. When the staging environment module was added, the same module was called again.

AWS restricts OIDC providers to **one per issuer URL per account**. Attempting to create a second `aws_iam_openid_connect_provider` for `token.actions.githubusercontent.com` in the same account fails with `EntityAlreadyExists`.

### Decision

Set `create_oidc_provider = false` in `infra/envs/staging/main.tf`. The IAM module branches on this variable: when `false`, it skips the `aws_iam_openid_connect_provider` resource and uses an `aws_iam_openid_connect_provider` data source (lookup by URL) instead. The resulting provider ARN is the same resource in both environments.

### Rationale

- **AWS constraint is absolute**: creating two OIDC providers for the same URL is not supported. Any approach that tries to create the resource in staging would fail on a real account.
- **The provider is not environment-specific**: GitHub's OIDC issuer is a single global endpoint. The IAM trust policy condition (`sub` claim) is what restricts which branch can assume which role — not the provider itself.
- **Single source of truth**: the dev apply creates the provider; every subsequent environment applies only reference it.

### Trade-offs

- **Staging depends on dev having been applied first**: if the dev environment is destroyed (including the OIDC provider), the staging module's data source lookup will fail on the next `terraform plan`. In practice, the OIDC provider would be re-created with dev before staging is re-applied.
- **Variable convention must be documented**: `create_oidc_provider = false` is non-obvious. The comment in `infra/envs/staging/main.tf` and this ADR provide the explanation. Any new environment must also set this to `false`.

---

## ADR-018: Staging Data Protection — deletion_protection and Final Snapshot

**Date**: 2026-06-13
**Status**: Accepted

### Context

The dev environment configures its RDS instance with `deletion_protection = false` and `skip_final_snapshot = true` to enable fast teardown (`terraform destroy` works without any pre-steps). Staging is a stable, longer-lived environment; the risk posture is different.

### Decision

In `infra/envs/staging/main.tf`, set:
- `deletion_protection = true` — `terraform destroy` fails until this is explicitly lifted.
- `skip_final_snapshot = false` — AWS retains a final snapshot when the instance is deleted.

The automated destroy workflow (`terraform-destroy-staging.yml`) handles the lifecycle: it calls `aws rds modify-db-instance --no-deletion-protection` and waits for the instance to become available before running `terraform destroy`.

### Rationale

- **Guard against accidents**: `deletion_protection = true` means a mistyped `terraform destroy` in the wrong terminal window cannot delete the staging database. The Terraform apply would succeed in disabling protection only if the operator intends it.
- **Data recovery path**: `skip_final_snapshot = false` retains the last RDS snapshot. If staging holds seed data, integration test fixtures, or data needed to reproduce a bug, the snapshot preserves it without requiring a manual pre-destroy backup step.
- **The dev pattern is inappropriate for staging**: dev teardowns are frequent (experimenting, testing Terraform changes). Dev data is ephemeral. Staging teardowns are intentional, infrequent operations where the cost of an extra pre-step is low and the cost of data loss is higher.

### Trade-offs

- **Multi-step destroy**: the automated destroy workflow adds an AWS CLI step before `terraform destroy`. Without the workflow, a manual operator must remember to disable deletion protection first. The workflow makes the correct order the default.
- **Final snapshot storage cost**: the snapshot incurs standard RDS snapshot storage charges (currently $0.095/GB-month). At 20 GiB, this is ~$1.90/month until the snapshot is manually deleted. Acceptable for the recovery insurance it provides.
- **Snapshot not cleaned up by the workflow**: `terraform destroy` does not delete the final snapshot (by design — that is the point of `skip_final_snapshot = false`). An operator must delete it manually in the console or via CLI after confirming it is no longer needed.

---

## ADR-019: No Billing Alarm in the Staging Environment

**Date**: 2026-06-13
**Status**: Accepted

### Context

The dev environment provisions a billing alarm on `AWS/Billing::EstimatedCharges` that fires when the estimated monthly spend exceeds $10. When the staging environment was being designed, the question arose whether staging should have its own billing alarm.

### Decision

**No billing alarm in the staging environment.** The billing alarm is provisioned only in `infra/envs/dev/main.tf`. The `infra/modules/observability/` module does not include a billing alarm. The staging `main.tf` notes the omission explicitly in a comment.

### Rationale

- **`EstimatedCharges` is account-level, not per-environment**: the CloudWatch metric `AWS/Billing::EstimatedCharges` counts all charges across the entire AWS account. There is no "dev charges" vs "staging charges" dimension in this metric — both alarms would watch the exact same number.
- **Two alarms on the same metric fire simultaneously**: if the billing threshold is crossed, both the dev alarm and a hypothetical staging alarm would transition to `ALARM` at the same moment, sending two notifications to possibly the same email address. This is pure noise with no additional information.
- **The billing alarm is a root-level concern, not a module concern**: billing governance is an account-level responsibility, not tied to a specific environment's infrastructure. It belongs in the root `envs/dev` configuration (which owns the AWS account's primary cost settings) rather than in a reusable module.

### Trade-offs

- **No per-environment cost breakdown via alarm**: if staging is substantially more expensive than dev (e.g., due to larger instance class or more traffic), there is no alarm specifically tied to staging spend. Mitigated by AWS Cost Explorer and tag-based cost allocation (all staging resources are tagged `Environment=staging`).

---

## ADR-020: Parameterized CI/CD Workflows (Single File Per Concern, Branch-Driven)

**Date**: 2026-06-13
**Status**: Accepted

### Context

With two environments (dev and staging), CI/CD workflows need to build, push, and deploy to both. Options:

1. **Duplicate workflow files**: `app-build-push-dev.yml` and `app-build-push-staging.yml`. Simple conditional logic; easy to read per file. Risk: drift between the two files over time.
2. **Single parameterized workflow**: one `app-build-push.yml` that branches on `github.ref_name`. More complex conditionals; no duplication risk.

### Decision

Use **single parameterized workflow files** per concern:
- `app-build-push.yml` triggers on pushes to `develop` or `staging`, uses `github.ref_name` to set `environment:` and `ECR_REPOSITORY`.
- `app-deploy.yml` triggers on `workflow_run` completion on `develop` or `staging`, uses a "Resolve deployment target" shell script step to derive `ECR_REPOSITORY`, `ECS_CLUSTER`, `ECS_SERVICE`, and `TASK_FAMILY` from the triggering branch.

### Rationale

- **No drift**: a bug fix in the build or deploy logic is applied to both environments in a single commit. With duplicate files, one file is typically updated and the other is forgotten until a divergence causes a subtle prod-vs-staging difference.
- **Smaller diff surface**: adding a third environment (e.g., prod) requires adding one branch to an existing conditional, not duplicating an entire workflow file.
- **GitHub Actions supports expressions in `environment:`**: `environment: ${{ github.ref_name == 'staging' && 'staging' || 'dev' }}` is evaluated before the job runs — this is what determines which `AWS_DEPLOY_ROLE_ARN` variable is read. This capability was confirmed before choosing the parameterized approach.

### Known complexity: `workflow_run` vs `workflow_dispatch` branch detection

`workflow_run` events expose the triggering branch as `github.event.workflow_run.head_branch`. `workflow_dispatch` (manual rollback) exposes it as `github.ref_name`. These can't be unified in a single job-level expression without a shell step, because `workflow_dispatch` does not populate `github.event.workflow_run.head_branch`.

Solution: the `app-deploy.yml` "Resolve deployment target" step evaluates `BRANCH="${{ github.event.workflow_run.head_branch || github.ref_name }}"` and writes the derived resource names to `$GITHUB_ENV`. All subsequent steps read simple variable names. The `environment:` job attribute uses the same ternary expression; any residual mismatch at the job level is benign because OIDC's `sub` claim restricts which role the staging environment can assume.

### Trade-offs

- **Conditionals add cognitive load**: a reader must understand the ternary logic to know what runs for which branch. Mitigated by inline comments in both workflow files.
- **`workflow_dispatch` branch ambiguity**: if an operator manually triggers `app-deploy.yml` from the `staging` branch, `github.ref_name` resolves correctly. If they trigger it from a feature branch, the deployment defaults to `dev` — which may be unexpected. The workflow is primarily triggered automatically; manual use is documented as a rollback tool that the operator should invoke from the correct branch.

---

## ADR-021: Staged Destroy Workflow for Staging Environment

**Date**: 2026-06-13
**Status**: Accepted

### Context

`terraform destroy` on the staging environment fails for three independent reasons if run naively:

1. **ECS tasks mid-request**: destroying the ALB and subnets while tasks are running causes connection resets.
2. **RDS `deletion_protection = true`** (ADR-018): Terraform cannot delete the instance until this is lifted.
3. **Non-empty ECR repository**: `aws_ecr_repository` does not set `force_delete = true`, so Terraform aborts with `RepositoryNotEmptyException` if images exist.

Additionally, app-created Secrets Manager secrets (under `platform/*/staging/*`) are not in Terraform state and would be orphaned without explicit cleanup.

### Decision

Provision a manual-only GitHub Actions workflow (`terraform-destroy-staging.yml`) that performs a **staged teardown** in the correct order:

1. Scale ECS service to 0 and wait for drain.
2. Disable RDS deletion protection via CLI and wait for the instance to become available.
3. Delete all ECR images from the repository.
4. (Opt-in) Delete app-created Secrets Manager secrets under `platform/*/staging/*`.
5. Run `terraform destroy`.

A `confirm` text input (`"destroy-staging"`) is required to prevent accidental runs.

### Rationale

- **Order is non-negotiable**: if destroy runs before deletion_protection is lifted, Terraform fails partway through and leaves the environment in a partially-destroyed state. Each step unblocks the next.
- **Operator-initiated, not automated**: staging teardown is an intentional, rare operation. It should require a human decision, not fire automatically on branch delete or PR merge.
- **Opt-in secrets cleanup**: runtime secrets are valuable for forensics (verifying what was provisioned). Making deletion opt-in preserves them by default while providing a clean mechanism for full teardown when desired. The filter `split("/")[2] == "staging"` scopes deletion to staging secrets only, leaving dev secrets intact if both environments share an account.
- **Confirmation input as safety gate**: `"destroy-staging"` as the confirmation string makes accidental runs improbable. The workflow fails immediately if the input does not match exactly.

### Trade-offs

- **Not idempotent if steps partially fail**: if step 2 (disable deletion_protection) fails, re-running the workflow attempts step 1 again (scale to 0, already 0 — safe no-op) and then step 2. The `aws rds wait` command makes step 2 idempotent. However, if step 3 or 4 fails mid-loop, a partial run may leave some images or secrets requiring manual cleanup.
- **ECR pagination**: `aws ecr list-images` returns up to 1000 results in JSON before paging. `aws ecr batch-delete-image` accepts up to 100 image IDs. The workflow does not implement pagination — if staging ECR accumulates more than 100 images, extra manual cleanup may be needed.
- **`force_delete` not set on ECR resource**: the alternative would be `force_delete = true` on the Terraform resource, which would auto-delete images on `terraform destroy`. This was rejected because it bypasses the ordered teardown and could silently delete images before other resources that depend on the most recent image are cleanly removed.

---

## ADR-022: Module Outputs for Terraform Test Assertions

**Date**: 2026-06-13
**Status**: Accepted

### Context

`terraform test` assertions in a root module can only reference **declared outputs** of child modules — not internal resource attributes. During the staging test suite implementation, several assertions were initially written against module-internal paths:

```hcl
# These all fail: "module.X is object with N attributes / does not have attribute Y"
module.data.aws_db_instance.postgres.deletion_protection
module.ecs_service.aws_cloudwatch_log_group.app.retention_in_days
module.iam.aws_iam_role.github_deploy.assume_role_policy
```

This is correct module encapsulation behavior, not a Terraform bug.

### Decision

Add outputs to each module for any attribute that test suites need to assert on:
- `infra/modules/data/outputs.tf`: `deletion_protection`, `skip_final_snapshot`
- `infra/modules/ecs-service/outputs.tf`: `log_retention_days`
- `infra/modules/iam/outputs.tf`: `allowed_refs`

Assert on `module.X.output_name` in test HCL instead of internal paths.

### Rationale

- **Outputs are the correct module interface**: in Terraform, a module's public surface is its outputs. Adding testability outputs is architecturally correct — it explicitly declares that these values are part of the module's contract with callers.
- **The outputs are genuinely useful to callers**: `deletion_protection` on the data module lets a root module (e.g., a destroy automation) know whether a pre-destroy step is needed. `log_retention_days` could be surfaced to operators or compared across environments. `allowed_refs` is useful to an ops script verifying branch isolation. These are not test-only scaffolding.
- **Alternative — testing internal state via `terraform show`**: parsing JSON from `terraform show -json` inside a test is fragile and not how `terraform test` is designed to be used.
- **Alternative — testing from outside the module**: writing tests that instantiate individual resources directly (not via the module) would duplicate the module's logic in the test configuration, creating drift.

### Trade-offs

- **Slightly more outputs per module**: each module now exposes a few more attributes. The outputs are descriptive and low-noise — they do not expose secrets or internal ARNs that should not be visible.
- **Tests couple to module output names**: renaming an output (e.g., `deletion_protection` → `rds_deletion_protection`) breaks test assertions. This is acceptable — output names are part of the module's public API and are versioned with the same care as resource attributes.

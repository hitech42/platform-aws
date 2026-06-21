# Architecture Decision Records

---

## ADR-019: Layered Architecture — Routes → Services → Repositories

**Date**: 2026-06-20
**Status**: Accepted

### Context

The initial implementation placed all business logic, DB access, and commit control in module-level functions imported directly by route handlers (`service_catalog.py`, `secret_requests.py`, `request_lifecycle.py`, `bedrock.py`). This worked for the first feature but produced several compounding problems as the codebase grew:

- Route handlers mixed HTTP concerns (request parsing, response serialisation) with DB transaction control and domain rules.
- Mocking in unit tests required patching module-level names in the route module, so tests were tightly coupled to import paths rather than to contracts.
- The module-level transition function held `VALID_TRANSITIONS` as a top-level constant with no natural encapsulation boundary.
- Adding new capabilities would require repeating the same flat-function pattern, making the service layer increasingly hard to navigate.

### Decision

Introduce a three-layer architecture:

1. **Repository layer** (`app/src/repositories/`): all SQLAlchemy access. One class per aggregate. Repositories flush but never commit; the service controls the transaction boundary.
2. **Service layer** (`app/src/services/*_service.py`): business logic classes injected with repositories and a `Session`. Services own `commit()` and `refresh()`. Domain exceptions are raised here, never `HTTPException`.
3. **Route layer** (`app/src/api/v1/routes/`): thin HTTP handlers. Receive service instances via `Depends()`, call one service method, return a validated schema.

All `Depends()` provider functions (`get_*_repository`, `get_*_service`) live in `app/src/services/dependencies.py`. FastAPI deduplicates identical `Depends(get_db)` calls so all repositories in a single request share one `Session`.

### Rationale

- **Testability**: service unit tests inject mock repository instances; repository tests mock the SQLAlchemy session. Tests are decoupled from import paths and HTTP wiring.
- **Encapsulation**: `_VALID_TRANSITIONS` and `_transition()` are private to `SecretRequestLifecycleService`, making the state machine an internal implementation detail rather than a public module-level contract.
- **Single-responsibility routes**: handlers only parse input, call one service method, and serialise the response. No commit logic, no domain decisions.
- **Extensibility**: adding a new capability means adding a new repository class and a new service class, not extending flat module files.

### Trade-offs

- More files and classes for the same amount of logic. For a single-feature service this is overhead; at two or more features it pays back through independent testability and clear ownership boundaries.
- FastAPI's `Depends()` graph is less immediately obvious than a direct function call. The `dependencies.py` file centralises the wiring so it is always one place to look.

---

## ADR-001: Local Development Strategy — Native Postgres + LocalStack + Native App Process

**Date**: 2026-06-13
**Status**: Superseded by [ADR-016](#adr-016-local-development-strategy--containerised-postgres--localstack--native-app-process)

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
5. Swap `boto3` → `aioboto3` in `services/secrets_manager_service.py`.
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

## ADR-017: Facts/Narrative Separation for the AI Summary Endpoint

**Date**: 2026-06-19
**Status**: Accepted

### Context

`GET /api/v1/secret-requests/{id}/summary` combines two types of information:

1. **Deterministic risk facts**: ownership match (requester vs. registered service owner), naming-convention compliance, and environment risk (prod vs. non-prod). These are computable directly from Postgres — no external service is required.
2. **Natural-language narrative**: a brief audit summary phrased as readable prose for a human reviewer.

The key design question is whether Bedrock should *determine* facts or only *phrase* pre-computed facts.

### Decision

**Application code always computes all facts. Bedrock only phrases pre-computed facts as readable prose — it never determines whether a flag is true or false.**

The response always contains a `facts` object with deterministically computed values. The `narrative` field is populated by `generate_request_narrative()` (Bedrock call), but its absence or content never affects the accuracy of `facts`.

Model: **Claude Haiku 4.5 via Bedrock cross-region inference profile** (`us.anthropic.claude-haiku-4-5-20251001:0`) — cheapest fast model, ~$0.001 per call at this token count.

### Rationale

- **Correctness is non-negotiable**: risk flags inform approver security decisions. An LLM can hallucinate or contradict the database record; application code reading Postgres cannot.
- **Facts must survive Bedrock failures**: if Bedrock is throttling or inaccessible, the endpoint returns `narrative=null` and `narrative_error="..."` but always returns correct `facts`. The endpoint is always useful even when Bedrock is unavailable.
- **No model lock-in for correctness**: if the model is deprecated or swapped, facts are unaffected. `narrative_generated_by` makes the narrative source visible so consumers can reason about its reliability separately from facts.
- **Audit integrity**: ownership and naming decisions determined by an external LLM would make the audit trail dependent on model interpretation. Deterministic code makes the audit trail unambiguous and reproducible.
- **LocalStack compatibility**: LocalStack Community Edition does not implement Bedrock. When `AWS_ENDPOINT_URL` is set, `generate_request_narrative` returns a labeled `[stub]` string immediately without any boto3 call — facts are always accurate, the stub signals the narrative is not real.

### Trade-offs

- **Two-phase response**: `facts` is always deterministic; `narrative` is generated text. API consumers must not parse `narrative` to extract security decisions.
- **Bedrock cost on every summary call**: ~$0.001 per call (Haiku 4.5 pricing at 300-token output). Acceptable at low internal call volume. If volume grows, add caching keyed on `(request_id, status)`.
- **IAM resource wildcard for foundation model region**: the `bedrock:InvokeModel` policy uses `arn:aws:bedrock:*::foundation-model/...` (wildcard region) because the cross-region inference profile may route to any US region dynamically. The model ID is fully specified — only the region is wildcarded.

---

## ADR-018: Swappable LLM Provider — DB-backed Runtime Config with 30-second TTL Cache

**Date**: 2026-06-20
**Status**: Accepted
**Extends**: [ADR-017](#adr-017-factsnarrative-separation-for-the-ai-summary-endpoint)

### Context

ADR-017 established the facts/narrative separation for the summary endpoint and hardcoded AWS Bedrock (Claude Haiku 4.5 via cross-region inference profile) as the sole narrative provider. Two problems surfaced during development:

1. **Bedrock requires manual model-access enablement**: in a fresh AWS account, the model must be enabled in the Bedrock console before the first invocation. During development, the direct Anthropic API is simpler to configure (one environment variable) and uses the same model family.
2. **No hot-switch capability**: changing the provider meant modifying code, cutting a release, and deploying a new ECS task revision — a 5–15-minute cycle for what should be an operational configuration decision.

### Decision

Introduce a `config` table in Postgres and a runtime config service (`app/src/core/runtime_config/llm_provider_config.py`) with a **30-second TTL in-memory cache**. The active provider is stored as a row with `key = 'llm_provider'`; valid values are `bedrock` and `anthropic_api`. The seed value is `anthropic_api`.

To switch providers at runtime without a redeploy or restart:
```sql
UPDATE config SET value = 'bedrock' WHERE key = 'llm_provider';
```
The running ECS task picks up the change within 30 seconds on the next summary request.

Two concrete providers implement the `NarrativeProvider` protocol (`generate_narrative(prompt: str) -> str`):

- **`BedrockNarrativeProvider`**: calls Bedrock Runtime `converse` API; returns a labeled `[stub]` string immediately when `AWS_ENDPOINT_URL` is set (LocalStack CE has no Bedrock).
- **`AnthropicAPINarrativeProvider`**: calls the Anthropic Messages API via the `anthropic` Python SDK. The API key is loaded once at startup: first from the `ANTHROPIC_API_KEY` env var, then from Secrets Manager at `/{environment}/platform/anthropic-api-key` (real AWS only; skipped when `AWS_ENDPOINT_URL` is set).

`get_active_provider(db)` reads the cached config value and returns the pre-instantiated singleton provider. Both providers are instantiated at module import time; only the selection is per-request.

### Rationale

- **No redeploy to switch providers**: a single `UPDATE` propagates within one TTL window. Useful in development (direct API vs Bedrock) and in production (Bedrock throttling or regional unavailability).
- **Secrets Manager for the Anthropic key on AWS**: the key is not in the ECS task definition environment (avoids it being visible in the ECS console). The task role has `secretsmanager:GetSecretValue` scoped to the single key ARN (`AnthropicAPIKeyRead` IAM statement; see Stage 5 Terraform).
- **Lazy client init**: `anthropic.Anthropic()` is created on first `generate_narrative` call, not at import. This prevents `AuthenticationError` at startup when `bedrock` is the active provider and no Anthropic key is configured — a valid production configuration.
- **ADR-017 design principle preserved**: `facts` are still always computed deterministically from Postgres. Neither provider determines facts; both only phrase pre-computed flags as prose.

### Trade-offs

- **30-second propagation lag**: after an `UPDATE config` statement, the running process continues using the cached provider for up to 30 seconds. Acceptable for a low-traffic internal tool.
- **Cache is per-process**: each ECS task replica has its own 30-second window. Under a multi-task deployment, different replicas may briefly use different providers after a config change. Provider selection is not a user-visible consistency concern.
- **Anthropic key loaded once at startup**: `_load_anthropic_api_key()` runs at module import time. If the Secrets Manager value changes, the task must restart to pick up the new key.
- **`narrative_generated_by` has three values**: `"bedrock"`, `"stub"`, and `"anthropic_api"`. API consumers must not assume only Bedrock values — all three are valid narrative sources, distinct from facts.

---

## ADR-016: Local Development Strategy — Containerised Postgres + LocalStack + Native App Process

**Date**: 2026-06-19
**Status**: Accepted
**Supersedes**: [ADR-001](#adr-001-local-development-strategy--native-postgres--localstack--native-app-process)

### Context

ADR-001 chose native Postgres (running on the developer's machine) primarily to support IntelliJ IDEA debugger attachment with zero friction. The original concern was that attaching to an in-container process required extra Docker network configuration.

The project is now being reviewed by interviewers. A native Postgres installation is an environment-specific prerequisite that adds setup friction for anyone cloning the repository for the first time — they must install Postgres, create a role, and create a database before running the application. Docker is already required (for LocalStack), so shipping Postgres as a second Docker Compose service adds no new tooling requirement.

### Decision

Run **Postgres inside Docker Compose** alongside LocalStack. The `docker-compose.yml` now defines both `localstack` and `postgres` services; `docker compose up -d` starts both. The `postgres_data` named volume persists data across container restarts.

Credentials are unchanged from the original default (`POSTGRES_USER=app`, `POSTGRES_PASSWORD=localdev`, `POSTGRES_DB=platform`), so the `DATABASE_URL` in `.env.example` (`postgresql://app:localdev@localhost:5432/platform`) requires no modification — Docker maps the container's port 5432 to `localhost:5432`.

### Rationale

- **Zero-install onboarding**: a new reviewer (or developer) needs only Docker Desktop. `git clone` → `docker compose up -d` → `alembic upgrade head` → `uvicorn` is the complete flow with no OS-level package installation.
- **Version pinned**: `postgres:16-alpine` is locked in `docker-compose.yml`, matching the CI and production target version exactly. Native installs may be on any version.
- **IntelliJ debugging unaffected**: the FastAPI app process still runs natively (not in a container). Only Postgres moved into Docker. The debugger attaches to the native `uvicorn` process exactly as before; network access to `localhost:5432` is identical whether Postgres is native or container-mapped.
- **Consistent with LocalStack**: the two AWS-and-DB dependencies now follow the same pattern. There is no longer a split model where one external dependency is containerised and one is not.

### Trade-offs

- **Docker must be running to start the app**: previously, a developer could work without Docker if they only needed the API (no AWS calls). Now, Postgres also requires Docker. Acceptable — the app cannot function without a database anyway, and Docker is already listed as a prerequisite.
- **Data volume lifecycle**: `postgres_data` persists across restarts. Destroying the volume (`docker compose down -v`) clears all local data and requires re-running migrations. This is the same behaviour as the native installation, where `dropdb platform` would do the same.


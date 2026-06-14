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

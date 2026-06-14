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

- **FastAPI compensates correctly**: `def` route handlers are automatically run in a thread pool executor (`asyncio.run_in_executor`), so blocking DB calls do not block the event loop. The behaviour is correct without requiring async machinery.
- **boto3 is synchronous**: boto3 has no native async support. Switching to `AsyncSession` would make DB calls non-blocking but leave Secrets Manager calls blocking on the event loop — partial async with no full benefit.
- **Simpler code and tests**: no `async`/`await` through the service layer, no `AsyncSession` context managers, no `asyncpg` driver quirks. Unit tests mock a plain `Session` with `unittest.mock.MagicMock`.
- **Internal tool, low concurrency**: this service handles infrequent self-service requests from internal teams, not high-throughput public traffic. A thread pool is more than sufficient.

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

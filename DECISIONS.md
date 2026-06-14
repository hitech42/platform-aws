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

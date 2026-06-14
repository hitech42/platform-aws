# Developer Self-Service Platform API

An internal FastAPI service that lets dev teams self-serve platform requests — starting with requesting and managing application secrets in AWS Secrets Manager — with a full audit trail stored in Postgres. Built for deployment on ECS Fargate + Aurora Serverless v2, with LocalStack for local AWS emulation.

## Status

**Early scaffold** — project structure, configuration, and tooling are in place. The `/healthz` and `/readyz` endpoints are functional. Database models, the secret-request lifecycle, and all business endpoints will be added in subsequent sessions.

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

> **Note**: No migrations exist yet in this scaffold. The command below will be the standard workflow once models are added.

```bash
cd app/
alembic upgrade head
cd ..
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

## Running Tests

```bash
# From the project root
PYTHONPATH=. pytest app/tests/ -v
```

## Linting & Type Checking

```bash
cd app/
ruff check src/ tests/
ruff format src/ tests/
mypy src/
```

## IntelliJ / PyCharm

Mark `app/src/` as a **Sources Root** (right-click → Mark Directory as → Sources Root). Set the project root as a content root so `app.src.*` imports resolve correctly without needing to set `PYTHONPATH` manually.

## Docker (optional)

```bash
docker build -f app/Dockerfile -t cvs-platform-api app/
docker run --rm -p 8000:8000 --env-file .env cvs-platform-api
```

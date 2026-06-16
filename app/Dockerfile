# Build context: app/
# Run: docker build -f app/Dockerfile -t cvs-platform-api app/

# ── Builder: install dependencies into an isolated venv ───────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml .
# Install only runtime deps (no [dev] extras) for a lean image.
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir .

# ── Final: minimal runtime image ──────────────────────────────────────────────
FROM python:3.12-slim AS final

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Non-root user for security — matches common ECS task patterns.
RUN useradd --no-create-home --shell /bin/false --uid 1001 appuser

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Mirror the local import path (app.src.*) so no code changes are needed
# between local and containerised runs.
WORKDIR /project
RUN mkdir -p app && touch app/__init__.py
COPY src/ app/src/
# alembic.ini is required by the migration one-off task in CI/CD (app-deploy.yml).
# script_location = src/db/migrations is relative to the ini file's location
# (/project/app/), resolving to /project/app/src/db/migrations/ inside the container.
COPY alembic.ini app/alembic.ini

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "app.src.main:app", "--host", "0.0.0.0", "--port", "8000"]

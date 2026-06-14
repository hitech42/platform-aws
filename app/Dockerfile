# Build context: app/
# Run: docker build -f app/Dockerfile -t cvs-platform-api app/

# ── Builder: install dependencies into an isolated venv ───────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml .
# Install only runtime deps (no [dev] extras) for a lean image.
RUN pip install --upgrade pip && pip install .

# ── Final: minimal runtime image ──────────────────────────────────────────────
FROM python:3.12-slim AS final

# Non-root user for security — matches common ECS task patterns.
RUN useradd --no-create-home --shell /bin/false --uid 1001 appuser

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Mirror the local import path (app.src.*) so no code changes are needed
# between local and containerised runs.
WORKDIR /project
RUN mkdir -p app && touch app/__init__.py
COPY src/ app/src/

USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.src.main:app", "--host", "0.0.0.0", "--port", "8000"]

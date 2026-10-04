# Mitschrift ASR-Adapter als Container. Erwartet einen erreichbaren whisper-server (WHISPER_URL) bzw.
# später ein Riva-gRPC-Backend; Konfiguration ausschließlich über Umgebungsvariablen, siehe README.
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY asr_adapter ./asr_adapter
RUN uv sync --frozen --no-dev
RUN useradd --system --uid 10001 --no-create-home mitschrift
USER mitschrift
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD ["/app/.venv/bin/python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/v1/health', timeout=3).status in (200, 503) else 1)"]
CMD ["/app/.venv/bin/uvicorn", "asr_adapter.app:app", "--host", "0.0.0.0", "--port", "8765"]

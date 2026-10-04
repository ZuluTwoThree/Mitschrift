from __future__ import annotations

import asyncio
import logging
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Callable

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from . import __version__
from .config import Settings, settings_from_env
from .nemo_realtime import NemoHealthClient
from .sessions import SessionError, SessionStore
from .wav import WavError, parse_wav
from .whisper_client import Transcriber, TranscriberError, WhisperServerClient

log = logging.getLogger("asr_adapter")

LANGUAGES = {"de", "en", "auto"}
HEADER_SESSION = "x-mitschrift-session"
HEADER_SEQUENCE = "x-mitschrift-sequence"
HEADER_LANGUAGE = "x-mitschrift-language"


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": code, "message": message})


def create_app(
    settings: Settings | None = None,
    transcriber: Transcriber | None = None,
    nemo_factory: Callable[[], Any] | None = None,
) -> FastAPI:
    settings = settings or settings_from_env()
    if transcriber is None:
        if settings.asr_backend == "nemo":
            transcriber = NemoHealthClient(settings.nemo_url, settings.nemo_api_key)
        else:
            transcriber = WhisperServerClient(settings.whisper_url, settings.whisper_timeout_seconds)
    store = SessionStore(settings, transcriber, nemo_factory=nemo_factory)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        sweeper = asyncio.create_task(store.run_sweeper())
        try:
            yield
        finally:
            sweeper.cancel()
            await transcriber.aclose()

    app = FastAPI(title="Mitschrift ASR-Adapter", version=__version__, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = store
    app.state.settings = settings

    @app.exception_handler(ApiError)
    async def _api_error(_: Request, error: ApiError) -> JSONResponse:
        return _error(error.status, error.code, error.message)

    @app.exception_handler(SessionError)
    async def _session_error(_: Request, error: SessionError) -> JSONResponse:
        return _error(error.status, error.code, error.message)

    @app.exception_handler(WavError)
    async def _wav_error(_: Request, error: WavError) -> JSONResponse:
        return _error(400, error.code, error.message)

    @app.exception_handler(TranscriberError)
    async def _transcriber_error(_: Request, error: TranscriberError) -> JSONResponse:
        log.warning("ASR-Backend (%s): %s", settings.asr_backend, error)
        return _error(503, "asr_unavailable", "Spracherkennung ist gerade nicht verfügbar.")

    @app.exception_handler(Exception)
    async def _unexpected(_: Request, error: Exception) -> JSONResponse:
        log.exception("unerwarteter Fehler: %s", type(error).__name__)
        return _error(500, "internal_error", "Interner Fehler.")

    def require_token(request: Request) -> None:
        header = request.headers.get("authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or token.strip() != settings.token:
            raise ApiError(401, "unauthorized", "Nicht autorisiert.")

    @app.get("/v1/health")
    async def health() -> JSONResponse:
        healthy = await transcriber.is_healthy()
        body: dict[str, Any] = {
            "status": "ok" if healthy else "degraded",
            "version": __version__,
            "backend": settings.asr_backend,
            "model": settings.model_name,
            "modelLoaded": healthy,
            "activeSessions": store.active_count,
            "maxSessions": settings.max_sessions,
            "language": settings.language_default,
            "diarization": settings.asr_backend == "nemo" and settings.nemo_speaker_diarization,
        }
        return JSONResponse(status_code=200 if healthy else 503, content=body)

    @app.post("/v1/live-transcriptions/segments")
    async def post_segment(request: Request) -> dict[str, Any]:
        require_token(request)

        content_length = request.headers.get("content-length")
        if content_length is not None and int(content_length) > settings.max_request_bytes:
            raise ApiError(413, "payload_too_large", "Segment ist größer als 1 MiB.")
        content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type not in {"audio/wav", "audio/x-wav", "audio/wave"}:
            raise ApiError(400, "invalid_content_type", "Erwartet Content-Type audio/wav.")

        session_id = request.headers.get(HEADER_SESSION, "").strip()
        try:
            uuid.UUID(session_id)
        except ValueError:
            raise ApiError(400, "invalid_session", "X-Mitschrift-Session muss eine UUID sein.") from None
        try:
            sequence = int(request.headers.get(HEADER_SEQUENCE, ""))
        except ValueError:
            raise ApiError(400, "invalid_sequence", "X-Mitschrift-Sequence muss eine Ganzzahl sein.") from None
        if sequence < 0:
            raise ApiError(400, "invalid_sequence", "X-Mitschrift-Sequence muss >= 0 sein.")
        language = request.headers.get(HEADER_LANGUAGE, "").strip().lower()
        if language not in LANGUAGES:
            raise ApiError(400, "invalid_language", "X-Mitschrift-Language muss de, en oder auto sein.")

        body = await request.body()
        if len(body) > settings.max_request_bytes:
            raise ApiError(413, "payload_too_large", "Segment ist größer als 1 MiB.")
        samples = parse_wav(body, min_seconds=settings.min_segment_seconds, max_seconds=settings.max_segment_seconds)
        return await store.handle_segment(session_id, sequence, language, samples)

    @app.post("/v1/live-transcriptions/{session_id}/finish")
    async def finish(session_id: str, request: Request) -> dict[str, Any]:
        require_token(request)
        return await store.finish(session_id)

    return app


def __getattr__(name: str) -> Any:
    # `uvicorn asr_adapter.app:app` erzeugt die App erst beim Zugriff, damit Tests ohne Umgebungsvariablen importieren können.
    if name == "app":
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
        return create_app()
    raise AttributeError(name)

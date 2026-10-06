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
from .llm_client import NOTES_KINDS, NotesError, NotesWriter, OpenAIChatClient
from .nemo_realtime import NemoHealthClient
from .sessions import SessionError, SessionStore
from .wav import WavError, parse_wav
from .whisper_client import Transcriber, TranscriberError, WhisperServerClient

log = logging.getLogger("asr_adapter")

LANGUAGES = {"de", "en", "auto"}
NOTES_LANGUAGES = {"de", "en"}
NOTES_UNAVAILABLE = "Der Protokoll-Assistent ist gerade nicht verfügbar."
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
    notes_writer: NotesWriter | None = None,
) -> FastAPI:
    settings = settings or settings_from_env()
    if notes_writer is None and settings.llm_url:
        notes_writer = OpenAIChatClient(
            settings.llm_url,
            model=settings.llm_model,
            api_key=settings.llm_api_key,
            timeout_seconds=settings.llm_timeout_seconds,
            max_output_tokens=settings.llm_max_output_tokens,
            temperature=settings.llm_temperature,
            summary_max_output_tokens=settings.llm_summary_max_output_tokens,
            chunk_chars=settings.llm_chunk_chars,
        )
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
            if notes_writer is not None:
                await notes_writer.aclose()

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

    @app.exception_handler(NotesError)
    async def _notes_error(_: Request, error: NotesError) -> JSONResponse:
        log.warning("Protokoll-Assistent: %s", error)
        return _error(503, "llm_unavailable", NOTES_UNAVAILABLE)

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
            "notes": notes_writer is not None,
            "notesKinds": list(NOTES_KINDS) if notes_writer is not None else [],
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

    @app.post("/v1/notes")
    async def post_notes(request: Request) -> dict[str, Any]:
        require_token(request)
        try:
            body = await request.json()
        except ValueError:
            raise ApiError(400, "invalid_request", "Erwartet einen JSON-Body.") from None
        if not isinstance(body, dict):
            raise ApiError(400, "invalid_request", "Erwartet ein JSON-Objekt.")

        transcript = body.get("transcript")
        if not isinstance(transcript, str):
            raise ApiError(400, "invalid_request", "transcript muss ein String sein.")
        transcript = transcript.strip()
        if not transcript:
            raise ApiError(400, "invalid_request", "transcript darf nicht leer sein.")
        if len(transcript) > settings.llm_max_input_chars:
            raise ApiError(413, "transcript_too_long", f"transcript ist länger als {settings.llm_max_input_chars} Zeichen.")

        language = body.get("language", "de")
        if language is None or language == "auto":
            language = "de"
        if not isinstance(language, str):
            raise ApiError(400, "invalid_request", "language muss ein String sein.")
        language = language.strip().lower() or "de"
        if language not in NOTES_LANGUAGES:
            raise ApiError(400, "invalid_language", "language muss de oder en sein.")

        title = body.get("title")
        if title is not None and not isinstance(title, str):
            raise ApiError(400, "invalid_request", "title muss ein String sein.")
        recorded_at = body.get("recordedAt")
        if recorded_at is not None and not isinstance(recorded_at, str):
            raise ApiError(400, "invalid_request", "recordedAt muss ein String sein.")

        kind = body.get("kind", "minutes")
        if kind is None:
            kind = "minutes"
        if not isinstance(kind, str) or kind not in NOTES_KINDS:
            raise ApiError(400, "invalid_kind", "kind muss minutes oder summary sein.")

        if notes_writer is None:
            raise NotesError("LLM_URL ist nicht konfiguriert")
        result = await notes_writer.write_notes(transcript, language, title or None, recorded_at or None, kind)
        log.info(
            "%s erstellt: %d Zeichen Eingabe in %d Teil(en), %d Zeichen Ausgabe, %s ms",
            "Zusammenfassung" if kind == "summary" else "Protokoll", len(transcript), result.chunks, len(result.notes), result.latency_ms,
        )

        diagnostics: dict[str, Any] = {}
        if result.latency_ms is not None:
            diagnostics["latencyMs"] = result.latency_ms
        if result.prompt_tokens is not None:
            diagnostics["promptTokens"] = result.prompt_tokens
        if result.completion_tokens is not None:
            diagnostics["completionTokens"] = result.completion_tokens
        diagnostics["chunks"] = result.chunks
        return {"notes": result.notes, "kind": kind, "model": result.model, "diagnostics": diagnostics}

    return app


def __getattr__(name: str) -> Any:
    # `uvicorn asr_adapter.app:app` erzeugt die App erst beim Zugriff, damit Tests ohne Umgebungsvariablen importieren können.
    if name == "app":
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
        return create_app()
    raise AttributeError(name)

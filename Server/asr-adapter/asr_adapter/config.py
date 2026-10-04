from __future__ import annotations

import os
from dataclasses import dataclass


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    token: str
    whisper_url: str = "http://127.0.0.1:8080"
    host: str = "127.0.0.1"
    port: int = 8765
    language_default: str = "de"
    model_name: str = "unbekannt"

    # Backend: "whisper" (Rollpuffer vor whisper-server) oder "nemo" (Realtime-WebSocket von nemo-speech serve)
    asr_backend: str = "whisper"
    nemo_url: str = "ws://127.0.0.1:8095"
    nemo_api_key: str | None = None
    nemo_endpointing_ms: int = 700
    # Nach dem Senden eines Segments so lange auf Verarbeitung warten (0 = nicht warten, höchstens 2 s)
    nemo_settle_seconds: float = 0.0
    nemo_finish_timeout_seconds: float = 15.0
    # Sprecherlabels je Wort anfordern (braucht ein mit --diar-model geladenes Diarization-Modell)
    nemo_speaker_diarization: bool = False

    # Audioformat
    sample_rate: int = 16_000
    overlap_seconds: float = 0.3
    min_segment_seconds: float = 1.0
    max_segment_seconds: float = 5.0
    max_request_bytes: int = 1_048_576

    # Rollpuffer und Finalisierung
    window_seconds: float = 12.0
    finalize_margin_seconds: float = 3.0
    # Finalisieren nur an einer Pause (Lücke zum nächsten Segment), an einem Satzende oder erzwungen,
    # wenn das Segment schon so lange zurückliegt. Verhindert Schnitte mitten im Wort.
    finalize_min_gap_seconds: float = 0.2
    finalize_force_seconds: float = 8.0
    # Nach einem finalen Segment wird der Puffer an der leisesten Stelle innerhalb dieses Zeitraums geschnitten.
    cut_search_seconds: float = 0.4
    # So viele Zeichen des zuletzt finalisierten Texts bekommt Whisper als Prompt für das nächste Fenster.
    # Standard 0 (aus): Im Vergleich auf einer 56-s-Aufnahme verschlechterte der Prompt die
    # Wortfehlerrate gegenüber der Offline-Transkription von 13,3 % auf 19,5 % und erzeugte leere Fenster.
    prompt_max_chars: int = 0

    # Limits
    max_sessions: int = 4
    session_idle_timeout_seconds: float = 60.0
    max_session_seconds: float = 4 * 3600.0
    max_inflight_per_session: int = 2
    whisper_timeout_seconds: float = 15.0

    # Protokoll-Assistent: OpenAI-kompatibler Chat-Endpunkt (z. B. llama-server). Leer = Funktion aus.
    llm_url: str = ""
    llm_model: str = "local"
    llm_api_key: str | None = None
    llm_timeout_seconds: float = 180.0
    llm_max_input_chars: int = 120_000
    llm_max_output_tokens: int = 2048
    llm_temperature: float = 0.2


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    return float(raw) if raw else default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "ja"}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def settings_from_env() -> Settings:
    token = os.environ.get("MITSCHRIFT_TOKEN", "").strip()
    if not token:
        raise ConfigError("MITSCHRIFT_TOKEN ist nicht gesetzt.")
    backend = os.environ.get("ASR_BACKEND", "whisper").strip().lower() or "whisper"
    if backend not in {"whisper", "nemo"}:
        raise ConfigError("ASR_BACKEND muss whisper oder nemo sein.")
    model_path = os.environ.get("MODEL", "")
    if backend == "nemo":
        model_path = os.environ.get("NEMO_ASR_MODEL", "") or model_path
    settle = min(max(_env_float("NEMO_SETTLE_SECONDS", 0.0), 0.0), 2.0)
    return Settings(
        token=token,
        whisper_url=os.environ.get("WHISPER_URL", "http://127.0.0.1:8080").rstrip("/"),
        host=os.environ.get("HOST", "127.0.0.1"),
        port=_env_int("PORT", 8765),
        language_default=os.environ.get("LANGUAGE", "de"),
        model_name=os.path.basename(model_path) if model_path else "unbekannt",
        asr_backend=backend,
        nemo_url=os.environ.get("NEMO_URL", "ws://127.0.0.1:8095").rstrip("/"),
        nemo_api_key=os.environ.get("NEMO_API_KEY") or None,
        nemo_endpointing_ms=_env_int("NEMO_ENDPOINTING_MS", 700),
        nemo_settle_seconds=settle,
        nemo_finish_timeout_seconds=_env_float("NEMO_FINISH_TIMEOUT_SECONDS", 15.0),
        nemo_speaker_diarization=_env_bool("NEMO_SPEAKER_DIARIZATION", False),
        window_seconds=_env_float("WINDOW_SECONDS", 12.0),
        finalize_margin_seconds=_env_float("FINALIZE_MARGIN_SECONDS", 3.0),
        finalize_min_gap_seconds=_env_float("FINALIZE_MIN_GAP_SECONDS", 0.2),
        finalize_force_seconds=_env_float("FINALIZE_FORCE_SECONDS", 8.0),
        prompt_max_chars=_env_int("PROMPT_MAX_CHARS", 0),
        max_sessions=_env_int("MAX_SESSIONS", 4),
        session_idle_timeout_seconds=_env_float("SESSION_IDLE_TIMEOUT_SECONDS", 60.0),
        whisper_timeout_seconds=_env_float("WHISPER_TIMEOUT_SECONDS", 15.0),
        llm_url=os.environ.get("LLM_URL", "").strip().rstrip("/"),
        llm_model=os.environ.get("LLM_MODEL", "").strip() or "local",
        llm_api_key=os.environ.get("LLM_API_KEY") or None,
        llm_timeout_seconds=_env_float("LLM_TIMEOUT_SECONDS", 180.0),
        llm_max_input_chars=_env_int("LLM_MAX_INPUT_CHARS", 120_000),
        llm_max_output_tokens=_env_int("LLM_MAX_OUTPUT_TOKENS", 2048),
        llm_temperature=_env_float("LLM_TEMPERATURE", 0.2),
    )

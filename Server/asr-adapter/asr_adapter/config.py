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


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    return float(raw) if raw else default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def settings_from_env() -> Settings:
    token = os.environ.get("MITSCHRIFT_TOKEN", "").strip()
    if not token:
        raise ConfigError("MITSCHRIFT_TOKEN ist nicht gesetzt.")
    model_path = os.environ.get("MODEL", "")
    return Settings(
        token=token,
        whisper_url=os.environ.get("WHISPER_URL", "http://127.0.0.1:8080").rstrip("/"),
        host=os.environ.get("HOST", "127.0.0.1"),
        port=_env_int("PORT", 8765),
        language_default=os.environ.get("LANGUAGE", "de"),
        model_name=os.path.basename(model_path) if model_path else "unbekannt",
        window_seconds=_env_float("WINDOW_SECONDS", 12.0),
        finalize_margin_seconds=_env_float("FINALIZE_MARGIN_SECONDS", 3.0),
        finalize_min_gap_seconds=_env_float("FINALIZE_MIN_GAP_SECONDS", 0.2),
        finalize_force_seconds=_env_float("FINALIZE_FORCE_SECONDS", 8.0),
        prompt_max_chars=_env_int("PROMPT_MAX_CHARS", 0),
        max_sessions=_env_int("MAX_SESSIONS", 4),
        session_idle_timeout_seconds=_env_float("SESSION_IDLE_TIMEOUT_SECONDS", 60.0),
        whisper_timeout_seconds=_env_float("WHISPER_TIMEOUT_SECONDS", 15.0),
    )

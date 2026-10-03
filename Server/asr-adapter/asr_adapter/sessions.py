from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np

from .config import Settings
from .whisper_client import RawSegment, Transcriber

log = logging.getLogger("asr_adapter.sessions")


class SessionError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _segment_json(start: float, end: float, text: str) -> dict[str, Any]:
    return {"start": round(start, 2), "end": round(end, 2), "text": text}


@dataclass
class Session:
    session_id: str
    language: str
    settings: Settings
    created_at: float
    last_activity: float
    last_sequence: int = -1
    finished: bool = False
    finish_response: dict[str, Any] | None = None
    # Rollpuffer: PCM ab `buffer_start` (Sekunden auf der Sessionzeitachse)
    buffer: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype="<i2"))
    buffer_start: float = 0.0
    timeline_end: float = 0.0
    # Dedup: gespeicherte Antwort je sequence
    responses: dict[int, dict[str, Any]] = field(default_factory=dict)
    # Zuletzt finalisierter Text (gekürzt), als Prompt für das nächste Fenster
    recent_final_text: str = ""
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    inflight: int = 0

    @property
    def buffer_end(self) -> float:
        return self.buffer_start + len(self.buffer) / self.settings.sample_rate

    def append(self, samples: np.ndarray, sequence: int) -> None:
        """Hängt ein Segment an; ab dem zweiten Segment wird die Überlappung verworfen."""
        if sequence > 0:
            drop = int(self.settings.overlap_seconds * self.settings.sample_rate)
            samples = samples[min(drop, len(samples)) :]
        self.buffer = np.concatenate([self.buffer, samples])
        self.timeline_end = self.buffer_end
        # Puffer auf Fenstergröße begrenzen (nicht finalisiertes Audio am Anfang fällt dann weg)
        max_samples = int(self.settings.window_seconds * self.settings.sample_rate)
        if len(self.buffer) > max_samples:
            excess = len(self.buffer) - max_samples
            self.buffer = self.buffer[excess:]
            self.buffer_start += excess / self.settings.sample_rate

    def split(self, raw: list[RawSegment], *, finalize_all: bool) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Teilt Whisper-Segmente in final/partial und kürzt den Puffer hinter dem letzten finalen.

        Ein Segment wird nur final, wenn es alt genug ist (Sicherheitsabstand) und zusätzlich an einer
        Pause oder einem Satzende endet; andernfalls erst, wenn es `finalize_force_seconds` zurückliegt.
        Der Puffer wird dann an der leisesten Stelle kurz hinter dem Segmentende geschnitten, damit kein
        angeschnittenes Wort in das nächste Fenster wandert.

        Überlaufschutz: Audio, das beim nächsten Segment vorn aus dem Fenster fallen würde, darf nicht
        nur vorläufig gewesen sein. Deshalb wird jedes Segment, dessen Anfang in diesem Bereich liegt,
        finalisiert, notfalls auch ohne Pause und innerhalb des Sicherheitsabstands.
        """
        settings = self.settings
        cutoff = self.buffer_end if finalize_all else self.buffer_end - settings.finalize_margin_seconds
        force_before = self.buffer_end - settings.finalize_force_seconds
        # Alles, was vor dieser Marke beginnt, würde beim nächsten Segment aus dem Fenster fallen.
        overflow_before = self.buffer_end - (settings.window_seconds - settings.max_segment_seconds)
        ordered = sorted(raw, key=lambda s: s.start)
        final: list[dict[str, Any]] = []
        partial: list[dict[str, Any]] = []
        last_final_end_rel: float | None = None
        next_partial_start_rel: float | None = None
        for index, segment in enumerate(ordered):
            abs_start = self.buffer_start + segment.start
            abs_end = self.buffer_start + segment.end
            if finalize_all:
                accept = True
            elif partial:
                accept = False
            elif abs_start <= overflow_before:
                accept = True  # Überlaufschutz: sonst ginge dieser Text verloren
            elif abs_end > cutoff:
                accept = False
            else:
                next_start = ordered[index + 1].start if index + 1 < len(ordered) else None
                has_pause = next_start is None or (next_start - segment.end) >= settings.finalize_min_gap_seconds
                ends_sentence = segment.text.rstrip().endswith((".", "!", "?"))
                forced = abs_end <= force_before
                accept = has_pause or ends_sentence or forced
            if accept:
                final.append(_segment_json(abs_start, abs_end, segment.text))
                last_final_end_rel = segment.end
                self._remember_final_text(segment.text)
            else:
                if not partial:
                    next_partial_start_rel = segment.start
                partial.append(_segment_json(abs_start, abs_end, segment.text))
        if finalize_all:
            self.buffer = np.zeros(0, dtype="<i2")
            self.buffer_start = self.timeline_end
        elif last_final_end_rel is not None:
            cut_rel = self._quiet_cut(last_final_end_rel, next_partial_start_rel)
            cut = min(len(self.buffer), int(cut_rel * settings.sample_rate))
            self.buffer = self.buffer[cut:]
            self.buffer_start += cut / settings.sample_rate
        return final, partial

    def _remember_final_text(self, text: str) -> None:
        """Merkt sich die letzten `prompt_max_chars` Zeichen finalen Texts; 0 schaltet den Prompt ab."""
        limit = self.settings.prompt_max_chars
        if limit <= 0:
            self.recent_final_text = ""
            return
        self.recent_final_text = (self.recent_final_text + " " + text.strip())[-limit:].strip()

    def _quiet_cut(self, end_rel: float, limit_rel: float | None) -> float:
        """Leiseste 50-ms-Stelle zwischen `end_rel` und `end_rel + cut_search_seconds` (vor `limit_rel`)."""
        rate = self.settings.sample_rate
        frame = int(0.05 * rate)
        search_end = end_rel + self.settings.cut_search_seconds
        if limit_rel is not None:
            search_end = min(search_end, limit_rel)
        search_end = min(search_end, len(self.buffer) / rate)
        start_idx = int(end_rel * rate)
        end_idx = int(search_end * rate)
        if end_idx - start_idx < frame:
            return end_rel
        window = self.buffer[start_idx:end_idx].astype(np.float32)
        frames = len(window) // frame
        energies = (window[: frames * frame].reshape(frames, frame) ** 2).mean(axis=1)
        quietest = int(np.argmin(energies))
        # Mitte des leisesten Rahmens
        return (start_idx + quietest * frame + frame // 2) / rate


class SessionStore:
    def __init__(self, settings: Settings, transcriber: Transcriber, now: Callable[[], float] = time.monotonic) -> None:
        self._settings = settings
        self._transcriber = transcriber
        self._now = now
        self._sessions: dict[str, Session] = {}
        self._lock = asyncio.Lock()

    @property
    def active_count(self) -> int:
        return sum(1 for s in self._sessions.values() if not s.finished)

    async def _get_or_create(self, session_id: str, sequence: int, language: str) -> Session:
        async with self._lock:
            session = self._sessions.get(session_id)
            if session is None:
                if sequence != 0:
                    raise SessionError(409, "sequence_gap", "Unbekannte Session muss mit Sequenz 0 beginnen.")
                if self.active_count >= self._settings.max_sessions:
                    raise SessionError(429, "too_many_sessions", "Zu viele gleichzeitige Sessions.")
                now = self._now()
                session = Session(session_id=session_id, language=language, settings=self._settings, created_at=now, last_activity=now)
                self._sessions[session_id] = session
                log.info("session=%s start language=%s", session_id, language)
            return session

    async def handle_segment(self, session_id: str, sequence: int, language: str, samples: np.ndarray) -> dict[str, Any]:
        session = await self._get_or_create(session_id, sequence, language)
        if session.inflight >= self._settings.max_inflight_per_session:
            raise SessionError(429, "too_many_requests", "Zu viele gleichzeitige Anfragen für diese Session.")
        session.inflight += 1
        try:
            async with session.lock:
                return await self._process(session, sequence, samples)
        finally:
            session.inflight -= 1

    async def _process(self, session: Session, sequence: int, samples: np.ndarray) -> dict[str, Any]:
        if sequence in session.responses:
            log.info("session=%s seq=%d replay", session.session_id, sequence)
            return session.responses[sequence]
        if session.finished:
            raise SessionError(409, "session_finished", "Session ist bereits beendet.")
        if sequence != session.last_sequence + 1:
            raise SessionError(409, "sequence_gap", "Sequenznummer passt nicht zur letzten.")
        if self._now() - session.created_at > self._settings.max_session_seconds:
            await self._finish_locked(session)
            raise SessionError(409, "session_finished", "Maximale Sessiondauer erreicht.")

        # Zustand sichern: Schlägt die Inferenz fehl (503, Client wiederholt), darf das Audio nicht
        # doppelt im Puffer landen.
        snapshot = (session.buffer, session.buffer_start, session.timeline_end)
        session.append(samples, sequence)
        window_start, window_end = session.buffer_start, session.buffer_end
        started = time.perf_counter()
        try:
            raw = await self._transcriber.transcribe(session.buffer, session.language, prompt=session.recent_final_text or None)
        except Exception:
            session.buffer, session.buffer_start, session.timeline_end = snapshot
            raise
        elapsed = time.perf_counter() - started
        final, partial = session.split(raw, finalize_all=False)

        session.last_sequence = sequence
        session.last_activity = self._now()
        window_seconds = max(window_end - window_start, 1e-6)
        response = {
            "sessionId": session.session_id,
            "sequence": sequence,
            "windowStart": round(window_start, 2),
            "windowEnd": round(window_end, 2),
            "final": final,
            "partial": partial,
            "diagnostics": {
                "serverLatencyMs": int(elapsed * 1000),
                "realtimeFactor": round(elapsed / window_seconds, 3),
                "queuedSegments": max(session.inflight - 1, 0),
            },
        }
        session.responses[sequence] = response
        log.info(
            "session=%s seq=%d window=%.1fs latency=%dms final=%d partial=%d",
            session.session_id, sequence, window_seconds, int(elapsed * 1000), len(final), len(partial),
        )
        return response

    async def finish(self, session_id: str) -> dict[str, Any]:
        async with self._lock:
            session = self._sessions.get(session_id)
        if session is None:
            raise SessionError(404, "session_unknown", "Session unbekannt.")
        async with session.lock:
            return await self._finish_locked(session)

    async def _finish_locked(self, session: Session) -> dict[str, Any]:
        if session.finished and session.finish_response is not None:
            return session.finish_response
        final: list[dict[str, Any]] = []
        min_samples = int(0.1 * self._settings.sample_rate)
        if len(session.buffer) > min_samples:
            raw = await self._transcriber.transcribe(session.buffer, session.language, prompt=session.recent_final_text or None)
            final, _ = session.split(raw, finalize_all=True)
        else:
            session.split([], finalize_all=True)
        session.finished = True
        session.last_activity = self._now()
        session.finish_response = {
            "sessionId": session.session_id,
            "lastSequence": session.last_sequence,
            "final": final,
            "partial": [],
        }
        # Wiederholte finish-Aufrufe liefern dieselbe Antwort (Vertrag: Replay, damit bei verlorener
        # Antwort keine finalen Segmente verloren gehen).
        log.info("session=%s finish lastSequence=%d final=%d", session.session_id, session.last_sequence, len(final))
        return session.finish_response

    async def sweep(self) -> int:
        """Beendet inaktive Sessions und entfernt beendete nach Ablauf des Timeouts."""
        now = self._now()
        timeout = self._settings.session_idle_timeout_seconds
        removed = 0
        async with self._lock:
            candidates = list(self._sessions.values())
        for session in candidates:
            if now - session.last_activity < timeout:
                continue
            async with session.lock:
                if not session.finished:
                    log.info("session=%s timeout", session.session_id)
                    try:
                        await self._finish_locked(session)
                    except Exception:  # noqa: BLE001
                        # Abschluss-Inferenz fehlgeschlagen: Session trotzdem freigeben, sonst bleiben
                        # die Slots bei Whisper-Ausfall dauerhaft belegt.
                        log.warning("session=%s timeout ohne Abschluss-Transkription", session.session_id)
                        session.finished = True
                async with self._lock:
                    self._sessions.pop(session.session_id, None)
                removed += 1
        return removed

    async def run_sweeper(self, interval_seconds: float = 5.0) -> None:
        while True:
            await asyncio.sleep(interval_seconds)
            try:
                await self.sweep()
            except Exception:  # noqa: BLE001
                log.exception("sweep fehlgeschlagen")

"""Session-Engine für das NeMo-Backend: Segmente in eine Realtime-Sitzung streamen.

Im Gegensatz zum Whisper-Pfad gibt es keinen Rollpuffer und keine Finalisierungsregeln: Das Modell
liefert selbst vorläufige Token (`delta`) und abgeschlossene Äußerungen (`completed`). Jede
abgeschlossene Äußerung wird ein finales Segment, der konkatenierte vorläufige Text das eine
`partial`-Segment der Antwort.
"""
from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING, Any, Callable

import numpy as np

from .config import Settings
from .nemo_realtime import NemoRealtimeError, NemoRealtimeSession

if TYPE_CHECKING:
    from .sessions import Session

log = logging.getLogger("asr_adapter.nemo")

SessionFactory = Callable[[], NemoRealtimeSession]


def _segment_json(start: float, end: float, text: str, speaker: str | None = None) -> dict[str, Any]:
    segment: dict[str, Any] = {"start": round(start, 2), "end": round(end, 2), "text": text}
    if speaker is not None:
        segment["speaker"] = speaker
    return segment


class NemoSessionEngine:
    def __init__(self, settings: Settings, factory: SessionFactory | None = None) -> None:
        self._settings = settings
        self._factory = factory or (
            lambda: NemoRealtimeSession(
                url=settings.nemo_url,
                api_key=settings.nemo_api_key,
                endpointing_ms=settings.nemo_endpointing_ms or None,
                sample_rate=settings.sample_rate,
                speaker_diarization=settings.nemo_speaker_diarization,
            )
        )

    async def _stream(self, session: Session) -> NemoRealtimeSession:
        stream: NemoRealtimeSession | None = session.nemo
        if stream is not None and stream.failed is not None:
            # Abgerissene Verbindung: verwerfen, beim nächsten Segment neu verbinden. Der Text der
            # alten Sitzung ist weg, die Zeitachse läuft weiter; die App markiert das Ergebnis als
            # unvollständig, weil sie 503 bekommen hat.
            await stream.close()
            session.nemo_offset = session.sent_seconds
            stream = None
        if stream is None:
            stream = self._factory()
            await stream.open(session.language)
            session.nemo = stream
        return stream

    async def process(self, session: Session, sequence: int, samples: np.ndarray) -> dict[str, Any]:
        settings = self._settings
        if sequence > 0:
            drop = int(settings.overlap_seconds * settings.sample_rate)
            samples = samples[min(drop, len(samples)) :]
        pcm = np.ascontiguousarray(samples, dtype="<i2").tobytes()
        seconds = len(samples) / settings.sample_rate

        started = time.perf_counter()
        stream = await self._stream(session)
        sent_before = session.sent_seconds
        try:
            await stream.feed(pcm)
            session.sent_seconds += seconds
            if settings.nemo_settle_seconds > 0:
                await stream.wait_processed(session.sent_seconds - session.nemo_offset, settings.nemo_settle_seconds)
            if stream.failed is not None:
                raise NemoRealtimeError(stream.failed)
        except NemoRealtimeError:
            # 503 für dieses Segment: Die App wiederholt es, dann darf die Zeitachse nicht doppelt wachsen.
            session.sent_seconds = sent_before
            raise
        elapsed = time.perf_counter() - started

        window_start = session.last_final_end
        final, partial = self._collect(session, stream, window_end=session.sent_seconds)
        response = {
            "sessionId": session.session_id,
            "sequence": sequence,
            "windowStart": round(window_start, 2),
            "windowEnd": round(session.sent_seconds, 2),
            "final": final,
            "partial": partial,
            "diagnostics": {
                "serverLatencyMs": int(elapsed * 1000),
                "realtimeFactor": round(elapsed / max(seconds, 1e-6), 3),
                "queuedSegments": max(session.inflight - 1, 0),
            },
        }
        log.info(
            "session=%s seq=%d sent=%.1fs latency=%dms final=%d partial=%d",
            session.session_id, sequence, session.sent_seconds, int(elapsed * 1000), len(final), len(partial),
        )
        return response

    async def finish(self, session: Session) -> list[dict[str, Any]]:
        stream: NemoRealtimeSession | None = session.nemo
        if stream is None:
            return []
        try:
            await stream.finish(timeout=self._settings.nemo_finish_timeout_seconds)
        finally:
            session.nemo = None
        if stream.failed is not None:
            log.warning("session=%s finish ohne sauberen Abschluss: %s", session.session_id, stream.failed)
        final, partial = self._collect(session, stream, window_end=session.sent_seconds)
        # Ohne abschließendes `completed` (z. B. Endpointing greift nicht) bleibt der vorläufige Text
        # übrig; beim Abschluss wird er final, damit nichts verloren geht.
        for item in partial:
            final.append(item)
            session.last_final_end = max(session.last_final_end, item["end"])
        return final

    def _collect(self, session: Session, stream: NemoRealtimeSession, *, window_end: float) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        offset = session.nemo_offset
        finals, partial_text = stream.snapshot()
        final = [_segment_json(offset + f.start, offset + f.end, f.text, f.speaker) for f in finals]
        if final:
            session.last_final_end = max(session.last_final_end, final[-1]["end"])
        partial: list[dict[str, Any]] = []
        if partial_text:
            partial.append(_segment_json(session.last_final_end, max(window_end, session.last_final_end), partial_text))
        return final, partial

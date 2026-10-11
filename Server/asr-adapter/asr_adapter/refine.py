"""Genaue Nach-Transkription einer ganzen Aufnahme („Genau transkribieren“ in der App).

Die Live-Mitschrift entsteht mit einem schnellen Streaming-Modell. Nach der Aufnahme kann die App die
Audiodatei hochladen; der Adapter transkribiert sie dann am Stück mit einem genaueren Modell
(whisper-server, z. B. large-v3) und holt die Sprechertrennung vom NeMo-Server (Wörter mit
Sprechernummer). Jedes Whisper-Wort bekommt den Sprecher des zeitlich passenden NeMo-Worts; an
Sprecherwechseln werden die Whisper-Abschnitte geteilt.

Weil das bei langen Aufnahmen Minuten dauert, läuft es als Auftrag: POST legt ihn an, GET fragt ab.
"""
from __future__ import annotations

import asyncio
import io
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx
import numpy as np

from .wav import SAMPLE_RATE, write_wav

log = logging.getLogger("asr_adapter.refine")


class RefineError(RuntimeError):
    """Fehler mit einer Meldung, die ohne Inhalte an die App gehen darf."""


@dataclass(frozen=True)
class Word:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class WhisperSegment:
    start: float
    end: float
    text: str
    words: list[Word]
    no_speech_prob: float = 0.0
    avg_logprob: float = 0.0
    #: Der Abschnitt beginnt mitten im Wort des vorigen (Rohtext ohne führendes Leerzeichen).
    continues: bool = False


@dataclass(frozen=True)
class SpeakerSpan:
    """Ein Zeitraum, in dem ein Sprecher spricht (aus der Sprechertrennung)."""

    start: float
    end: float
    speaker: str


# --- Audio ---


def decode_audio(data: bytes) -> np.ndarray:
    """Beliebige Audiodatei (M4A/AAC, WAV, CAF …) → 16 kHz mono Int16."""
    import av  # erst hier, damit Tests ohne Audiodateien schnell bleiben

    try:
        container = av.open(io.BytesIO(data))
    except (av.error.FFmpegError, ValueError) as error:
        raise RefineError("Die Audiodatei konnte nicht gelesen werden.") from error
    try:
        stream = next((s for s in container.streams if s.type == "audio"), None)
        if stream is None:
            raise RefineError("Die Datei enthält keine Tonspur.")
        resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)
        chunks: list[np.ndarray] = []
        for frame in container.decode(stream):
            for converted in resampler.resample(frame):
                chunks.append(converted.to_ndarray().reshape(-1))
        for converted in resampler.resample(None):
            chunks.append(converted.to_ndarray().reshape(-1))
    except av.error.FFmpegError as error:
        raise RefineError("Die Audiodatei konnte nicht dekodiert werden.") from error
    finally:
        container.close()
    if not chunks:
        raise RefineError("Die Audiodatei ist leer.")
    return np.concatenate(chunks).astype("<i2")


# --- Backends ---


class RefineTranscriber(Protocol):
    async def transcribe_file(self, samples: np.ndarray, language: str) -> list[WhisperSegment]: ...

    async def aclose(self) -> None: ...


class Diarizer(Protocol):
    async def diarize(self, samples: np.ndarray, language: str) -> list[SpeakerSpan]: ...

    async def aclose(self) -> None: ...


class WhisperFileClient:
    """POST /inference an whisper-server mit `verbose_json`: Abschnitte samt Wortzeiten."""

    def __init__(self, base_url: str, timeout_seconds: float = 1800.0) -> None:
        self._client = httpx.AsyncClient(base_url=base_url, timeout=timeout_seconds)

    async def transcribe_file(self, samples: np.ndarray, language: str) -> list[WhisperSegment]:
        files = {"file": ("aufnahme.wav", write_wav(samples), "audio/wav")}
        data = {"response_format": "verbose_json", "temperature": "0"}
        if language and language != "auto":
            data["language"] = language
        try:
            response = await self._client.post("/inference", files=files, data=data)
        except httpx.HTTPError as error:
            raise RefineError(f"whisper-server nicht erreichbar: {type(error).__name__}") from error
        if response.status_code != 200:
            raise RefineError(f"whisper-server antwortete mit HTTP {response.status_code}")
        try:
            return parse_whisper_verbose(response.json())
        except (ValueError, KeyError, TypeError) as error:
            raise RefineError("whisper-server lieferte kein verwertbares Ergebnis") from error

    async def aclose(self) -> None:
        await self._client.aclose()


def parse_whisper_verbose(payload: dict[str, Any]) -> list[WhisperSegment]:
    """Abschnitte aus `verbose_json`; Wortstücke ohne führendes Leerzeichen („ abyte“) hängen am Vorwort."""
    segments: list[WhisperSegment] = []
    for item in payload.get("segments", []):
        raw_text = str(item.get("text", ""))
        text = raw_text.strip()
        if not text:
            continue
        words: list[Word] = []
        for raw in item.get("words") or []:
            piece = str(raw.get("word", ""))
            if not piece.strip():
                continue
            start, end = float(raw["start"]), float(raw["end"])
            if words and not piece.startswith(" "):
                last = words[-1]
                words[-1] = Word(last.start, max(last.end, end), last.text + piece.strip())
            else:
                words.append(Word(start, end, piece.strip()))
        segments.append(
            WhisperSegment(
                start=float(item["start"]),
                end=float(item["end"]),
                text=text,
                words=words,
                no_speech_prob=float(item.get("no_speech_prob") or 0.0),
                avg_logprob=float(item.get("avg_logprob") or 0.0),
                continues=bool(segments) and not raw_text.startswith(" "),
            )
        )
    return segments


class NemoDiarizer:
    """Sprechersegmente über `POST /v1/audio/diarizations` von `nemo-speech serve` (Sortformer, Streaming-Modus
    auch für lange Aufnahmen). Unabhängig von der Worterkennung des Streaming-Modells."""

    def __init__(self, base_url: str, api_key: str | None = None, timeout_seconds: float = 1800.0) -> None:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.AsyncClient(base_url=base_url, headers=headers, timeout=timeout_seconds)

    async def diarize(self, samples: np.ndarray, language: str) -> list[SpeakerSpan]:
        files = {"file": ("aufnahme.wav", write_wav(samples), "audio/wav")}
        try:
            response = await self._client.post("/v1/audio/diarizations", files=files, data={"mode": "streaming"})
        except httpx.HTTPError as error:
            raise RefineError(f"NeMo-Server nicht erreichbar: {type(error).__name__}") from error
        if response.status_code != 200:
            raise RefineError(f"NeMo-Server antwortete mit HTTP {response.status_code}")
        try:
            return [
                SpeakerSpan(float(item["start"]), float(item["end"]), str(item["speaker"]))
                for item in response.json().get("segments") or []
            ]
        except (ValueError, KeyError, TypeError) as error:
            raise RefineError("NeMo-Server lieferte keine Sprechersegmente") from error

    async def aclose(self) -> None:
        await self._client.aclose()


# --- Zusammenführen ---


def assign_speakers(words: list[Word], spans: list[SpeakerSpan], max_distance: float = 1.5) -> list[str | None]:
    """Je Wort der Sprecher der Spanne mit der größten Überlappung, sonst der nächstgelegenen (höchstens
    `max_distance` Sekunden entfernt), sonst `None`."""
    if not spans or not words:
        return [None] * len(words)
    starts = np.array([s.start for s in spans])
    ends = np.array([s.end for s in spans])
    result: list[str | None] = []
    for word in words:
        overlap = np.minimum(word.end, ends) - np.maximum(word.start, starts)
        best = int(np.argmax(overlap))
        if overlap[best] > 0:
            result.append(spans[best].speaker)
            continue
        distance = np.maximum(starts - word.end, word.start - ends)
        nearest = int(np.argmin(distance))
        result.append(spans[nearest].speaker if distance[nearest] <= max_distance else None)
    return result


def likely_hallucination(segment: WhisperSegment, speaker_spans: list[SpeakerSpan]) -> bool:
    """Whisper erfindet in Stille gern Sätze („Untertitel im Auftrag des ZDF“). Ein Abschnitt gilt als
    erfunden, wenn das Streaming-Modell dort nichts gehört hat und Whisper selbst unsicher ist."""
    heard = any(w.end > segment.start - 0.5 and w.start < segment.end + 0.5 for w in speaker_spans)
    if heard:
        return False
    return segment.no_speech_prob >= 0.5 or segment.avg_logprob <= -0.8


#: Satzende: danach beginnt ein neuer Abschnitt.
_SENTENCE_END = (".", "?", "!", "…", ".«", "?«", "!«", ".“", "?“", "!“", '."', '?"', '!"')


def flatten_words(whisper: list[WhisperSegment], speaker_spans: list[SpeakerSpan] | None) -> list[Word]:
    """Alle Wörter am Stück. whisper-server teilt Abschnitte auch mitten im Wort („Ausein“ | „andersetzung“);
    deshalb werden Wortstücke über Abschnittsgrenzen verbunden. Mutmaßliche Halluzinationen fallen weg."""
    words: list[Word] = []
    for segment in whisper:
        if speaker_spans and likely_hallucination(segment, speaker_spans):
            continue
        pieces = segment.words or [Word(segment.start, segment.end, segment.text)]
        for index, word in enumerate(pieces):
            if index == 0 and words and segment.continues:
                last = words[-1]
                words[-1] = Word(last.start, max(last.end, word.end), last.text + word.text)
            else:
                words.append(word)
    return words


def _fill(speakers: list[str | None]) -> list[str | None]:
    """Lücken ohne Sprecher erben den nächsten bekannten (am Anfang) bzw. den vorigen."""
    filled = list(speakers)
    following: str | None = None
    for index in range(len(filled) - 1, -1, -1):
        if filled[index] is None:
            filled[index] = following
        else:
            following = filled[index]
    previous: str | None = None
    for index, speaker in enumerate(filled):
        if speaker is None:
            filled[index] = previous
        else:
            previous = speaker
    return filled


def _smooth_sentence(speakers: list[str | None], durations: list[float], min_run: int = 4) -> list[str | None]:
    """Innerhalb eines Satzes zählen nur Sprecherwechsel ab `min_run` Wörtern; kürzere Läufe gehören zum
    längeren Nachbarn (Wortzeiten von Whisper und NeMo weichen um Zehntelsekunden ab). Sätze unter
    `min_run` Wörtern bekommen den Sprecher mit der meisten Sprechzeit."""
    if len(speakers) < min_run:
        totals: dict[str | None, float] = {}
        for speaker, duration in zip(speakers, durations):
            totals[speaker] = totals.get(speaker, 0.0) + duration
        winner = max(totals, key=lambda k: totals[k]) if totals else None
        return [winner] * len(speakers)
    runs: list[list] = []  # [speaker, length]
    for speaker in speakers:
        if runs and runs[-1][0] == speaker:
            runs[-1][1] += 1
        else:
            runs.append([speaker, 1])
    changed = True
    while changed and len(runs) > 1:
        changed = False
        for index, (speaker, length) in enumerate(runs):
            if length >= min_run:
                continue
            left = runs[index - 1] if index > 0 else None
            right = runs[index + 1] if index + 1 < len(runs) else None
            target = left if right is None or (left is not None and left[1] >= right[1]) else right
            target[1] += length
            del runs[index]
            merged: list[list] = []
            for run in runs:
                if merged and merged[-1][0] == run[0]:
                    merged[-1][1] += run[1]
                else:
                    merged.append(run)
            runs = merged
            changed = True
            break
    return [speaker for speaker, length in runs for _ in range(length)]


def build_segments(
    whisper: list[WhisperSegment],
    speaker_spans: list[SpeakerSpan] | None,
    max_pause: float = 1.5,
    max_seconds: float = 30.0,
) -> list[dict[str, Any]]:
    """Abschnitte für die App, etwa satzweise: neuer Abschnitt nach einem Satzende, bei einer Pause über
    `max_pause`, bei einem Sprecherwechsel und spätestens nach `max_seconds`. Sprecherlabels „1“, „2“, …
    in Reihenfolge des ersten Auftretens; ohne Sprechertrennung (`None`) ohne Label."""
    words = flatten_words(whisper, speaker_spans)
    if not words:
        return []
    if speaker_spans:
        speakers = _fill(assign_speakers(words, speaker_spans))
    else:
        speakers = [None] * len(words)

    # Sätze bilden und Sprecher je Satz glätten
    sentences: list[tuple[int, int]] = []
    begin = 0
    for index, word in enumerate(words):
        last = index == len(words) - 1
        pause = not last and words[index + 1].start - word.end > max_pause
        if last or pause or word.text.endswith(_SENTENCE_END):
            sentences.append((begin, index + 1))
            begin = index + 1
    if speaker_spans:
        for a, b in sentences:
            speakers[a:b] = _smooth_sentence(speakers[a:b], [w.end - w.start for w in words[a:b]])

    renumber: dict[str, str] = {}

    def label(raw: str | None) -> str | None:
        if raw is None:
            return None
        if raw not in renumber:
            renumber[raw] = str(len(renumber) + 1)
        return renumber[raw]

    out: list[dict[str, Any]] = []
    for a, b in sentences:
        if _repeats_previous(words[a:b], out):
            continue
        run_start = a
        for index in range(a, b + 1):
            boundary = index == b or speakers[index] != speakers[run_start] or words[index].end - words[run_start].start > max_seconds
            if boundary and index > run_start:
                out.append(_segment(words[run_start:index], label(speakers[run_start])))
                run_start = index
    return out


def _repeats_previous(sentence: list[Word], out: list[dict[str, Any]], min_words: int = 4) -> bool:
    """Whisper kann in Wiederholungsschleifen geraten („Und das war ein sehr guter Satz.“ alle zwei Sekunden).
    Ein Satz ab `min_words` Wörtern, der wörtlich dem vorigen gleicht, gilt als Schleife."""
    if len(sentence) < min_words or not out:
        return False
    normalize = lambda text: " ".join(text.lower().split())  # noqa: E731
    return normalize(" ".join(w.text for w in sentence)) == normalize(out[-1]["text"])


def _segment(words: list[Word], speaker: str | None) -> dict[str, Any]:
    return {
        "start": round(words[0].start, 3),
        "end": round(words[-1].end, 3),
        "text": " ".join(w.text for w in words),
        "speaker": speaker,
    }


# --- Aufträge ---


@dataclass
class RefineJob:
    id: str
    language: str
    created: float = field(default_factory=time.monotonic)
    status: str = "queued"  # queued | running | done | failed
    phase: str | None = None  # decoding | transcribing | diarizing
    duration_seconds: float | None = None
    started: float | None = None
    finished: float | None = None
    segments: list[dict[str, Any]] | None = None
    diarization: bool = False
    message: str | None = None

    def to_json(self, model: str) -> dict[str, Any]:
        now = self.finished or time.monotonic()
        body: dict[str, Any] = {
            "id": self.id,
            "status": self.status,
            "model": model,
            "elapsedSeconds": round(now - (self.started or self.created), 1) if self.started else 0.0,
            "queuedSeconds": round((self.started or now) - self.created, 1),
        }
        if self.phase:
            body["phase"] = self.phase
        if self.duration_seconds is not None:
            body["durationSeconds"] = round(self.duration_seconds, 2)
        if self.status == "done":
            body["segments"] = self.segments or []
            body["diarization"] = self.diarization
        if self.message:
            body["message"] = self.message
        return body


class RefineJobs:
    """Hält Aufträge im Speicher und arbeitet sie nacheinander ab (whisper-server rechnet ohnehin seriell).
    Fertige Aufträge verfallen nach `ttl_seconds`; der Adapter speichert weder Audio noch Text."""

    def __init__(
        self,
        transcriber: RefineTranscriber,
        diarizer: Diarizer | None,
        model_name: str,
        max_jobs: int = 8,
        ttl_seconds: float = 3600.0,
    ) -> None:
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.model_name = model_name
        self.max_jobs = max_jobs
        self.ttl_seconds = ttl_seconds
        self._jobs: dict[str, RefineJob] = {}
        self._lock = asyncio.Lock()
        self._tasks: set[asyncio.Task[None]] = set()

    def get(self, job_id: str) -> RefineJob | None:
        self._expire()
        return self._jobs.get(job_id)

    def open_count(self) -> int:
        return sum(1 for job in self._jobs.values() if job.status in {"queued", "running"})

    def submit(self, data: bytes, language: str) -> RefineJob:
        self._expire()
        if self.open_count() >= self.max_jobs:
            raise RefineError("Zu viele Aufträge in der Warteschlange.")
        job = RefineJob(id=str(uuid.uuid4()), language=language)
        self._jobs[job.id] = job
        task = asyncio.create_task(self._run(job, data))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return job

    async def _run(self, job: RefineJob, data: bytes) -> None:
        async with self._lock:
            job.status = "running"
            job.started = time.monotonic()
            try:
                job.phase = "decoding"
                samples = await asyncio.to_thread(decode_audio, data)
                del data
                job.duration_seconds = len(samples) / SAMPLE_RATE
                job.phase = "transcribing"
                whisper = await self.transcriber.transcribe_file(samples, job.language)
                speaker_spans: list[SpeakerSpan] | None = None
                if self.diarizer is not None:
                    job.phase = "diarizing"
                    try:
                        speaker_spans = await self.diarizer.diarize(samples, job.language)
                    except RefineError as error:
                        # Ohne Sprecher ist die genaue Fassung immer noch besser als keine.
                        log.warning("Sprechertrennung für die Nach-Transkription fehlgeschlagen: %s", error)
                job.segments = build_segments(whisper, speaker_spans)
                job.diarization = speaker_spans is not None
                job.status = "done"
                log.info(
                    "Nach-Transkription fertig: %.0f s Audio, %d Abschnitte, %.1f s Rechenzeit",
                    job.duration_seconds, len(job.segments), time.monotonic() - job.started,
                )
            except RefineError as error:
                job.status = "failed"
                job.message = str(error)
                log.warning("Nach-Transkription fehlgeschlagen: %s", error)
            except Exception as error:  # noqa: BLE001 - der Auftrag soll sauber als fehlgeschlagen enden
                job.status = "failed"
                job.message = "Interner Fehler bei der Nach-Transkription."
                log.exception("Nach-Transkription: unerwarteter Fehler %s", type(error).__name__)
            finally:
                job.phase = None
                job.finished = time.monotonic()

    def _expire(self) -> None:
        now = time.monotonic()
        for job_id in [j.id for j in self._jobs.values() if j.finished and now - j.finished > self.ttl_seconds]:
            del self._jobs[job_id]

    async def aclose(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        await self.transcriber.aclose()
        if self.diarizer is not None:
            await self.diarizer.aclose()

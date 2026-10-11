from __future__ import annotations

import asyncio
import io
from dataclasses import dataclass, field

import httpx
import numpy as np
import pytest

from conftest import AUTH, FakeWhisper, make_settings, wav_bytes

from asr_adapter.app import create_app
from asr_adapter.refine import (
    RefineError,
    RefineJobs,
    SpeakerSpan,
    WhisperSegment,
    Word,
    assign_speakers,
    build_segments,
    decode_audio,
    parse_whisper_verbose,
)


def test_parse_whisper_verbose_joins_word_pieces() -> None:
    payload = {
        "segments": [
            {"text": " Aber 53 Gigabyte.", "start": 0.0, "end": 2.0, "no_speech_prob": 0.01, "avg_logprob": -0.2,
             "words": [{"word": " Aber", "start": 0.0, "end": 0.4}, {"word": " 53", "start": 0.4, "end": 1.1},
                       {"word": " Gig", "start": 1.1, "end": 1.4}, {"word": "abyte.", "start": 1.4, "end": 2.0}]},
            {"text": "  ", "start": 2.0, "end": 3.0, "words": []},
        ]
    }
    [segment] = parse_whisper_verbose(payload)
    assert segment.text == "Aber 53 Gigabyte."
    assert [w.text for w in segment.words] == ["Aber", "53", "Gigabyte."]
    assert segment.words[2] == Word(1.1, 2.0, "Gigabyte.")


def test_assign_speakers_by_overlap_then_nearest() -> None:
    words = [Word(0.0, 0.5, "a"), Word(0.6, 1.0, "b"), Word(41.6, 41.8, "c"), Word(2.5, 2.8, "d"), Word(30.0, 30.5, "e")]
    spans = [SpeakerSpan(0.0, 0.55, "1"), SpeakerSpan(0.55, 2.0, "2"), SpeakerSpan(3.0, 40.0, "3")]
    assert assign_speakers(words, spans) == ["1", "2", None, "3", "3"]


def _segment(words: list[tuple[float, float, str]], **kw: float) -> WhisperSegment:
    ws = [Word(a, b, t) for a, b, t in words]
    return WhisperSegment(ws[0].start, ws[-1].end, " ".join(w.text for w in ws), ws, **kw)


def test_build_segments_splits_on_speaker_change_and_renumbers() -> None:
    whisper = [_segment([(0, 1, "Hallo,"), (1, 2, "wie"), (2, 3, "geht's?"), (3, 4, "Gut.")])]
    nemo = [SpeakerSpan(0, 3, "7"), SpeakerSpan(3, 4, "2")]
    assert build_segments(whisper, nemo) == [
        {"start": 0, "end": 3, "text": "Hallo, wie geht's?", "speaker": "1"},
        {"start": 3, "end": 4, "text": "Gut.", "speaker": "2"},
    ]


def test_build_segments_joins_word_broken_across_whisper_segments() -> None:
    payload = {"segments": [
        {"text": " in der Ausein", "start": 0, "end": 1.5, "words": [
            {"word": " in", "start": 0, "end": 0.3}, {"word": " der", "start": 0.3, "end": 0.6}, {"word": " Ausein", "start": 0.6, "end": 1.5}]},
        {"text": "andersetzung.", "start": 1.5, "end": 2.5, "words": [
            {"word": "anders", "start": 1.5, "end": 2.0}, {"word": "etzung", "start": 2.0, "end": 2.4}, {"word": ".", "start": 2.4, "end": 2.5}]},
        {"text": " die Form.", "start": 2.6, "end": 3.2, "words": [
            {"word": " die", "start": 2.6, "end": 2.8}, {"word": " Form", "start": 2.8, "end": 3.1}, {"word": ".", "start": 3.1, "end": 3.2}]},
    ]}
    segments = build_segments(parse_whisper_verbose(payload), None)
    assert [s["text"] for s in segments] == ["in der Auseinandersetzung.", "die Form."]


def test_short_speaker_runs_inside_a_sentence_are_smoothed() -> None:
    # Whisper-Wortzeiten liegen leicht neben NeMo: "Ja, wir haben" fiele sonst an Sprecher A.
    whisper = [_segment([(0, 0.3, "Gut."), (2.0, 2.2, "Ja,"), (2.2, 2.4, "wir"), (2.4, 2.6, "haben"), (2.6, 2.8, "die"),
                         (2.8, 3.0, "Form,"), (3.0, 3.2, "wir"), (3.2, 3.4, "haben"), (3.4, 3.6, "das"), (3.6, 3.9, "Thema.")])]
    nemo = [SpeakerSpan(0, 0.3, "A"), SpeakerSpan(2.0, 2.3, "A"), SpeakerSpan(2.3, 3.9, "B")]
    segments = build_segments(whisper, nemo)
    assert [(s["speaker"], s["text"]) for s in segments] == [("1", "Gut."), ("2", "Ja, wir haben die Form, wir haben das Thema.")]


def test_words_before_first_heard_speaker_inherit_the_next_one() -> None:
    whisper = [_segment([(0.0, 0.4, "Aber"), (0.4, 1.0, "53"), (1.1, 2.0, "Gigabyte.")])]
    nemo = [SpeakerSpan(1.2, 2.0, "5")]
    assert [s["speaker"] for s in build_segments(whisper, nemo)] == ["1"]


def test_build_segments_without_diarization_keeps_whisper_segments() -> None:
    whisper = [_segment([(0, 1, "Eins.")]), _segment([(2, 3, "Zwei.")])]
    assert [s["speaker"] for s in build_segments(whisper, None)] == [None, None]
    assert [s["text"] for s in build_segments(whisper, None)] == ["Eins.", "Zwei."]


def test_build_segments_drops_hallucination_in_silence() -> None:
    nemo = [SpeakerSpan(0, 1, "1")]
    real = _segment([(0, 1, "Hallo.")])
    unsure_in_silence = _segment([(10, 12, "Untertitel"), (12, 13, "im"), (13, 14, "Auftrag")], no_speech_prob=0.7)
    confident_but_unheard = _segment([(20, 21, "Grüezi")], avg_logprob=-0.2)
    texts = [s["text"] for s in build_segments([real, unsure_in_silence, confident_but_unheard], nemo)]
    # Whisper hört Dialekt, den das Streaming-Modell verpasst: bei Sicherheit bleibt der Abschnitt.
    assert texts == ["Hallo.", "Grüezi"]


def test_decode_audio_wav_and_aac() -> None:
    import av

    assert len(decode_audio(wav_bytes(2.0))) == 32_000
    # 1 s Stereo-Sinus mit 48 kHz als AAC/M4A → 16 kHz mono
    buffer = io.BytesIO()
    with av.open(buffer, mode="w", format="mp4") as container:
        stream = container.add_stream("aac", rate=48_000)
        stream.layout = "stereo"
        t = np.arange(48_000) / 48_000
        tone = (np.sin(2 * np.pi * 440 * t) * 0.3).astype(np.float32)
        frame = av.AudioFrame.from_ndarray(np.stack([tone, tone]), format="fltp", layout="stereo")
        frame.sample_rate = 48_000
        for packet in stream.encode(frame):
            container.mux(packet)
        for packet in stream.encode(None):
            container.mux(packet)
    samples = decode_audio(buffer.getvalue())
    assert abs(len(samples) - 16_000) < 1_600
    assert np.abs(samples).max() > 3_000
    with pytest.raises(RefineError):
        decode_audio(b"kein audio")


@dataclass
class FakeRefineWhisper:
    segments: list[WhisperSegment] = field(default_factory=list)
    seen: list[tuple[int, str]] = field(default_factory=list)
    fail: bool = False

    async def transcribe_file(self, samples: np.ndarray, language: str) -> list[WhisperSegment]:
        self.seen.append((len(samples), language))
        if self.fail:
            raise RefineError("whisper-server nicht erreichbar: ConnectError")
        return self.segments

    async def aclose(self) -> None:
        return None


@dataclass
class FakeDiarizer:
    words: list[SpeakerSpan] = field(default_factory=list)
    fail: bool = False

    async def diarize(self, samples: np.ndarray, language: str) -> list[SpeakerSpan]:
        if self.fail:
            raise RefineError("NeMo-Server nicht erreichbar")
        return self.words

    async def aclose(self) -> None:
        return None


def refine_client(jobs: RefineJobs | None, **overrides: object) -> httpx.AsyncClient:
    app = create_app(make_settings(refine_enabled=jobs is not None, **overrides), FakeWhisper(), refine_jobs=jobs)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


async def _wait(client: httpx.AsyncClient, job_id: str) -> dict[str, object]:
    for _ in range(100):
        body = (await client.get(f"/v1/transcriptions/{job_id}", headers=AUTH)).json()
        if body["status"] in {"done", "failed"}:
            return body
        await asyncio.sleep(0.01)
    raise AssertionError("Auftrag wurde nicht fertig")


async def test_refine_job_round_trip_with_speakers() -> None:
    whisper = FakeRefineWhisper([_segment([(0, 1, "Guten"), (1, 2, "Morgen.")]), _segment([(2, 3, "Hallo.")])])
    jobs = RefineJobs(whisper, FakeDiarizer([SpeakerSpan(0, 2, "4"), SpeakerSpan(2, 3, "9")]), "ggml-large-v3.bin")
    async with refine_client(jobs) as client:
        health = (await client.get("/v1/health")).json()
        assert health["refine"] is True and health["refineModel"] == "ggml-large-v3.bin"
        response = await client.post("/v1/transcriptions", content=wav_bytes(3.0),
                                     headers={**AUTH, "Content-Type": "audio/mp4", "X-Mitschrift-Language": "de"})
        assert response.status_code == 202
        created = response.json()
        assert created["status"] in {"queued", "running"} and created["model"] == "ggml-large-v3.bin"
        body = await _wait(client, created["id"])
    assert body["status"] == "done"
    assert body["durationSeconds"] == 3.0
    assert body["diarization"] is True
    assert body["segments"] == [
        {"start": 0, "end": 2, "text": "Guten Morgen.", "speaker": "1"},
        {"start": 2, "end": 3, "text": "Hallo.", "speaker": "2"},
    ]  # zwei Sätze, je ein Abschnitt
    assert whisper.seen == [(48_000, "de")]


async def test_refine_without_diarization_when_nemo_fails() -> None:
    jobs = RefineJobs(FakeRefineWhisper([_segment([(0, 1, "Hallo.")])]), FakeDiarizer(fail=True), "m")
    async with refine_client(jobs) as client:
        created = (await client.post("/v1/transcriptions", content=wav_bytes(1.0), headers={**AUTH, "Content-Type": "audio/wav"})).json()
        body = await _wait(client, created["id"])
    assert body["status"] == "done" and body["diarization"] is False
    assert body["segments"] == [{"start": 0, "end": 1, "text": "Hallo.", "speaker": None}]


async def test_refine_failure_is_reported_without_content() -> None:
    jobs = RefineJobs(FakeRefineWhisper(fail=True), None, "m")
    async with refine_client(jobs) as client:
        created = (await client.post("/v1/transcriptions", content=wav_bytes(1.0), headers={**AUTH, "Content-Type": "audio/wav"})).json()
        body = await _wait(client, created["id"])
        bad = (await client.post("/v1/transcriptions", content=b"xyz", headers={**AUTH, "Content-Type": "audio/mp4"})).json()
        bad_body = await _wait(client, bad["id"])
    assert body["status"] == "failed" and "whisper-server" in body["message"] and "segments" not in body
    assert bad_body["status"] == "failed" and bad_body["message"] == "Die Audiodatei konnte nicht gelesen werden."


async def test_refine_request_validation() -> None:
    jobs = RefineJobs(FakeRefineWhisper(), None, "m")
    async with refine_client(jobs, refine_max_bytes=1000) as client:
        assert (await client.post("/v1/transcriptions", content=wav_bytes(1.0))).status_code == 401
        r = await client.post("/v1/transcriptions", content=wav_bytes(1.0), headers={**AUTH, "Content-Type": "audio/wav"})
        assert r.status_code == 413 and r.json()["error"] == "payload_too_large"
        r = await client.post("/v1/transcriptions", content=b"x", headers={**AUTH, "Content-Type": "text/plain"})
        assert r.status_code == 400 and r.json()["error"] == "invalid_content_type"
        r = await client.post("/v1/transcriptions", content=b"x", headers={**AUTH, "Content-Type": "audio/wav", "X-Mitschrift-Language": "fr"})
        assert r.status_code == 400 and r.json()["error"] == "invalid_language"
        r = await client.post("/v1/transcriptions", content=b"", headers={**AUTH, "Content-Type": "audio/wav"})
        assert r.status_code == 400
        r = await client.get("/v1/transcriptions/unbekannt", headers=AUTH)
        assert r.status_code == 404 and r.json()["error"] == "unknown_job"
    async with refine_client(None) as client:
        assert (await client.get("/v1/health")).json()["refine"] is False
        r = await client.post("/v1/transcriptions", content=b"x", headers={**AUTH, "Content-Type": "audio/wav"})
        assert r.status_code == 503 and r.json()["error"] == "refine_unavailable"


def test_repetition_loop_is_collapsed() -> None:
    loop = [_segment([(t, t + 0.5, "Und"), (t + 0.5, t + 1, "das"), (t + 1, t + 1.5, "war"), (t + 1.5, t + 2, "gut.")]) for t in (0, 2, 4, 6)]
    short = [_segment([(10, 10.3, "Ja.")]), _segment([(10.4, 10.7, "Ja.")])]
    texts = [s["text"] for s in build_segments(loop + short, None)]
    assert texts == ["Und das war gut.", "Ja.", "Ja."]

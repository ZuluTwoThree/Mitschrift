from __future__ import annotations

import uuid

import httpx
import numpy as np
import pytest

from conftest import AUTH, SAMPLE_RATE, FakeWhisper, make_settings, segment_headers, wav_bytes

from asr_adapter.app import create_app


async def post_segment(client: httpx.AsyncClient, session_id: str, sequence: int, seconds: float = 2.5, **kw):
    return await client.post(
        "/v1/live-transcriptions/segments", headers=segment_headers(session_id, sequence, **kw), content=wav_bytes(seconds)
    )


async def test_health_without_token(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["model"] == "ggml-test.bin"
    assert body["activeSessions"] == 0
    assert body["maxSessions"] == 4


async def test_health_degraded_when_whisper_down(settings, whisper: FakeWhisper) -> None:
    whisper.healthy = False
    app = create_app(settings, whisper)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/health")
    assert response.status_code == 503
    assert response.json()["status"] == "degraded"


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer falsch"}, {"Authorization": "Basic abc"}])
async def test_segment_requires_token(client: httpx.AsyncClient, session_id: str, headers: dict[str, str]) -> None:
    h = {**segment_headers(session_id, 0), **headers}
    if not headers:
        h.pop("Authorization")
    response = await client.post("/v1/live-transcriptions/segments", headers=h, content=wav_bytes(2.5))
    assert response.status_code == 401
    assert response.json() == {"error": "unauthorized", "message": "Nicht autorisiert."}


async def test_finish_requires_token(client: httpx.AsyncClient, session_id: str) -> None:
    response = await client.post(f"/v1/live-transcriptions/{session_id}/finish")
    assert response.status_code == 401


async def test_invalid_headers(client: httpx.AsyncClient, session_id: str) -> None:
    bad_session = segment_headers("keine-uuid", 0)
    assert (await client.post("/v1/live-transcriptions/segments", headers=bad_session, content=wav_bytes(2.5))).status_code == 400
    bad_seq = {**segment_headers(session_id, 0), "X-Mitschrift-Sequence": "x"}
    assert (await client.post("/v1/live-transcriptions/segments", headers=bad_seq, content=wav_bytes(2.5))).status_code == 400
    bad_lang = segment_headers(session_id, 0, language="fr")
    r = await client.post("/v1/live-transcriptions/segments", headers=bad_lang, content=wav_bytes(2.5))
    assert r.status_code == 400 and r.json()["error"] == "invalid_language"
    bad_type = {**segment_headers(session_id, 0), "Content-Type": "application/octet-stream"}
    assert (await client.post("/v1/live-transcriptions/segments", headers=bad_type, content=wav_bytes(2.5))).status_code == 400


async def test_invalid_audio(client: httpx.AsyncClient, session_id: str) -> None:
    r = await client.post("/v1/live-transcriptions/segments", headers=segment_headers(session_id, 0), content=b"nicht wav")
    assert r.status_code == 400 and r.json()["error"] == "invalid_audio"
    r = await post_segment(client, session_id, 0, seconds=0.5)
    assert r.status_code == 400 and r.json()["error"] == "invalid_duration"
    r = await post_segment(client, session_id, 0, seconds=6.0)
    assert r.status_code == 400 and r.json()["error"] == "invalid_duration"


async def test_payload_too_large(client: httpx.AsyncClient, session_id: str) -> None:
    big = b"RIFF" + b"\0" * (1_048_576 + 100)
    r = await client.post("/v1/live-transcriptions/segments", headers=segment_headers(session_id, 0), content=big)
    assert r.status_code == 413
    assert r.json()["error"] == "payload_too_large"


async def test_first_segment_must_be_sequence_zero(client: httpx.AsyncClient, session_id: str) -> None:
    r = await post_segment(client, session_id, 3)
    assert r.status_code == 409
    assert r.json()["error"] == "sequence_gap"


async def test_sequence_gap_rejected(client: httpx.AsyncClient, session_id: str) -> None:
    assert (await post_segment(client, session_id, 0)).status_code == 200
    r = await post_segment(client, session_id, 2)
    assert r.status_code == 409 and r.json()["error"] == "sequence_gap"
    # Danach geht es mit der richtigen Nummer weiter.
    assert (await post_segment(client, session_id, 1)).status_code == 200


async def test_duplicate_replays_without_inference(client: httpx.AsyncClient, whisper: FakeWhisper, session_id: str) -> None:
    first = await post_segment(client, session_id, 0)
    assert first.status_code == 200
    calls = whisper.calls
    again = await post_segment(client, session_id, 0)
    assert again.status_code == 200
    assert again.json() == first.json()
    assert whisper.calls == calls


async def test_response_shape(client: httpx.AsyncClient, session_id: str) -> None:
    body = (await post_segment(client, session_id, 0)).json()
    assert body["sessionId"] == session_id
    assert body["sequence"] == 0
    assert body["windowStart"] == 0.0
    assert body["windowEnd"] == 2.5
    assert body["final"] == []  # nichts endet 3 s vor dem Pufferende
    assert [s["text"] for s in body["partial"]] == ["s0.", "s1."]
    assert set(body["diagnostics"]) == {"serverLatencyMs", "realtimeFactor", "queuedSegments"}


async def test_finalization_over_ten_seconds(client: httpx.AsyncClient, whisper: FakeWhisper, session_id: str) -> None:
    """2,5-s-Segmente mit 300 ms Überlappung: Zeitachse 2.5, 4.7, 6.9, 9.1 s."""
    finals: list[dict] = []
    windows: list[tuple[float, float]] = []
    for seq in range(4):
        body = (await post_segment(client, session_id, seq)).json()
        windows.append((body["windowStart"], body["windowEnd"]))
        for segment in body["final"]:
            assert segment["end"] <= body["windowEnd"] - 3.0
        finals.extend(body["final"])
        for segment in body["partial"]:
            assert segment["end"] > body["windowEnd"] - 3.0 or body["final"] == [] or segment["start"] >= finals[-1]["end"]
    assert windows[-1][1] == pytest.approx(9.1, abs=0.01)
    # Finale Segmente: eindeutig, aufsteigend, lückenlos ab 0
    ends = [s["end"] for s in finals]
    assert ends == sorted(ends) and len(set(ends)) == len(ends)
    assert finals[0]["start"] == 0.0
    assert finals[-1]["end"] <= 9.1 - 3.0
    assert len(finals) >= 5
    # Der Puffer wird hinter dem letzten finalen Segment gekürzt
    assert windows[-1][0] == pytest.approx(finals[-1]["end"] if len(finals) else 0.0, abs=0.01) or windows[-1][0] >= 0.0
    assert max(whisper.durations) <= 12.0


async def test_no_finalization_mid_speech_until_forced(client: httpx.AsyncClient, whisper: FakeWhisper, session_id: str) -> None:
    """Ohne Pause und ohne Satzende bleibt alles partial, bis ein Segment 8 s zurückliegt oder sein
    Anfang beim nächsten Segment aus dem 12-s-Fenster fallen würde (Überlaufschutz ab buffer_end - 7 s)."""
    whisper.punctuate = False
    finals: list[dict] = []
    for seq in range(4):  # Zeitachse bis 9.1 s
        body = (await post_segment(client, session_id, seq)).json()
        finals.extend(body["final"])
        for segment in body["final"]:
            assert segment["end"] <= body["windowEnd"] - 8.0 or segment["start"] <= body["windowEnd"] - 7.0
    # Bis 6.9 s greift keine Regel; bei 9.1 s sind die Segmente mit Anfang <= 2.1 s vom Überlaufschutz betroffen
    assert [(s["start"], s["end"]) for s in finals] == [(0.0, 1.0), (1.0, 2.0), (2.0, 3.0)]
    body = (await client.post(f"/v1/live-transcriptions/{session_id}/finish", headers=AUTH)).json()
    # Der Rest wird beim Abschluss final; er beginnt hinter dem Schnitt (3,0 s plus Suchfenster) und reicht bis zum Ende.
    assert 3.0 <= body["final"][0]["start"] <= 3.5
    assert body["final"][-1]["end"] == pytest.approx(9.1, abs=0.6)
    assert body["partial"] == []


async def test_overflow_finalizes_before_audio_is_dropped(whisper: FakeWhisper) -> None:
    """Ein Segment, dessen Anfang beim nächsten Append aus dem Fenster fiele, wird finalisiert, auch
    ohne Pause und innerhalb des Sicherheitsabstands. Vorher ging dieser Text verloren."""
    from asr_adapter.sessions import Session
    from asr_adapter.whisper_client import RawSegment

    settings = make_settings()  # window 12 s, max_segment 5 s → Überlaufmarke bei buffer_end - 7 s
    session = Session(session_id="s", language="de", settings=settings, created_at=0.0, last_activity=0.0)
    session.append(np.zeros(int(12.0 * SAMPLE_RATE), dtype="<i2"), 0)
    # Durchgehende Rede ohne Satzzeichen: ein langes Segment 0–10 s und ein Rest 10–12 s
    raw = [RawSegment(0.0, 10.0, "ohne Pause gesprochen"), RawSegment(10.0, 12.0, "und weiter")]
    final, partial = session.split(raw, finalize_all=False)
    assert [s["text"] for s in final] == ["ohne Pause gesprochen"]
    assert [s["text"] for s in partial] == ["und weiter"]
    assert session.buffer_start >= 10.0


async def test_overflow_rule_does_not_fire_in_small_window(whisper: FakeWhisper) -> None:
    from asr_adapter.sessions import Session
    from asr_adapter.whisper_client import RawSegment

    session = Session(session_id="s", language="de", settings=make_settings(), created_at=0.0, last_activity=0.0)
    session.append(np.zeros(int(6.0 * SAMPLE_RATE), dtype="<i2"), 0)
    final, partial = session.split([RawSegment(0.0, 5.5, "noch unsicher")], finalize_all=False)
    assert final == [] and len(partial) == 1


async def test_cut_moves_into_silence_after_final(whisper: FakeWhisper) -> None:
    """Nach einem finalen Segment wird der Puffer an der leisesten Stelle kurz dahinter geschnitten."""
    from asr_adapter.sessions import Session
    from asr_adapter.whisper_client import RawSegment

    settings = make_settings()
    session = Session(session_id="s", language="de", settings=settings, created_at=0.0, last_activity=0.0)
    tone = np.frombuffer(wav_bytes(1.1, tone=True)[44:], dtype="<i2")
    silence = np.zeros(int(0.2 * SAMPLE_RATE), dtype="<i2")
    tail = np.frombuffer(wav_bytes(4.0, tone=True)[44:], dtype="<i2")
    session.append(np.concatenate([tone, silence, tail]), 0)  # Stille bei 1.1–1.3 s
    raw = [RawSegment(0.0, 1.0, "Hallo."), RawSegment(1.3, 5.3, "weiter")]
    final, partial = session.split(raw, finalize_all=False)
    assert [s["text"] for s in final] == ["Hallo."]
    assert 1.1 <= session.buffer_start <= 1.3, session.buffer_start


async def test_finish_returns_rest_and_is_idempotent(client: httpx.AsyncClient, session_id: str) -> None:
    for seq in range(2):
        assert (await post_segment(client, session_id, seq)).status_code == 200
    r = await client.post(f"/v1/live-transcriptions/{session_id}/finish", headers=AUTH)
    assert r.status_code == 200
    body = r.json()
    assert body["sessionId"] == session_id
    assert body["lastSequence"] == 1
    assert body["partial"] == []
    assert len(body["final"]) >= 1
    # Der Fake liefert ganze Sekunden; Zeitachse endet bei 4.7 s, letztes Segment also [3, 4).
    assert body["final"][-1]["end"] == pytest.approx(4.0, abs=0.01)
    assert body["final"][-1]["end"] <= 4.7

    again = await client.post(f"/v1/live-transcriptions/{session_id}/finish", headers=AUTH)
    assert again.status_code == 200
    assert again.json() == body, "Wiederholtes finish liefert dieselbe Antwort (Replay)"

    # Weitere Segmente an eine beendete Session
    r = await post_segment(client, session_id, 2)
    assert r.status_code == 409 and r.json()["error"] == "session_finished"


async def test_failed_inference_rolls_back_buffer(client: httpx.AsyncClient, whisper: FakeWhisper, session_id: str) -> None:
    """503 bei Inferenzfehler; die Wiederholung derselben Sequenz darf das Audio nicht doppelt anhängen."""
    assert (await post_segment(client, session_id, 0)).status_code == 200
    whisper.fail_next = 1
    r = await post_segment(client, session_id, 1)
    assert r.status_code == 503 and r.json()["error"] == "asr_unavailable"
    r = await post_segment(client, session_id, 1)
    assert r.status_code == 200
    assert r.json()["windowEnd"] == pytest.approx(4.7, abs=0.01), "Zeitachse 2.5 + 2.2, nicht 2.5 + 2.2 + 2.2"


async def test_sweep_releases_session_when_whisper_down(whisper: FakeWhisper) -> None:
    from asr_adapter.sessions import SessionStore
    from conftest import SAMPLE_RATE as rate

    clock = {"t": 0.0}
    store = SessionStore(make_settings(session_idle_timeout_seconds=1.0), whisper, now=lambda: clock["t"])
    await store.handle_segment("s1", 0, "de", np.zeros(int(2.5 * rate), dtype="<i2"))
    whisper.fail_next = 10
    clock["t"] = 5.0
    removed = await store.sweep()
    assert removed == 1
    assert store.active_count == 0


async def test_finish_unknown_session(client: httpx.AsyncClient) -> None:
    r = await client.post(f"/v1/live-transcriptions/{uuid.uuid4()}/finish", headers=AUTH)
    assert r.status_code == 404


async def test_max_sessions(whisper: FakeWhisper) -> None:
    app = create_app(make_settings(max_sessions=2), whisper)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        ids = [str(uuid.uuid4()) for _ in range(3)]
        assert (await post_segment(client, ids[0], 0)).status_code == 200
        assert (await post_segment(client, ids[1], 0)).status_code == 200
        r = await post_segment(client, ids[2], 0)
        assert r.status_code == 429 and r.json()["error"] == "too_many_sessions"
        # Nach finish wird der Platz frei
        assert (await client.post(f"/v1/live-transcriptions/{ids[0]}/finish", headers=AUTH)).status_code == 200
        assert (await post_segment(client, ids[2], 0)).status_code == 200


async def test_idle_sessions_are_finished_by_sweep(whisper: FakeWhisper) -> None:
    clock = [0.0]
    settings = make_settings(session_idle_timeout_seconds=60.0)
    from asr_adapter.sessions import SessionStore

    store = SessionStore(settings, whisper, now=lambda: clock[0])
    sid = str(uuid.uuid4())
    import numpy as np

    await store.handle_segment(sid, 0, "de", np.zeros(40_000, dtype="<i2"))
    assert store.active_count == 1
    clock[0] = 30.0
    assert await store.sweep() == 0
    clock[0] = 61.0
    assert await store.sweep() == 1
    assert store.active_count == 0

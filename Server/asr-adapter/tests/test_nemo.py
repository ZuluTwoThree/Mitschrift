from __future__ import annotations

import uuid

import httpx
import pytest

from conftest import AUTH, FakeWhisper, segment_headers, wav_bytes
from fake_nemo import FakeNemoServer

from asr_adapter.app import create_app
from asr_adapter.nemo_realtime import NemoRealtimeError, NemoRealtimeSession, http_base_url, language_for_nemo


@pytest.fixture
async def nemo():
    server = FakeNemoServer()
    await server.start()
    try:
        yield server
    finally:
        await server.stop()


def nemo_settings(server: FakeNemoServer, **overrides):
    from asr_adapter.config import Settings
    from conftest import TOKEN

    return Settings(token=TOKEN, model_name="nemotron-test.gguf", asr_backend="nemo", nemo_url=server.url, **overrides)


@pytest.fixture
async def nemo_client(nemo: FakeNemoServer):
    app = create_app(nemo_settings(nemo), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def post_segment(client: httpx.AsyncClient, session_id: str, sequence: int, seconds: float = 2.5, **kw):
    return await client.post(
        "/v1/live-transcriptions/segments", headers=segment_headers(session_id, sequence, **kw), content=wav_bytes(seconds)
    )


async def finish(client: httpx.AsyncClient, session_id: str):
    return await client.post(f"/v1/live-transcriptions/{session_id}/finish", headers=AUTH)


def test_language_mapping() -> None:
    assert language_for_nemo("de") == "de"
    assert language_for_nemo("EN") == "en"
    assert language_for_nemo("auto") is None
    assert language_for_nemo("") is None
    assert http_base_url("ws://nemo-speech:8080") == "http://nemo-speech:8080"
    assert http_base_url("wss://host:443/") == "https://host:443"


async def test_realtime_session_builds_partial_and_completes(nemo: FakeNemoServer) -> None:
    session = NemoRealtimeSession(url=nemo.url, endpointing_ms=700)
    await session.open("de")
    assert nemo.sessions[-1]["language"] == "de"
    assert nemo.sessions[-1]["endpointing_ms"] == 700
    assert nemo.sessions[-1]["word_timestamps"] is True
    await session.feed(b"\0" * (2 * 16_000 * 2))  # 2 s
    await session.wait_processed(2.0, timeout=2.0)
    finals, partial = session.snapshot()
    assert finals == []
    assert partial == "t0 t1 t2 t3"
    await session.finish(timeout=5.0)
    finals, partial = session.snapshot()
    assert partial == ""
    assert len(finals) == 1
    assert finals[0].text == "t0 t1 t2 t3"
    assert finals[0].start == 0.0 and finals[0].end == 2.0
    assert session.failed is None


async def test_auto_language_is_left_to_model(nemo: FakeNemoServer) -> None:
    session = NemoRealtimeSession(url=nemo.url, endpointing_ms=0)
    await session.open("auto")
    assert "language" not in nemo.sessions[-1]
    assert "endpointing_ms" not in nemo.sessions[-1]
    await session.close()


async def test_partial_grows_and_completed_becomes_final_once(nemo_client: httpx.AsyncClient, nemo: FakeNemoServer) -> None:
    nemo.completed_every_seconds = 2.0
    sid = str(uuid.uuid4())
    app_settings = nemo_settings(nemo, nemo_settle_seconds=1.0)
    app = create_app(app_settings, FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        seen_finals: list[dict] = []
        for seq in range(4):  # 2.5 + 3×2.2 = 9.1 s gesendet
            body = (await post_segment(client, sid, seq)).json()
            assert body["sessionId"] == sid and body["sequence"] == seq
            assert body["windowEnd"] == pytest.approx(2.5 + 2.2 * seq, abs=0.01)
            for segment in body["final"]:
                assert segment not in seen_finals, "Finals werden nie erneut geliefert"
                seen_finals.append(segment)
            assert len(body["partial"]) <= 1
            if body["partial"]:
                assert body["partial"][0]["start"] >= (seen_finals[-1]["end"] if seen_finals else 0.0)
                assert body["partial"][0]["end"] == body["windowEnd"]
            assert set(body["diagnostics"]) == {"serverLatencyMs", "realtimeFactor", "queuedSegments"}
        assert len(seen_finals) >= 3
        ends = [s["end"] for s in seen_finals]
        assert ends == sorted(ends)
        assert all(s["text"] for s in seen_finals)

        body = (await finish(client, sid)).json()
        assert body["partial"] == []
        assert body["lastSequence"] == 3
        all_text = " ".join(s["text"] for s in seen_finals + body["final"])
        assert all_text.split() == [f"t{k}" for k in range(18)], all_text
        again = (await finish(client, sid)).json()
        assert again == body


async def test_without_endpointing_everything_is_partial_until_finish(nemo_client: httpx.AsyncClient) -> None:
    sid = str(uuid.uuid4())
    for seq in range(3):
        body = (await post_segment(nemo_client, sid, seq)).json()
        assert body["final"] == []
    body = (await finish(nemo_client, sid)).json()
    assert body["partial"] == []
    assert len(body["final"]) == 1
    assert body["final"][0]["start"] == 0.0
    # Der Fake bildet Wörter in 0,5-s-Schritten; das letzte endet bei 6,5 s von 6,9 s gesendetem Audio.
    assert 6.5 <= body["final"][0]["end"] <= 6.9
    assert body["final"][0]["text"].split() == [f"t{k}" for k in range(13)]


async def test_duplicate_sequence_is_replayed_without_resending(nemo_client: httpx.AsyncClient, nemo: FakeNemoServer) -> None:
    sid = str(uuid.uuid4())
    first = (await post_segment(nemo_client, sid, 0)).json()
    received = nemo.received_bytes
    again = (await post_segment(nemo_client, sid, 0)).json()
    assert again == first
    assert nemo.received_bytes == received


async def test_sequence_rules_apply(nemo_client: httpx.AsyncClient) -> None:
    sid = str(uuid.uuid4())
    assert (await post_segment(nemo_client, sid, 1)).status_code == 409
    assert (await post_segment(nemo_client, sid, 0)).status_code == 200
    r = await post_segment(nemo_client, sid, 2)
    assert r.status_code == 409 and r.json()["error"] == "sequence_gap"
    assert (await finish(nemo_client, sid)).status_code == 200
    r = await post_segment(nemo_client, sid, 1)
    assert r.status_code == 409 and r.json()["error"] == "session_finished"


async def test_connection_failure_yields_503_and_reconnects(nemo: FakeNemoServer) -> None:
    nemo.fail_after_bytes = 3 * 16_000 * 2  # nach 3 s Audio bricht der Server ab
    app = create_app(nemo_settings(nemo, nemo_settle_seconds=1.0), FakeWhisper())
    sid = str(uuid.uuid4())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        assert (await post_segment(client, sid, 0)).status_code == 200
        r = await post_segment(client, sid, 1)
        assert r.status_code == 503 and r.json()["error"] == "asr_unavailable"
        nemo.fail_after_bytes = None
        r = await post_segment(client, sid, 1)
        assert r.status_code == 200, "nach dem Abbruch wird neu verbunden"
        assert nemo.connections == 2
        body = r.json()
        assert body["windowEnd"] == pytest.approx(4.7, abs=0.01), "Zeitachse läuft weiter"
        body = (await finish(client, sid)).json()
        assert body["final"], "der Text der neuen Verbindung kommt beim Abschluss"
        assert body["final"][-1]["start"] >= 4.7 - 2.2 - 0.01, "Zeiten der neuen Verbindung sind auf die Sessionzeitachse versetzt"


async def test_unreachable_server_is_503(nemo: FakeNemoServer) -> None:
    await nemo.stop()
    app = create_app(nemo_settings(nemo), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        r = await post_segment(client, str(uuid.uuid4()), 0)
        assert r.status_code == 503 and r.json()["error"] == "asr_unavailable"


async def test_server_rejecting_session_is_error(nemo: FakeNemoServer) -> None:
    nemo.reject = True
    session = NemoRealtimeSession(url=nemo.url)
    with pytest.raises(NemoRealtimeError):
        await session.open("de")
        await session.feed(b"\0" * 32_000)


async def test_health_reports_backend(nemo: FakeNemoServer) -> None:
    app = create_app(nemo_settings(nemo), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        body = (await client.get("/v1/health")).json()
    assert body["backend"] == "nemo"
    assert body["model"] == "nemotron-test.gguf"


async def test_whisper_health_still_reports_backend(client: httpx.AsyncClient) -> None:
    body = (await client.get("/v1/health")).json()
    assert body["backend"] == "whisper"


async def test_session_update_requests_diarization_only_when_enabled(nemo: FakeNemoServer) -> None:
    session = NemoRealtimeSession(url=nemo.url)
    await session.open("de")
    assert "speaker_diarization" not in nemo.sessions[-1]
    assert session.diarization_active is False
    await session.close()

    nemo.speaker_switch_every_seconds = 1.0
    session = NemoRealtimeSession(url=nemo.url, speaker_diarization=True)
    await session.open("de")
    assert nemo.sessions[-1]["speaker_diarization"] is True
    assert session.diarization_active is True
    await session.close()


async def test_unconfirmed_diarization_keeps_working_without_speakers(nemo: FakeNemoServer) -> None:
    # Kein Diarization-Modell geladen: der Server bestätigt die Option nicht, Audio läuft trotzdem.
    session = NemoRealtimeSession(url=nemo.url, speaker_diarization=True)
    await session.open("de")
    assert session.diarization_active is False
    await session.feed(b"\0" * (2 * 16_000 * 2))
    await session.finish(timeout=5.0)
    finals, _ = session.snapshot()
    assert len(finals) == 1 and finals[0].speaker is None
    assert session.failed is None


async def test_completed_with_speaker_change_is_split_into_speaker_segments(nemo: FakeNemoServer) -> None:
    nemo.speaker_switch_every_seconds = 1.0
    app = create_app(nemo_settings(nemo, nemo_speaker_diarization=True, nemo_settle_seconds=1.0), FakeWhisper())
    sid = str(uuid.uuid4())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        body = (await post_segment(client, sid, 0, seconds=2.0)).json()
        assert body["final"] == [], "ohne Endpointing erst beim Abschluss final"
        assert body["partial"] and "speaker" not in body["partial"][0], "partial nie mit Sprecher"
        body = (await finish(client, sid)).json()
    # 2 s Audio → Wörter t0,t1 (0–1 s) Sprecher 1, t2,t3 (1–2 s) Sprecher 2 → zwei Finals
    assert [(s["speaker"], s["text"]) for s in body["final"]] == [("1", "t0 t1"), ("2", "t2 t3")]
    assert body["final"][0]["start"] == 0.0 and body["final"][0]["end"] == 1.0
    assert body["final"][1]["start"] == 1.0 and body["final"][1]["end"] == 2.0


async def test_without_diarization_segments_have_no_speaker(nemo_client: httpx.AsyncClient, nemo: FakeNemoServer) -> None:
    nemo.speaker_switch_every_seconds = 1.0  # Server könnte, die Einstellung fordert es aber nicht an
    sid = str(uuid.uuid4())
    await post_segment(nemo_client, sid, 0, seconds=2.0)
    body = (await finish(nemo_client, sid)).json()
    assert len(body["final"]) == 1
    assert "speaker" not in body["final"][0]


async def test_health_reports_diarization_flag(nemo: FakeNemoServer) -> None:
    app = create_app(nemo_settings(nemo, nemo_speaker_diarization=True), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        body = (await client.get("/v1/health")).json()
    assert body["diarization"] is True
    app = create_app(nemo_settings(nemo), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        body = (await client.get("/v1/health")).json()
    assert body["diarization"] is False


async def test_single_speaker_final_keeps_formatted_transcript() -> None:
    """Hat ein completed-Ereignis nur einen Sprecher, bleibt der formatierte `transcript` erhalten."""
    from asr_adapter.nemo_realtime import NemoRealtimeSession

    session = NemoRealtimeSession.__new__(NemoRealtimeSession)
    session._partial = ""
    session._pending_finals = []
    session._last_final_end = 0.0
    session.audio_processed = 0.0
    session._completed({
        "transcript": "Guten Tag, wir beginnen.",
        "words": [
            {"word": "Guten", "start": 0.5, "end": 0.9, "speaker": 2},
            {"word": "Tag", "start": 1.0, "end": 1.3, "speaker": 2},
            {"word": "wir", "start": 1.5, "end": 1.7, "speaker": 2},
            {"word": "beginnen", "start": 1.8, "end": 2.4, "speaker": 2},
        ],
    })
    assert [(f.text, f.speaker) for f in session._pending_finals] == [("Guten Tag, wir beginnen.", "2")]
    session._pending_finals.clear()
    session._completed({
        "transcript": "Ja. Nein.",
        "words": [
            {"word": "Ja.", "start": 3.0, "end": 3.2, "speaker": 1},
            {"word": "Nein.", "start": 3.5, "end": 3.8, "speaker": 3},
        ],
    })
    assert [(f.text, f.speaker) for f in session._pending_finals] == [("Ja.", "1"), ("Nein.", "3")]

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

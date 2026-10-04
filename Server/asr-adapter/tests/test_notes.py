from __future__ import annotations

import json
from dataclasses import dataclass, field

import httpx
import pytest

from conftest import AUTH, FakeWhisper, make_settings

from asr_adapter.app import create_app
from asr_adapter.llm_client import NotesError, NotesResult, OpenAIChatClient, strip_thinking

NOTES_MD = "# Protokoll\n\n## Zusammenfassung\nKurz.\n\n## Themen\n- Eins.\n\n## Entscheidungen\nKeine Entscheidungen festgehalten.\n\n## Aufgaben\n- [ ] Anna: Bericht (nicht genannt)\n\n## Offene Punkte\nKeine."
TRANSCRIPT = "Anna: Guten Morgen.\nBernd: Fangen wir an."


@dataclass
class FakeNotesWriter:
    """Zeichnet Aufrufe auf und liefert festen Markdown-Text; mit `fail=True` wirft er NotesError."""

    calls: list[dict[str, object]] = field(default_factory=list)
    fail: bool = False
    closed: bool = False

    async def write_notes(self, transcript: str, language: str, title: str | None, recorded_at: str | None) -> NotesResult:
        self.calls.append({"transcript": transcript, "language": language, "title": title, "recorded_at": recorded_at})
        if self.fail:
            raise NotesError("simulierter Ausfall")
        return NotesResult(notes=NOTES_MD, model="Qwen3-8B", prompt_tokens=1800, completion_tokens=420, latency_ms=2345)

    async def aclose(self) -> None:
        self.closed = True


def notes_client(writer: FakeNotesWriter | None, **overrides: object) -> httpx.AsyncClient:
    app = create_app(make_settings(**overrides), FakeWhisper(), notes_writer=writer)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


async def test_notes_success() -> None:
    writer = FakeNotesWriter()
    async with notes_client(writer) as client:
        response = await client.post(
            "/v1/notes",
            headers=AUTH,
            json={"transcript": TRANSCRIPT, "language": "en", "title": "Jour fixe", "recordedAt": "2026-10-04T10:00:00Z"},
        )
    assert response.status_code == 200
    assert response.json() == {
        "notes": NOTES_MD,
        "model": "Qwen3-8B",
        "diagnostics": {"latencyMs": 2345, "promptTokens": 1800, "completionTokens": 420},
    }
    assert writer.calls == [{"transcript": TRANSCRIPT, "language": "en", "title": "Jour fixe", "recorded_at": "2026-10-04T10:00:00Z"}]


async def test_notes_defaults_language_and_optional_fields() -> None:
    writer = FakeNotesWriter()
    async with notes_client(writer) as client:
        assert (await client.post("/v1/notes", headers=AUTH, json={"transcript": "  Hallo.  "})).status_code == 200
        assert (await client.post("/v1/notes", headers=AUTH, json={"transcript": "Hallo.", "language": "auto"})).status_code == 200
    assert [c["language"] for c in writer.calls] == ["de", "de"]
    assert writer.calls[0]["transcript"] == "Hallo."
    assert writer.calls[0]["title"] is None and writer.calls[0]["recorded_at"] is None


async def test_notes_requires_token() -> None:
    async with notes_client(FakeNotesWriter()) as client:
        response = await client.post("/v1/notes", json={"transcript": TRANSCRIPT})
    assert response.status_code == 401
    assert response.json() == {"error": "unauthorized", "message": "Nicht autorisiert."}


@pytest.mark.parametrize(
    "body, code",
    [
        ({"transcript": ""}, "invalid_request"),
        ({"transcript": "   \n"}, "invalid_request"),
        ({"transcript": 42}, "invalid_request"),
        ({}, "invalid_request"),
        ({"transcript": TRANSCRIPT, "title": 1}, "invalid_request"),
        ({"transcript": TRANSCRIPT, "recordedAt": []}, "invalid_request"),
        ({"transcript": TRANSCRIPT, "language": "fr"}, "invalid_language"),
        ({"transcript": TRANSCRIPT, "language": 3}, "invalid_request"),
    ],
)
async def test_notes_invalid_request(body: dict[str, object], code: str) -> None:
    writer = FakeNotesWriter()
    async with notes_client(writer) as client:
        response = await client.post("/v1/notes", headers=AUTH, json=body)
    assert response.status_code == 400
    assert response.json()["error"] == code
    assert writer.calls == []


async def test_notes_rejects_non_json() -> None:
    async with notes_client(FakeNotesWriter()) as client:
        r = await client.post("/v1/notes", headers={**AUTH, "Content-Type": "application/json"}, content=b"kein json")
        assert r.status_code == 400 and r.json()["error"] == "invalid_request"
        r = await client.post("/v1/notes", headers=AUTH, json=["liste"])
        assert r.status_code == 400 and r.json()["error"] == "invalid_request"


async def test_notes_transcript_too_long() -> None:
    writer = FakeNotesWriter()
    async with notes_client(writer, llm_max_input_chars=20) as client:
        response = await client.post("/v1/notes", headers=AUTH, json={"transcript": "x" * 21})
    assert response.status_code == 413
    assert response.json()["error"] == "transcript_too_long"
    assert "x" not in response.json()["message"].replace("transcript", "")
    assert writer.calls == []


async def test_notes_unavailable_without_llm() -> None:
    async with notes_client(None) as client:
        response = await client.post("/v1/notes", headers=AUTH, json={"transcript": TRANSCRIPT})
    assert response.status_code == 503
    assert response.json() == {"error": "llm_unavailable", "message": "Der Protokoll-Assistent ist gerade nicht verfügbar."}


async def test_notes_unavailable_when_writer_fails() -> None:
    async with notes_client(FakeNotesWriter(fail=True)) as client:
        response = await client.post("/v1/notes", headers=AUTH, json={"transcript": TRANSCRIPT})
    assert response.status_code == 503
    assert response.json()["error"] == "llm_unavailable"
    assert "Anna" not in response.json()["message"]


async def test_health_reports_notes() -> None:
    async with notes_client(None) as client:
        assert (await client.get("/v1/health")).json()["notes"] is False
    async with notes_client(FakeNotesWriter()) as client:
        assert (await client.get("/v1/health")).json()["notes"] is True


async def test_app_builds_chat_client_from_llm_url_and_closes_it() -> None:
    app = create_app(make_settings(llm_url="http://llm.test"), FakeWhisper())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        assert (await client.get("/v1/health")).json()["notes"] is True
    writer = FakeNotesWriter()
    app = create_app(make_settings(), FakeWhisper(), notes_writer=writer)
    async with app.router.lifespan_context(app):
        pass
    assert writer.closed


# --- OpenAIChatClient gegen einen MockTransport ---


def chat_response(content: str, *, model: str | None = "Qwen3-8B", usage: dict[str, int] | None = None) -> dict[str, object]:
    body: dict[str, object] = {"choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]}
    if model:
        body["model"] = model
    if usage is not None:
        body["usage"] = usage
    return body


async def test_chat_client_sends_expected_request_and_parses_response() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=chat_response("<think>\nÜberlegung…\n</think>\n\n" + NOTES_MD + "\n", usage={"prompt_tokens": 1800, "completion_tokens": 420}))

    client = OpenAIChatClient("http://llm.test/", model="local", api_key="geheim", temperature=0.2, max_output_tokens=2048, transport=httpx.MockTransport(handler))
    try:
        result = await client.write_notes(TRANSCRIPT, "de", "Jour fixe", "2026-10-04T10:00:00Z")
    finally:
        await client.aclose()

    assert len(seen) == 1
    request = seen[0]
    assert request.method == "POST"
    assert request.url.path == "/v1/chat/completions"
    assert request.headers["authorization"] == "Bearer geheim"
    payload = json.loads(request.content)
    assert payload["model"] == "local"
    assert payload["stream"] is False
    assert payload["temperature"] == 0.2
    assert payload["max_tokens"] == 2048
    system, user = payload["messages"]
    assert system["role"] == "system" and "Protokoll" in system["content"]
    assert user["role"] == "user"
    assert TRANSCRIPT in user["content"]
    assert "Jour fixe" in user["content"] and "04.10.2026, 10:00" in user["content"]
    assert user["content"].index("Jour fixe") < user["content"].index(TRANSCRIPT)

    assert result.notes == NOTES_MD
    assert "<think>" not in result.notes
    assert result.model == "Qwen3-8B"
    assert result.prompt_tokens == 1800 and result.completion_tokens == 420
    assert result.latency_ms is not None and result.latency_ms >= 0


async def test_chat_client_english_prompt_and_fallback_model() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=chat_response(NOTES_MD, model=None))

    client = OpenAIChatClient("http://llm.test", model="fallback", transport=httpx.MockTransport(handler))
    try:
        result = await client.write_notes(TRANSCRIPT, "en", None, None)
    finally:
        await client.aclose()
    payload = json.loads(seen[0].content)
    assert "meeting minutes" in payload["messages"][0]["content"]
    assert payload["messages"][1]["content"].startswith("Transcript:")
    assert "authorization" not in seen[0].headers
    assert result.model == "fallback"
    assert result.prompt_tokens is None and result.completion_tokens is None


@pytest.mark.parametrize(
    "handler",
    [
        lambda request: httpx.Response(500, text="kaputt"),
        lambda request: httpx.Response(200, json={"choices": []}),
        lambda request: httpx.Response(200, json={"choices": [{"message": {"role": "assistant"}}]}),
        lambda request: httpx.Response(200, json={"choices": [{"message": {"content": "<think>nur Gedanken</think>"}}]}),
        lambda request: httpx.Response(200, text="kein json"),
    ],
)
async def test_chat_client_errors_become_notes_error(handler) -> None:
    client = OpenAIChatClient("http://llm.test", transport=httpx.MockTransport(handler))
    try:
        with pytest.raises(NotesError):
            await client.write_notes(TRANSCRIPT, "de", None, None)
    finally:
        await client.aclose()


async def test_chat_client_connection_error_becomes_notes_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("Verbindung abgelehnt", request=request)

    client = OpenAIChatClient("http://llm.test", transport=httpx.MockTransport(handler))
    try:
        with pytest.raises(NotesError):
            await client.write_notes(TRANSCRIPT, "de", None, None)
    finally:
        await client.aclose()


def test_strip_thinking() -> None:
    assert strip_thinking("<think>a</think>\n\n# Protokoll\n") == "# Protokoll"
    assert strip_thinking("<think>a</think>x<think>b</think> y ") == "x y"
    assert strip_thinking("# Protokoll\n<think>abgeschnitten") == "# Protokoll"
    assert strip_thinking("  ohne  ") == "ohne"


def test_recorded_at_is_rendered_readable_in_user_prompt() -> None:
    from asr_adapter.llm_client import build_messages, format_recorded_at

    assert format_recorded_at("2026-10-04T12:30:00+02:00", english=False) == "04.10.2026, 12:30"
    assert format_recorded_at("2026-10-04T10:30:00Z", english=True) == "2026-10-04 10:30"
    assert format_recorded_at("gestern", english=False) == "gestern"
    user = build_messages("Text", "de", None, "2026-10-04T12:30:00+02:00")[1]["content"]
    assert "Datum: 04.10.2026, 12:30" in user

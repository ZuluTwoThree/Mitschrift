from __future__ import annotations

from datetime import datetime

import re
import time
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

# Qwen3 und ähnliche Modelle stellen dem Ergebnis einen <think>-Block voran; der gehört nicht ins Protokoll.
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)
# Ein nicht geschlossener Block (Antwort abgeschnitten) wird bis zum Ende entfernt.
_THINK_OPEN = re.compile(r"<think>.*\Z", re.DOTALL)


@dataclass(frozen=True)
class NotesResult:
    """Vom LLM erzeugtes Protokoll (Markdown) samt Diagnosedaten."""

    notes: str
    model: str
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    latency_ms: int | None = None


class NotesError(RuntimeError):
    pass


class NotesWriter(Protocol):
    async def write_notes(self, transcript: str, language: str, title: str | None, recorded_at: str | None) -> NotesResult: ...

    async def aclose(self) -> None: ...


SYSTEM_PROMPT_DE = """Du bist ein Notizen-Assistent und erstellst aus der Mitschrift einer Besprechung ein sachliches Protokoll in Markdown.

Regeln:
- Verwende nur Inhalte, die in der Mitschrift stehen. Erfinde oder ergänze nichts.
- Übernimm Sprechernamen so, wie sie in der Mitschrift stehen („Sprecher 2“ bleibt „Sprecher 2“).
- Kennzeichne unklare oder fehlende Angaben als „nicht genannt“.
- Eine Aufgabe nimmst du nur auf, wenn in der Mitschrift jemand ausdrücklich etwas übernimmt, zusagt oder zugewiesen bekommt („ich kümmere mich“, „machst du bis Freitag“). Eine Entscheidung, wenn ein Vorgehen ausdrücklich festgelegt, vereinbart oder bestätigt wird („dann machen wir es so“, „wir machen es Freitag“, „das vertagen wir“). Meinungen, Vorschläge, Forderungen, Fragen und Diskussionen sind weder Aufgaben noch Entscheidungen. Jede Aufgabe und jede Entscheidung braucht ein wörtliches Zitat aus der Mitschrift als Beleg; findest du keines, lässt du den Eintrag weg. Eine Diskussionsrunde ohne Zusagen hat keine Aufgaben.
- Die Mitschrift stammt aus automatischer Spracherkennung und kann Erkennungsfehler enthalten. Korrigiere offensichtliche Erkennungsfehler sinngemäß; rate Zahlen und Namen nicht.
- Keine Einleitung, keine Nachbemerkung, nur das Protokoll.

Halte dich exakt an diese Struktur (Überschriften genau so):

# Protokoll
<Titel falls gegeben, Datum falls gegeben, sonst Zeile weglassen>

## Zusammenfassung
<3–6 Sätze>

## Themen
<je Thema ein Aufzählungspunkt mit 1–3 Sätzen; Reihenfolge wie besprochen>

## Entscheidungen
<Im Regelfall „Keine Entscheidungen festgehalten.“; sonst je Entscheidung „- Was – Beleg: „wörtliches Zitat aus der Mitschrift““>

## Aufgaben
<Im Regelfall „Keine Aufgaben festgehalten.“; sonst je Aufgabe „- [ ] Wer: Was (bis wann) – Beleg: „wörtliches Zitat aus der Mitschrift““; „nicht genannt“ für fehlende Teile>

## Offene Punkte
<Aufzählung; „Keine.“ falls keine>"""

SYSTEM_PROMPT_EN = """You are a note-taking assistant. From the transcript of a meeting you write factual meeting minutes in Markdown.

Rules:
- Use only content that appears in the transcript. Do not invent or add anything.
- Keep speaker names exactly as they appear in the transcript ("Speaker 2" stays "Speaker 2").
- Mark unclear or missing information as "not stated".
- List a task only when someone in the transcript explicitly takes on, promises or is assigned something ("I'll take care of it", "can you do it by Friday"). List a decision when a course of action is explicitly set, agreed or confirmed ("then that's what we'll do", "we'll do it Friday", "we postpone that"). Opinions, suggestions, demands, questions and discussion are neither tasks nor decisions. Every task and decision needs a verbatim quote from the transcript as evidence; if you find none, leave the entry out. A discussion without commitments has no tasks.
- The transcript comes from automatic speech recognition and may contain recognition errors. Correct obvious recognition errors by their evident meaning; do not guess numbers or names.
- No introduction, no closing remark, only the minutes.

Follow exactly this structure (headings verbatim):

# Protokoll
<title if given, date if given, otherwise omit the line>

## Zusammenfassung
<3–6 sentences>

## Themen
<one bullet per topic with 1–3 sentences; in the order discussed>

## Entscheidungen
<Usually "Keine Entscheidungen festgehalten."; otherwise per decision "- What – Beleg: „verbatim quote from the transcript“">

## Aufgaben
<Usually "Keine Aufgaben festgehalten."; otherwise per task "- [ ] Who: What (by when) – Beleg: „verbatim quote from the transcript“"; "not stated" for missing parts>

## Offene Punkte
<bullet list; "Keine." if none>"""


def format_recorded_at(value: str, english: bool) -> str:
    """ISO-8601-Zeitpunkt lesbar in der Wanduhrzeit des Geräts (Offset bleibt erhalten); sonst unverändert."""
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    return moment.strftime("%Y-%m-%d %H:%M" if english else "%d.%m.%Y, %H:%M")


def build_messages(transcript: str, language: str, title: str | None, recorded_at: str | None) -> list[dict[str, str]]:
    """Baut System- und User-Nachricht für den Chat-Endpunkt; Titel und Datum nur, wenn gegeben."""
    english = language == "en"
    lines: list[str] = []
    if title:
        lines.append(f"{'Title' if english else 'Titel'}: {title}")
    if recorded_at:
        lines.append(f"{'Date' if english else 'Datum'}: {format_recorded_at(recorded_at, english)}")
    if lines:
        lines.append("")
    lines.append(f"{'Transcript' if english else 'Mitschrift'}:")
    lines.append("")
    lines.append(transcript)
    return [
        {"role": "system", "content": SYSTEM_PROMPT_EN if english else SYSTEM_PROMPT_DE},
        {"role": "user", "content": "\n".join(lines)},
    ]


def strip_thinking(content: str) -> str:
    """Entfernt <think>…</think>-Blöcke (auch einen nicht geschlossenen) und trimmt den Rest."""
    content = _THINK_BLOCK.sub("", content)
    content = _THINK_OPEN.sub("", content)
    return content.strip()


def _optional_int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


class OpenAIChatClient:
    """Spricht einen OpenAI-kompatiblen Server (llama-server) über POST /v1/chat/completions an."""

    def __init__(
        self,
        base_url: str,
        model: str = "local",
        api_key: str | None = None,
        timeout_seconds: float = 180.0,
        max_output_tokens: int = 2048,
        temperature: float = 0.2,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else None
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout_seconds, headers=headers, transport=transport)
        self._model = model
        self._max_output_tokens = max_output_tokens
        self._temperature = temperature

    async def write_notes(self, transcript: str, language: str, title: str | None, recorded_at: str | None) -> NotesResult:
        payload = {
            "model": self._model,
            "messages": build_messages(transcript, language, title, recorded_at),
            "temperature": self._temperature,
            "max_tokens": self._max_output_tokens,
            "stream": False,
        }
        started = time.monotonic()
        try:
            response = await self._client.post("/v1/chat/completions", json=payload)
        except httpx.HTTPError as error:
            raise NotesError(f"LLM nicht erreichbar: {type(error).__name__}") from error
        latency_ms = int((time.monotonic() - started) * 1000)
        if response.status_code != 200:
            raise NotesError(f"LLM antwortete mit HTTP {response.status_code}")
        try:
            body = response.json()
        except ValueError as error:
            raise NotesError("LLM lieferte kein JSON") from error
        return parse_chat_completion(body, fallback_model=self._model, latency_ms=latency_ms)

    async def aclose(self) -> None:
        await self._client.aclose()


def parse_chat_completion(body: Any, fallback_model: str, latency_ms: int | None = None) -> NotesResult:
    """Liest choices[0].message.content, model und usage aus einer Chat-Completion-Antwort."""
    if not isinstance(body, dict):
        raise NotesError("LLM-Antwort hat kein erwartetes Format")
    choices = body.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise NotesError("LLM-Antwort enthält keine choices")
    message = choices[0].get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        raise NotesError("LLM-Antwort enthält keinen content")
    notes = strip_thinking(content)
    if not notes:
        raise NotesError("LLM-Antwort ist leer")
    model = body.get("model")
    usage = body.get("usage") if isinstance(body.get("usage"), dict) else {}
    return NotesResult(
        notes=notes,
        model=model if isinstance(model, str) and model else fallback_model,
        prompt_tokens=_optional_int(usage.get("prompt_tokens")),
        completion_tokens=_optional_int(usage.get("completion_tokens")),
        latency_ms=latency_ms,
    )

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
    #: Anzahl der Teile, in die eine lange Mitschrift vorverdichtet wurde (1 = in einem Durchgang).
    chunks: int = 1


class NotesError(RuntimeError):
    pass


#: Protokoll einer Besprechung (Entscheidungen, Aufgaben) oder Zusammenfassung eines Vortrags/Trainings.
NOTES_KINDS = ("minutes", "summary")


class NotesWriter(Protocol):
    async def write_notes(
        self, transcript: str, language: str, title: str | None, recorded_at: str | None, kind: str = "minutes"
    ) -> NotesResult: ...

    async def aclose(self) -> None: ...


SYSTEM_PROMPT_DE = """Du bist ein Notizen-Assistent und erstellst aus der Mitschrift einer Besprechung ein sachliches Protokoll in Markdown.

Regeln:
- Verwende nur Inhalte, die in der Mitschrift stehen. Erfinde oder ergänze nichts.
- Übernimm Sprechernamen so, wie sie in der Mitschrift stehen („Sprecher 2“ bleibt „Sprecher 2“).
- Kennzeichne unklare oder fehlende Angaben als „nicht genannt“.
- Eine Aufgabe nimmst du nur auf, wenn in der Mitschrift jemand ausdrücklich etwas übernimmt, zusagt oder zugewiesen bekommt („ich kümmere mich“, „machst du bis Freitag“). Eine Entscheidung, wenn ein Vorgehen ausdrücklich festgelegt, vereinbart oder bestätigt wird („dann machen wir es so“, „wir machen es Freitag“, „wir verschieben den Termin auf Freitag“, „das vertagen wir“). Ein Vorschlag, dem ausdrücklich zugestimmt wird („Einverstanden“, „Ja, so machen wir das“), ist ebenfalls eine Entscheidung. Meinungen, Vorschläge, Forderungen, Fragen und Diskussionen sind weder Aufgaben noch Entscheidungen. Jede Aufgabe und jede Entscheidung braucht ein wörtliches Zitat aus der Mitschrift als Beleg; findest du keines, lässt du den Eintrag weg. Eine Diskussionsrunde ohne Zusagen hat keine Aufgaben. Eine offene Frage wie „Wer kümmert sich um …?“ ohne Zusage in der Antwort ist ein offener Punkt, keine Aufgabe; die Person einer Aufgabe ist immer die, die zusagt oder beauftragt wird.
- Die Mitschrift stammt aus automatischer Spracherkennung und kann Erkennungsfehler enthalten. Korrigiere offensichtliche Erkennungsfehler sinngemäß; rate Zahlen und Namen nicht. Übernimm Zahlen genau so, wie sie in der Mitschrift stehen, und wandle ausgeschriebene Zahlen nicht in Ziffern um („zweihundertzwölf“ bleibt „zweihundertzwölf“).
- Keine Einleitung, keine Nachbemerkung, nur das Protokoll.

Halte dich exakt an diese Struktur (Überschriften genau so):

# Protokoll
<Titel falls gegeben, Datum falls gegeben, sonst Zeile weglassen>

## Zusammenfassung
<3–6 Sätze>

## Themen
<je Thema ein Aufzählungspunkt mit 1–3 Sätzen; Reihenfolge wie besprochen>

## Entscheidungen
<je Entscheidung „- <Entscheidung> – Beleg: „<wörtliches Zitat aus der Mitschrift>““; gibt es keine: „Keine Entscheidungen festgehalten.“>

## Aufgaben
<je Aufgabe „- [ ] <Person>: <Aufgabe> (bis <Termin oder „nicht genannt“>) – Beleg: „<wörtliches Zitat aus der Mitschrift>““; gibt es keine: „Keine Aufgaben festgehalten.“>

## Offene Punkte
<Aufzählung; „Keine.“ falls keine>"""

SYSTEM_PROMPT_EN = """You are a note-taking assistant. From the transcript of a meeting you write factual meeting minutes in Markdown.

Rules:
- Use only content that appears in the transcript. Do not invent or add anything.
- Keep speaker names exactly as they appear in the transcript ("Speaker 2" stays "Speaker 2").
- Mark unclear or missing information as "not stated".
- List a task only when someone in the transcript explicitly takes on, promises or is assigned something ("I'll take care of it", "can you do it by Friday"). List a decision when a course of action is explicitly set, agreed or confirmed ("then that's what we'll do", "we'll do it Friday", "we move the meeting to Friday", "we postpone that"). A proposal that is explicitly agreed to ("agreed", "yes, let's do that") is a decision too. Opinions, suggestions, demands, questions and discussion are neither tasks nor decisions. Every task and decision needs a verbatim quote from the transcript as evidence; if you find none, leave the entry out. A discussion without commitments has no tasks. An open question such as "who takes care of …?" without a commitment in the answer is an open point, not a task; the person of a task is always the one who commits or is assigned.
- The transcript comes from automatic speech recognition and may contain recognition errors. Correct obvious recognition errors by their evident meaning; do not guess numbers or names. Copy numbers exactly as they appear in the transcript and do not turn spelled-out numbers into digits.
- No introduction, no closing remark, only the minutes.

Follow exactly this structure (headings verbatim):

# Protokoll
<title if given, date if given, otherwise omit the line>

## Zusammenfassung
<3–6 sentences>

## Themen
<one bullet per topic with 1–3 sentences; in the order discussed>

## Entscheidungen
<per decision "- <decision> – Beleg: „<verbatim quote from the transcript>“"; if there are none: "Keine Entscheidungen festgehalten.">

## Aufgaben
<per task "- [ ] <person>: <task> (by <date or "not stated">) – Beleg: „<verbatim quote from the transcript>“"; if there are none: "Keine Aufgaben festgehalten.">

## Offene Punkte
<bullet list; "Keine." if none>"""

SUMMARY_PROMPT_DE = """Du bist ein Notizen-Assistent und erstellst aus der Mitschrift eines Vortrags, Trainings oder einer Informationsveranstaltung eine sachliche Zusammenfassung in Markdown, mit der Teilnehmende die Inhalte nachlesen können.

Regeln:
- Verwende nur Inhalte, die in der Mitschrift stehen. Erfinde oder ergänze nichts, auch kein Allgemeinwissen zum Thema.
- Gib wieder, was vermittelt wurde: Erklärungen, Begründungen, Beispiele, Zahlen, Arbeitsschritte und Empfehlungen. Lieber konkret als allgemein.
- Übernimm Sprechernamen so, wie sie in der Mitschrift stehen („Sprecher 2“ bleibt „Sprecher 2“). Nenne Personen nur, wo es für den Inhalt wichtig ist.
- „Fragen und Antworten“ enthält nur Fragen, die eine andere Person als die vortragende tatsächlich gestellt hat. Rhetorische Fragen der vortragenden Person zählen nicht; spricht nur eine Person, steht dort „Keine.“
- „Hinweise“ enthält nur, was ausdrücklich genannt wurde: Literatur, Materialien, Termine, Links, Aufgaben für die Teilnehmenden. Leite nichts ab und ergänze keine Übungen.
- Verwende einfache Aufzählungen ohne Verschachtelung.
- Die Mitschrift stammt aus automatischer Spracherkennung und kann Erkennungsfehler enthalten. Korrigiere offensichtliche Erkennungsfehler sinngemäß; rate Zahlen und Namen nicht. Übernimm Zahlen genau so, wie sie in der Mitschrift stehen, und wandle ausgeschriebene Zahlen nicht in Ziffern um („zweihundertzwölf“ bleibt „zweihundertzwölf“).
- Keine Einleitung, keine Nachbemerkung, nur die Zusammenfassung.

Halte dich exakt an diese Struktur (Überschriften genau so):

# Zusammenfassung
<Titel falls gegeben, Datum falls gegeben, sonst Zeile weglassen; die erste Überschrift lautet immer „# Zusammenfassung“>

## Überblick
<3–5 Sätze: worum es ging, für wen und mit welchem Ziel>

## Kernaussagen
<3–7 Aufzählungspunkte mit den wichtigsten Botschaften>

## Inhalte
<je Themenblock in der Reihenfolge der Veranstaltung eine Unterüberschrift „### Thema“, darunter Aufzählungspunkte mit den Einzelheiten>

## Fragen und Antworten
<im Regelfall „Keine.“; sonst je echter Frage einer anderen Person ein Punkt „- <Frage> – <Antwort>“, z. B. „- Gilt das auch im Lager? – Nur in den markierten Zonen.“>

## Hinweise
<im Regelfall „Keine.“; sonst je ausdrücklich genanntem Hinweis ein Punkt>"""

SUMMARY_PROMPT_EN = """You are a note-taking assistant. From the transcript of a talk, training or information session you write a factual summary in Markdown that participants can use to review the content.

Rules:
- Use only content that appears in the transcript. Do not invent or add anything, including general knowledge about the topic.
- Reproduce what was taught: explanations, reasons, examples, numbers, steps and recommendations. Prefer concrete over general.
- Keep speaker names exactly as they appear in the transcript ("Speaker 2" stays "Speaker 2"). Mention people only where it matters for the content.
- "Fragen und Antworten" contains only questions actually asked by someone other than the presenter. Rhetorical questions by the presenter do not count; if only one person speaks, write "Keine."
- "Hinweise" contains only what was explicitly mentioned: literature, materials, dates, links, assignments for participants. Do not infer anything and do not add exercises.
- Use plain bullet lists without nesting.
- The transcript comes from automatic speech recognition and may contain recognition errors. Correct obvious recognition errors by their evident meaning; do not guess numbers or names. Copy numbers exactly as they appear in the transcript and do not turn spelled-out numbers into digits.
- No introduction, no closing remark, only the summary.

Follow exactly this structure (headings verbatim):

# Zusammenfassung
<title if given, date if given, otherwise omit the line; the first heading is always "# Zusammenfassung">

## Überblick
<3–5 sentences: what it was about, for whom and with what goal>

## Kernaussagen
<3–7 bullets with the key messages>

## Inhalte
<per topic block, in the order presented, a subheading "### Topic" followed by bullets with the details>

## Fragen und Antworten
<usually "Keine."; otherwise one bullet "- <question> – <answer>" per real question from another person, e.g. "- Does this apply to the warehouse too? – Only in the marked zones.">

## Hinweise
<usually "Keine."; otherwise one bullet per explicitly mentioned item>"""

# Für lange Mitschriften: jeder Teil wird erst zu Notizen verdichtet, aus denen dann der Endtext entsteht.
PARTIAL_PROMPT_DE = """Du verdichtest einen Teil einer längeren Mitschrift zu Stichpunkt-Notizen. Aus den Notizen aller Teile entsteht später {target}.

Regeln:
- Nur Inhalte aus diesem Teil, nichts erfinden. Sprechernamen unverändert übernehmen.
- Die Mitschrift stammt aus automatischer Spracherkennung; offensichtliche Erkennungsfehler sinngemäß korrigieren, Zahlen und Namen nicht raten, Zahlen genau so übernehmen, wie sie dastehen.
- Keine Einleitung, nur die Notizen.

Halte fest:
{focus}"""

PARTIAL_PROMPT_EN = """You condense one part of a longer transcript into bullet-point notes. The notes of all parts will later become {target}.

Rules:
- Only content from this part, invent nothing. Keep speaker names unchanged.
- The transcript comes from automatic speech recognition; correct obvious recognition errors by their evident meaning, do not guess numbers or names, copy numbers exactly as written.
- No introduction, only the notes.

Record:
{focus}"""

_PARTIAL_DETAILS = {
    ("minutes", False): ("ein Besprechungsprotokoll", """- die besprochenen Themen in Reihenfolge mit den wichtigsten Aussagen, Zahlen und Namen,
- ausdrücklich festgelegte Entscheidungen und ausdrücklich übernommene oder zugewiesene Aufgaben, jeweils mit einem wörtlichen Zitat als Beleg,
- offene Fragen."""),
    ("minutes", True): ("meeting minutes", """- the topics discussed, in order, with the key statements, numbers and names,
- decisions explicitly made and tasks explicitly taken on or assigned, each with a verbatim quote as evidence,
- open questions."""),
    ("summary", False): ("eine Zusammenfassung zum Nachlesen", """- die behandelten Themen in Reihenfolge mit Erklärungen, Beispielen, Zahlen, Arbeitsschritten und Empfehlungen,
- Fragen, die andere Personen an die vortragende Person gestellt haben, mit den Antworten (keine rhetorischen Fragen),
- ausdrücklich genannte Literatur, Materialien, Termine und Links."""),
    ("summary", True): ("a summary for review", """- the topics covered, in order, with explanations, examples, numbers, steps and recommendations,
- questions other people asked the presenter, with the answers (no rhetorical questions),
- literature, materials, dates and links explicitly mentioned."""),
}


def system_prompt(kind: str, english: bool) -> str:
    if kind == "summary":
        return SUMMARY_PROMPT_EN if english else SUMMARY_PROMPT_DE
    return SYSTEM_PROMPT_EN if english else SYSTEM_PROMPT_DE


def partial_prompt(kind: str, english: bool) -> str:
    target, focus = _PARTIAL_DETAILS[(kind, english)]
    return (PARTIAL_PROMPT_EN if english else PARTIAL_PROMPT_DE).format(target=target, focus=focus)


def split_transcript(text: str, max_chars: int) -> list[str]:
    """Teilt eine Mitschrift an Zeilengrenzen (Sprecherwechseln) in Stücke von höchstens `max_chars` Zeichen.

    Zu lange Zeilen werden an Satzenden, notfalls an Leerzeichen und zuletzt hart geteilt."""
    if max_chars <= 0 or len(text) <= max_chars:
        return [text]
    pieces: list[str] = []
    for line in text.split("\n"):
        while len(line) > max_chars:
            window = line[:max_chars]
            cut = max(window.rfind(". "), window.rfind("? "), window.rfind("! "))
            cut = cut + 1 if cut > max_chars // 2 else window.rfind(" ")
            if cut <= max_chars // 2:
                cut = max_chars
            pieces.append(line[:cut].rstrip())
            line = line[cut:].lstrip()
        pieces.append(line)
    chunks: list[str] = []
    current = ""
    for piece in pieces:
        candidate = f"{current}\n{piece}" if current else piece
        if len(candidate) > max_chars and current:
            chunks.append(current)
            current = piece
        else:
            current = candidate
    if current.strip():
        chunks.append(current)
    return [chunk for chunk in chunks if chunk.strip()]


def format_recorded_at(value: str, english: bool) -> str:
    """ISO-8601-Zeitpunkt lesbar in der Wanduhrzeit des Geräts (Offset bleibt erhalten); sonst unverändert."""
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    return moment.strftime("%Y-%m-%d %H:%M" if english else "%d.%m.%Y, %H:%M")


def build_messages(
    transcript: str,
    language: str,
    title: str | None,
    recorded_at: str | None,
    kind: str = "minutes",
    condensed: bool = False,
) -> list[dict[str, str]]:
    """Baut System- und User-Nachricht für den Chat-Endpunkt; Titel und Datum nur, wenn gegeben.

    Mit `condensed=True` ist `transcript` nicht die Mitschrift selbst, sondern die Teilnotizen einer
    zu langen Mitschrift; das steht dann so in der User-Nachricht."""
    english = language == "en"
    lines: list[str] = []
    if title:
        lines.append(f"{'Title' if english else 'Titel'}: {title}")
    if recorded_at:
        lines.append(f"{'Date' if english else 'Datum'}: {format_recorded_at(recorded_at, english)}")
    if lines:
        lines.append("")
    if condensed:
        lines.append(
            "Notes on the transcript (it was too long and was condensed part by part, in order; quotes in the notes are verbatim from the transcript):"
            if english
            else "Notizen zur Mitschrift (sie war zu lang und wurde abschnittsweise vorverdichtet, in Reihenfolge; Zitate in den Notizen stammen wörtlich aus der Mitschrift):"
        )
    else:
        lines.append(f"{'Transcript' if english else 'Mitschrift'}:")
    lines.append("")
    lines.append(transcript)
    return [
        {"role": "system", "content": system_prompt(kind, english)},
        {"role": "user", "content": "\n".join(lines)},
    ]


def build_partial_messages(part: str, index: int, total: int, language: str, kind: str) -> list[dict[str, str]]:
    english = language == "en"
    header = f"Part {index} of {total} of the transcript:" if english else f"Teil {index} von {total} der Mitschrift:"
    return [
        {"role": "system", "content": partial_prompt(kind, english)},
        {"role": "user", "content": f"{header}\n\n{part}"},
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
    """Spricht einen OpenAI-kompatiblen Server (llama-server) über POST /v1/chat/completions an.

    Mitschriften bis `chunk_chars` Zeichen gehen in einem Aufruf an das Modell. Längere werden an
    Sprecherwechseln geteilt, Teil für Teil zu Notizen verdichtet (nacheinander, weil sich die Slots
    eines llama-servers den Kontext teilen) und aus den Notizen entsteht der Endtext."""

    #: Höchstens so viele Verdichtungsrunden; danach wird mit dem gearbeitet, was da ist.
    MAX_CONDENSE_ROUNDS = 3

    def __init__(
        self,
        base_url: str,
        model: str = "local",
        api_key: str | None = None,
        timeout_seconds: float = 180.0,
        max_output_tokens: int = 2048,
        temperature: float = 0.2,
        transport: httpx.AsyncBaseTransport | None = None,
        summary_max_output_tokens: int = 4096,
        chunk_chars: int = 60_000,
        partial_max_output_tokens: int = 1536,
    ) -> None:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else None
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout_seconds, headers=headers, transport=transport)
        self._model = model
        self._max_output_tokens = max_output_tokens
        self._summary_max_output_tokens = summary_max_output_tokens
        self._partial_max_output_tokens = partial_max_output_tokens
        self._chunk_chars = chunk_chars
        self._temperature = temperature

    async def write_notes(
        self, transcript: str, language: str, title: str | None, recorded_at: str | None, kind: str = "minutes"
    ) -> NotesResult:
        if kind not in NOTES_KINDS:
            raise ValueError(f"unbekannte Art: {kind}")
        started = time.monotonic()
        totals = _Usage()
        text = transcript
        condensed = False
        chunks = 1
        rounds = 0
        while len(text) > self._chunk_chars and rounds < self.MAX_CONDENSE_ROUNDS:
            parts = split_transcript(text, self._chunk_chars)
            if rounds == 0:
                chunks = len(parts)
            notes: list[str] = []
            for index, part in enumerate(parts, start=1):
                result = await self._complete(build_partial_messages(part, index, len(parts), language, kind), self._partial_max_output_tokens)
                totals.add(result)
                notes.append(f"[{index}/{len(parts)}]\n{result.notes}")
            text = "\n\n".join(notes)
            condensed = True
            rounds += 1
        max_tokens = self._summary_max_output_tokens if kind == "summary" else self._max_output_tokens
        final = await self._complete(build_messages(text, language, title, recorded_at, kind, condensed), max_tokens)
        totals.add(final)
        return NotesResult(
            notes=final.notes,
            model=final.model,
            prompt_tokens=totals.prompt_tokens,
            completion_tokens=totals.completion_tokens,
            latency_ms=int((time.monotonic() - started) * 1000),
            chunks=chunks,
        )

    async def _complete(self, messages: list[dict[str, str]], max_tokens: int) -> NotesResult:
        payload = {
            "model": self._model,
            "messages": messages,
            "temperature": self._temperature,
            "max_tokens": max_tokens,
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


@dataclass
class _Usage:
    """Summiert Tokenangaben über mehrere Aufrufe; bleibt None, sobald ein Aufruf keine liefert."""

    prompt_tokens: int | None = 0
    completion_tokens: int | None = 0

    def add(self, result: NotesResult) -> None:
        self.prompt_tokens = None if self.prompt_tokens is None or result.prompt_tokens is None else self.prompt_tokens + result.prompt_tokens
        self.completion_tokens = (
            None if self.completion_tokens is None or result.completion_tokens is None else self.completion_tokens + result.completion_tokens
        )


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

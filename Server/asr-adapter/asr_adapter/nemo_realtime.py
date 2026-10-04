"""Client für den Realtime-WebSocket von NeMo-Speech.cpp (`nemo-speech serve`).

Protokoll (v0.2.0): Nach dem Verbinden schickt der Server `session.created`. Der Client sendet einmal
`session.update`, danach rohe PCM16-Frames (mono, 16 kHz, little-endian) als Binärnachrichten und zum
Schluss `input_audio_buffer.commit`. Der Server liefert `...transcription.delta` (Token-Fragmente, zu
konkatenieren), `...transcription.completed` (eine Äußerung mit `transcript` und `words`) sowie zuletzt
`input_audio_buffer.committed`.
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable
from urllib.parse import urlsplit, urlunsplit

import httpx
import websockets
from websockets.asyncio.client import connect

from .whisper_client import TranscriberError

log = logging.getLogger("asr_adapter.nemo")

EVENT_DELTA = "conversation.item.input_audio_transcription.delta"
EVENT_COMPLETED = "conversation.item.input_audio_transcription.completed"
EVENT_COMMITTED = "input_audio_buffer.committed"


class NemoRealtimeError(TranscriberError):
    """Verbindungs- oder Protokollfehler; die API antwortet damit 503 `asr_unavailable`."""


@dataclass(frozen=True)
class FinalSegment:
    start: float
    end: float
    text: str


def language_for_nemo(language: str) -> str | None:
    """`X-Mitschrift-Language` → Session-Feld `language`; `auto` überlässt dem Modell die Erkennung."""
    code = language.strip().lower()
    if code in {"", "auto"}:
        return None
    return code


def http_base_url(ws_url: str) -> str:
    """ws://host:port → http://host:port (für Health-Prüfungen)."""
    parts = urlsplit(ws_url)
    scheme = {"ws": "http", "wss": "https"}.get(parts.scheme, parts.scheme)
    return urlunsplit((scheme, parts.netloc, "", "", ""))


ConnectFactory = Callable[[str, dict[str, str]], Awaitable[Any]]


async def _default_connect(url: str, headers: dict[str, str]) -> Any:
    return await connect(url, additional_headers=headers, max_size=None, open_timeout=10, close_timeout=5)


@dataclass
class NemoRealtimeSession:
    """Eine Streaming-Sitzung: Audio hinein, finale Äußerungen und vorläufiger Text heraus."""

    url: str
    api_key: str | None = None
    endpointing_ms: int | None = 700
    sample_rate: int = 16_000
    connect_factory: ConnectFactory = _default_connect

    audio_processed: float = 0.0
    failed: str | None = None
    _ws: Any = None
    _reader: asyncio.Task[None] | None = None
    _pending_finals: list[FinalSegment] = field(default_factory=list)
    _partial: str = ""
    _last_final_end: float = 0.0
    _committed: asyncio.Event = field(default_factory=asyncio.Event)
    _updated: asyncio.Event = field(default_factory=asyncio.Event)
    _changed: asyncio.Event = field(default_factory=asyncio.Event)
    _commit_sent: bool = False

    @property
    def is_open(self) -> bool:
        return self._ws is not None and self.failed is None

    async def open(self, language: str) -> None:
        url = self.url.rstrip("/")
        if not url.endswith("/v1/audio/transcriptions/realtime"):
            url = f"{url}/v1/audio/transcriptions/realtime"
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        try:
            self._ws = await self.connect_factory(url, headers)
            created = json.loads(await asyncio.wait_for(self._ws.recv(), timeout=10))
            if created.get("type") != "session.created":
                raise NemoRealtimeError(f"unerwartete Begrüßung: {created.get('type')}")
            session: dict[str, Any] = {
                "sample_rate": self.sample_rate,
                "automatic_punctuation": True,
                "word_timestamps": True,
            }
            code = language_for_nemo(language)
            if code:
                session["language"] = code
            if self.endpointing_ms:
                session["endpointing_ms"] = int(self.endpointing_ms)
            await self._ws.send(json.dumps({"type": "session.update", "session": session}))
        except NemoRealtimeError:
            await self.close()
            raise
        except Exception as error:  # noqa: BLE001
            await self.close()
            raise NemoRealtimeError(f"nemo-speech nicht erreichbar: {type(error).__name__}") from error
        self._reader = asyncio.create_task(self._read_loop())
        try:
            await asyncio.wait_for(self._updated.wait(), timeout=5)
        except asyncio.TimeoutError:
            # Manche Versionen bestätigen nicht; Audio darf trotzdem fließen.
            log.debug("session.updated blieb aus")
        self._raise_if_failed()

    async def feed(self, pcm: bytes) -> None:
        self._raise_if_failed()
        if self._ws is None or self._commit_sent:
            raise NemoRealtimeError("Realtime-Sitzung ist nicht offen.")
        try:
            await self._ws.send(pcm)
        except Exception as error:  # noqa: BLE001
            self._fail(f"Senden fehlgeschlagen: {type(error).__name__}")
            self._raise_if_failed()

    async def wait_processed(self, target_seconds: float, timeout: float) -> None:
        """Wartet, bis der Server mindestens `target_seconds` Audio verarbeitet hat (oder Timeout)."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while self.audio_processed < target_seconds and self.failed is None:
            remaining = deadline - loop.time()
            if remaining <= 0:
                return
            self._changed.clear()
            try:
                await asyncio.wait_for(self._changed.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                return

    async def finish(self, timeout: float = 15.0) -> None:
        """Schließt die Eingabe und wartet auf das letzte `completed` und `committed`."""
        if self._ws is None:
            return
        if self.failed is None and not self._commit_sent:
            self._commit_sent = True
            try:
                await self._ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
            except Exception as error:  # noqa: BLE001
                self._fail(f"Commit fehlgeschlagen: {type(error).__name__}")
        if self.failed is None:
            try:
                await asyncio.wait_for(self._committed.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                log.warning("nemo-speech hat den Commit nicht bestätigt")
        await self.close()

    def snapshot(self) -> tuple[list[FinalSegment], str]:
        """Neue finale Äußerungen seit dem letzten Aufruf und der aktuelle vorläufige Text."""
        finals, self._pending_finals = self._pending_finals, []
        return finals, self._partial.strip()

    @property
    def last_final_end(self) -> float:
        return self._last_final_end

    async def close(self) -> None:
        reader, self._reader = self._reader, None
        if reader is not None and reader is not asyncio.current_task():
            reader.cancel()
            try:
                await reader
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
        ws, self._ws = self._ws, None
        if ws is not None:
            try:
                await ws.close()
            except Exception:  # noqa: BLE001
                pass

    # --- intern -------------------------------------------------------------------------------

    def _raise_if_failed(self) -> None:
        if self.failed is not None:
            raise NemoRealtimeError(self.failed)

    def _fail(self, message: str) -> None:
        if self.failed is None:
            self.failed = message
            log.warning("nemo-speech: %s", message)
        self._committed.set()
        self._updated.set()
        self._changed.set()

    async def _read_loop(self) -> None:
        assert self._ws is not None
        try:
            async for raw in self._ws:
                if isinstance(raw, (bytes, bytearray)):
                    continue
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                self._handle(event)
            # Stream regulär zu Ende: ohne Commit ist das ein Abbruch durch den Server.
            if not self._commit_sent:
                self._fail("Verbindung vom Server geschlossen.")
        except websockets.ConnectionClosedOK:
            if not self._commit_sent:
                self._fail("Verbindung vom Server geschlossen.")
        except websockets.ConnectionClosed as error:
            if not (self._commit_sent and self._committed.is_set()):
                code = error.rcvd.code if error.rcvd is not None else "ohne Close-Frame"
                self._fail(f"Verbindung abgebrochen: {code}")
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001
            self._fail(f"Lesefehler: {type(error).__name__}")

    def _handle(self, event: dict[str, Any]) -> None:
        kind = event.get("type", "")
        if kind == "session.updated":
            self._updated.set()
        elif kind == EVENT_DELTA:
            self._partial += str(event.get("delta") or "")
            self._touch(event)
        elif kind == EVENT_COMPLETED:
            self._completed(event)
            self._touch(event)
        elif kind == EVENT_COMMITTED:
            self._touch(event)
            self._committed.set()
        elif kind == "error":
            detail = event.get("error") or event.get("message") or event
            self._fail(f"Serverfehler: {json.dumps(detail)[:200]}")
        else:
            self._touch(event)

    def _touch(self, event: dict[str, Any]) -> None:
        processed = event.get("audio_processed")
        if isinstance(processed, (int, float)):
            self.audio_processed = max(self.audio_processed, float(processed))
        self._changed.set()

    def _completed(self, event: dict[str, Any]) -> None:
        words = [w for w in (event.get("words") or []) if isinstance(w, dict)]
        text = str(event.get("transcript") or event.get("text") or "").strip()
        if not text and words:
            text = " ".join(str(w.get("word", "")) for w in words).strip()
        if words:
            start = float(words[0].get("start", self._last_final_end))
            end = float(words[-1].get("end", start))
        else:
            processed = event.get("audio_processed")
            start = self._last_final_end
            end = float(processed) if isinstance(processed, (int, float)) else max(self.audio_processed, start)
        self._partial = ""
        if text:
            self._pending_finals.append(FinalSegment(start=start, end=max(end, start), text=text))
            self._last_final_end = max(self._last_final_end, end)


class NemoHealthClient:
    """Erreichbarkeitsprüfung für `nemo-speech serve` über HTTP; erfüllt das Transcriber-Protokoll nur für Health und Schließen."""

    def __init__(self, ws_url: str, api_key: str | None = None, timeout_seconds: float = 3.0) -> None:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.AsyncClient(base_url=http_base_url(ws_url), headers=headers, timeout=timeout_seconds)

    async def transcribe(self, samples: Any, language: str) -> list[Any]:
        raise NemoRealtimeError("Das NeMo-Backend transkribiert nur über die Realtime-Sitzung.")

    async def is_healthy(self) -> bool:
        try:
            response = await self._client.get("/v1/models")
        except httpx.HTTPError:
            return False
        return response.status_code < 500

    async def aclose(self) -> None:
        await self._client.aclose()

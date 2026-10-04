"""Fake von `nemo-speech serve` für Tests: Realtime-WebSocket mit Deltas, completed und committed.

Pro 0,5 s empfangenem Audio ein Delta-Token ` t<k>`. Mit `completed_every_seconds` wird nach jeweils
so viel Audio eine Äußerung abgeschlossen (Endpointing-Simulation); sonst erst beim Commit.
`fail_after_bytes` bricht die Verbindung nach so vielen empfangenen Bytes ab (1006).
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from typing import Any

from websockets.asyncio.server import serve

SAMPLE_RATE = 16_000
TOKEN_SECONDS = 0.5


@dataclass
class FakeNemoServer:
    completed_every_seconds: float | None = None
    fail_after_bytes: int | None = None
    reject: bool = False
    sessions: list[dict[str, Any]] = field(default_factory=list)
    received_bytes: int = 0
    connections: int = 0
    _server: Any = None
    port: int = 0

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}"

    async def start(self) -> None:
        self._server = await serve(self._handler, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()

    async def _handler(self, ws: Any) -> None:
        self.connections += 1
        await ws.send(json.dumps({"type": "session.created", "event_id": "e1", "session": {"model": "fake"}}))
        audio_bytes = 0
        tokens_emitted = 0
        utterance_tokens: list[str] = []
        utterance_start = 0.0
        completed_mark = 0.0

        async def complete(end: float, event_id: str) -> None:
            nonlocal utterance_tokens, utterance_start
            words = []
            for i, token in enumerate(utterance_tokens):
                start = utterance_start + i * TOKEN_SECONDS
                words.append({"word": token.strip(), "start": round(start, 2), "end": round(start + TOKEN_SECONDS, 2), "confidence": 1})
            await ws.send(json.dumps({
                "type": "conversation.item.input_audio_transcription.completed",
                "event_id": event_id,
                "transcript": "".join(utterance_tokens).strip(),
                "words": words,
                "audio_processed": round(end, 2),
            }))
            utterance_tokens = []
            utterance_start = end

        async for message in ws:
            if isinstance(message, (bytes, bytearray)):
                audio_bytes += len(message)
                self.received_bytes += len(message)
                if self.fail_after_bytes is not None and audio_bytes >= self.fail_after_bytes:
                    await ws.close(code=1011, reason="simulierter Absturz")
                    return
                seconds = audio_bytes / 2 / SAMPLE_RATE
                while (tokens_emitted + 1) * TOKEN_SECONDS <= seconds:
                    token = f" t{tokens_emitted}"
                    tokens_emitted += 1
                    utterance_tokens.append(token)
                    await ws.send(json.dumps({
                        "type": "conversation.item.input_audio_transcription.delta",
                        "event_id": f"d{tokens_emitted}",
                        "delta": token,
                        "audio_processed": round(tokens_emitted * TOKEN_SECONDS, 2),
                    }))
                    if self.completed_every_seconds and tokens_emitted * TOKEN_SECONDS - completed_mark >= self.completed_every_seconds:
                        completed_mark = tokens_emitted * TOKEN_SECONDS
                        await complete(completed_mark, f"c{tokens_emitted}")
                continue
            event = json.loads(message)
            if event.get("type") == "session.update":
                self.sessions.append(event.get("session", {}))
                if self.reject:
                    await ws.send(json.dumps({"type": "error", "error": {"message": "abgelehnt"}}))
                    await ws.close()
                    return
                await ws.send(json.dumps({"type": "session.updated", "session": event.get("session", {})}))
            elif event.get("type") == "input_audio_buffer.commit":
                total = audio_bytes / 2 / SAMPLE_RATE
                if utterance_tokens:
                    await complete(total, "cfinal")
                await ws.send(json.dumps({"type": "input_audio_buffer.committed", "audio_processed": round(total, 2)}))
                await asyncio.sleep(0)

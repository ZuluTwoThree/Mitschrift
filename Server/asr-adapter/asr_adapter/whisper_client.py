from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import httpx
import numpy as np

from .wav import write_wav


@dataclass(frozen=True)
class RawSegment:
    """Ein von Whisper erkanntes Segment, Zeiten in Sekunden relativ zum übergebenen Audio."""

    start: float
    end: float
    text: str


class TranscriberError(RuntimeError):
    pass


class Transcriber(Protocol):
    async def transcribe(self, samples: np.ndarray, language: str) -> list[RawSegment]: ...

    async def is_healthy(self) -> bool: ...

    async def aclose(self) -> None: ...


class WhisperServerClient:
    """Spricht `whisper-server` (whisper.cpp) über POST /inference mit response_format=verbose_json an."""

    def __init__(self, base_url: str, timeout_seconds: float = 15.0) -> None:
        self._client = httpx.AsyncClient(base_url=base_url, timeout=timeout_seconds)

    async def transcribe(self, samples: np.ndarray, language: str) -> list[RawSegment]:
        files = {"file": ("segment.wav", write_wav(samples), "audio/wav")}
        data = {"response_format": "verbose_json", "language": language, "temperature": "0"}
        try:
            response = await self._client.post("/inference", files=files, data=data)
        except httpx.HTTPError as error:
            raise TranscriberError(f"whisper-server nicht erreichbar: {type(error).__name__}") from error
        if response.status_code != 200:
            raise TranscriberError(f"whisper-server antwortete mit HTTP {response.status_code}")
        try:
            payload = response.json()
        except ValueError as error:
            raise TranscriberError("whisper-server lieferte kein JSON") from error
        return parse_verbose_json(payload)

    async def is_healthy(self) -> bool:
        try:
            response = await self._client.get("/", timeout=3.0)
        except httpx.HTTPError:
            return False
        return response.status_code < 500

    async def aclose(self) -> None:
        await self._client.aclose()


def parse_verbose_json(payload: dict[str, Any]) -> list[RawSegment]:
    segments: list[RawSegment] = []
    for item in payload.get("segments", []):
        text = str(item.get("text", "")).strip()
        if not text:
            continue
        segments.append(RawSegment(start=float(item["start"]), end=float(item["end"]), text=text))
    return segments

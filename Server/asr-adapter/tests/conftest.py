from __future__ import annotations

import uuid
from dataclasses import dataclass, field

import httpx
import numpy as np
import pytest

from asr_adapter.app import create_app
from asr_adapter.config import Settings
from asr_adapter.wav import SAMPLE_RATE, write_wav
from asr_adapter.whisper_client import RawSegment

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@dataclass
class FakeWhisper:
    """Liefert pro volle Sekunde Audio ein Segment [k, k+1) mit Text `s<k>`. Zählt Aufrufe."""

    calls: int = 0
    durations: list[float] = field(default_factory=list)
    healthy: bool = True

    async def transcribe(self, samples: np.ndarray, language: str) -> list[RawSegment]:
        self.calls += 1
        seconds = len(samples) / SAMPLE_RATE
        self.durations.append(seconds)
        return [RawSegment(start=float(k), end=float(k + 1), text=f"s{k}") for k in range(int(seconds))]

    async def is_healthy(self) -> bool:
        return self.healthy

    async def aclose(self) -> None:
        return None


def make_settings(**overrides: object) -> Settings:
    return Settings(token=TOKEN, model_name="ggml-test.bin", **overrides)  # type: ignore[arg-type]


def wav_bytes(seconds: float, *, tone: bool = True) -> bytes:
    n = int(seconds * SAMPLE_RATE)
    if tone:
        t = np.arange(n) / SAMPLE_RATE
        samples = (np.sin(2 * np.pi * 440 * t) * 8000).astype("<i2")
    else:
        samples = np.zeros(n, dtype="<i2")
    return write_wav(samples)


def segment_headers(session_id: str, sequence: int, language: str = "de") -> dict[str, str]:
    return {
        **AUTH,
        "Content-Type": "audio/wav",
        "X-Mitschrift-Session": session_id,
        "X-Mitschrift-Sequence": str(sequence),
        "X-Mitschrift-Language": language,
    }


@pytest.fixture
def whisper() -> FakeWhisper:
    return FakeWhisper()


@pytest.fixture
def settings() -> Settings:
    return make_settings()


@pytest.fixture
async def client(settings: Settings, whisper: FakeWhisper):
    app = create_app(settings, whisper)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture
def session_id() -> str:
    return str(uuid.uuid4())

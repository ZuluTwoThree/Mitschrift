from __future__ import annotations

import struct

import numpy as np
import pytest

from asr_adapter.wav import SAMPLE_RATE, WavError, parse_wav, write_wav


def test_roundtrip() -> None:
    samples = (np.arange(SAMPLE_RATE * 2) % 1000).astype("<i2")
    parsed = parse_wav(write_wav(samples), min_seconds=1.0, max_seconds=5.0)
    assert np.array_equal(parsed, samples)


def test_extra_chunks_are_skipped() -> None:
    samples = np.zeros(SAMPLE_RATE * 2, dtype="<i2")
    data = bytearray(write_wav(samples))
    # LIST-Chunk zwischen Header und data einschieben, wie ffmpeg es tut
    list_chunk = b"LIST" + struct.pack("<I", 4) + b"INFO"
    insert_at = data.index(b"data")
    data[insert_at:insert_at] = list_chunk
    parsed = parse_wav(bytes(data), min_seconds=1.0, max_seconds=5.0)
    assert len(parsed) == SAMPLE_RATE * 2


@pytest.mark.parametrize(
    ("channels", "rate", "bits", "code"),
    [(2, 16_000, 16, "invalid_audio"), (1, 44_100, 16, "invalid_audio"), (1, 16_000, 8, "invalid_audio")],
)
def test_wrong_format(channels: int, rate: int, bits: int, code: str) -> None:
    frames = SAMPLE_RATE * 2
    pcm = b"\0" * (frames * channels * bits // 8)
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVE"
        + b"fmt "
        + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
        + b"data"
        + struct.pack("<I", len(pcm))
    )
    with pytest.raises(WavError) as info:
        parse_wav(header + pcm, min_seconds=1.0, max_seconds=5.0)
    assert info.value.code == code


def test_garbage() -> None:
    with pytest.raises(WavError):
        parse_wav(b"RIFFxxxxWAVE", min_seconds=1.0, max_seconds=5.0)

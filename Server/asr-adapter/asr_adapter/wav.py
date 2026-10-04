from __future__ import annotations

import io
import struct
import wave

import numpy as np

SAMPLE_RATE = 16_000


class WavError(ValueError):
    """Ungültiges Audio. `code` ist der Fehlercode für die API-Antwort."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def parse_wav(data: bytes, *, min_seconds: float, max_seconds: float) -> np.ndarray:
    """Liest ein WAV und liefert Int16-Mono-PCM bei 16 kHz. Konvertiert nicht."""
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise WavError("invalid_audio", "Kein gültiges WAV.")

    fmt: tuple[int, int, int, int] | None = None
    pcm: bytes | None = None
    pos = 12
    while pos + 8 <= len(data):
        chunk_id = data[pos : pos + 4]
        (chunk_size,) = struct.unpack_from("<I", data, pos + 4)
        body = data[pos + 8 : pos + 8 + chunk_size]
        if chunk_id == b"fmt " and len(body) >= 16:
            tag, channels, rate, _byte_rate, _align, bits = struct.unpack_from("<HHIIHH", body, 0)
            fmt = (tag, channels, rate, bits)
        elif chunk_id == b"data":
            pcm = body
        pos += 8 + chunk_size + (chunk_size & 1)

    if fmt is None or pcm is None:
        raise WavError("invalid_audio", "WAV ohne fmt- oder data-Chunk.")
    tag, channels, rate, bits = fmt
    if tag != 1 or bits != 16:
        raise WavError("invalid_audio", "Erwartet PCM mit 16 Bit.")
    if channels != 1:
        raise WavError("invalid_audio", "Erwartet mono.")
    if rate != SAMPLE_RATE:
        raise WavError("invalid_audio", f"Erwartet {SAMPLE_RATE} Hz.")

    samples = np.frombuffer(pcm[: len(pcm) - (len(pcm) % 2)], dtype="<i2")
    seconds = len(samples) / SAMPLE_RATE
    if seconds < min_seconds or seconds > max_seconds:
        raise WavError(
            "invalid_duration",
            f"Segmentlänge {seconds:.2f} s liegt außerhalb von {min_seconds:.1f}–{max_seconds:.1f} s.",
        )
    return samples


def write_wav(samples: np.ndarray) -> bytes:
    """Schreibt Int16-Mono-PCM als 16-kHz-WAV."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(np.ascontiguousarray(samples, dtype="<i2").tobytes())
    return buffer.getvalue()

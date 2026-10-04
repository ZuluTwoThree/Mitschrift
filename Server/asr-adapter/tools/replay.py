#!/usr/bin/env python3
"""Spielt eine WAV-Datei (16 kHz, mono, PCM16) wie die App segmentweise in den Adapter ein.

    uv run python tools/replay.py --url http://127.0.0.1:8765 --token "$MITSCHRIFT_TOKEN" aufnahme.wav

Nützlich, um Aufnahmen vom Gerät reproduzierbar durch den Adapter zu schicken und das Ergebnis
mit einer Offline-Transkription zu vergleichen. Gibt den finalen Text aus und druckt mit
--verbose je Segment Latenz sowie Zahl der finalen und vorläufigen Abschnitte.
"""
from __future__ import annotations

import argparse
import struct
import sys
import time
import uuid
import wave

import httpx

SAMPLE_RATE = 16_000
SEGMENT_SECONDS = 2.5
OVERLAP_SECONDS = 0.3


def wav_bytes(samples: bytes) -> bytes:
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(samples), b"WAVE", b"fmt ", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16, b"data", len(samples),
    )
    return header + samples


def segments(pcm: bytes) -> list[bytes]:
    step = int((SEGMENT_SECONDS - OVERLAP_SECONDS) * SAMPLE_RATE) * 2
    length = int(SEGMENT_SECONDS * SAMPLE_RATE) * 2
    out: list[bytes] = []
    offset = 0
    while offset + length <= len(pcm):
        out.append(pcm[offset : offset + length])
        offset += step
    rest = pcm[offset:]
    if len(rest) > (length - step):  # mehr als nur Überlappung übrig
        minimum = SAMPLE_RATE * 2  # 1 s
        if len(rest) < minimum:
            rest = rest + b"\x00" * (minimum - len(rest))
        out.append(rest)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("wav")
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    parser.add_argument("--token", required=True)
    parser.add_argument("--language", default="de")
    parser.add_argument("--realtime", action="store_true", help="Segmente im 2,2-s-Takt senden statt so schnell wie möglich")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    with wave.open(args.wav, "rb") as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != SAMPLE_RATE:
            print("Erwartet 16 kHz, mono, 16 Bit PCM", file=sys.stderr)
            return 2
        pcm = handle.readframes(handle.getnframes())

    session_id = str(uuid.uuid4())
    headers = {"Authorization": f"Bearer {args.token}", "X-Mitschrift-Client": "replay/0.1"}
    finals: list[dict] = []
    partial: list[dict] = []
    with httpx.Client(base_url=args.url, timeout=30.0) as client:
        for sequence, segment in enumerate(segments(pcm)):
            started = time.perf_counter()
            response = client.post(
                "/v1/live-transcriptions/segments",
                content=wav_bytes(segment),
                headers={
                    **headers,
                    "Content-Type": "audio/wav",
                    "X-Mitschrift-Session": session_id,
                    "X-Mitschrift-Sequence": str(sequence),
                    "X-Mitschrift-Language": args.language,
                },
            )
            if response.status_code != 200:
                print(f"seq={sequence}: HTTP {response.status_code} {response.text}", file=sys.stderr)
                return 1
            body = response.json()
            finals.extend(body["final"])
            partial = body["partial"]
            if args.verbose:
                print(
                    f"seq={sequence:3d} window={body['windowStart']:6.1f}-{body['windowEnd']:6.1f} "
                    f"rtt={1000 * (time.perf_counter() - started):4.0f}ms final=+{len(body['final'])} partial={len(partial)}"
                )
            if args.realtime:
                time.sleep(max(0.0, (SEGMENT_SECONDS - OVERLAP_SECONDS) - (time.perf_counter() - started)))
        response = client.post(f"/v1/live-transcriptions/{session_id}/finish", headers=headers)
        response.raise_for_status()
        finals.extend(response.json()["final"])

    print(" ".join(segment["text"].strip() for segment in finals if segment["text"].strip()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

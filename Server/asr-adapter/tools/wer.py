#!/usr/bin/env python3
"""Wortfehlerrate (WER) einer Hypothese gegenüber einer Referenz, beide als Textdateien.

    uv run python tools/wer.py referenz.txt hypothese.txt

Normalisiert auf Kleinbuchstaben und Wort-Token (Buchstaben, Ziffern, Umlaute); Satzzeichen zählen
nicht. Gedacht für den Vergleich von Live-Transkription (tools/replay.py) mit einer Offline-Transkription.
"""
from __future__ import annotations

import re
import sys


def tokens(text: str) -> list[str]:
    return re.findall(r"[a-zäöüß0-9]+", text.lower())


def wer(reference: str, hypothesis: str) -> tuple[float, int, int]:
    ref, hyp = tokens(reference), tokens(hypothesis)
    row = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, row = row, [i] + [0] * len(hyp)
        for j in range(1, len(hyp) + 1):
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (ref[i - 1] != hyp[j - 1]))
    return row[len(hyp)] / max(1, len(ref)), len(ref), len(hyp)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as ref, open(sys.argv[2], encoding="utf-8") as hyp:
        rate, n_ref, n_hyp = wer(ref.read(), hyp.read())
    print(f"WER {rate * 100:.1f} %  (Referenz {n_ref} Wörter, Hypothese {n_hyp} Wörter)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

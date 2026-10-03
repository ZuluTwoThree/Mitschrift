#!/bin/zsh
# Misst den Echtzeitfaktor von whisper-cli für ein WAV und ein Modell.
# Aufruf: zsh Scripts/bench-asr.sh <datei.wav> [modellname=small] [threads=4]
# Ausgabe: eine Markdown-Tabellenzeile für docs/ops/benchmarks.md
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
WAV="${1:?WAV-Datei fehlt}"
MODEL_NAME="${2:-small}"
THREADS="${3:-4}"
MODEL="${MODELS_DIR:-$PROJECT_DIR/Models}/ggml-$MODEL_NAME.bin"
WHISPER_CLI="${WHISPER_CLI:-whisper-cli}"

[[ -f "$MODEL" ]] || { echo "Modell fehlt: $MODEL" >&2; exit 1; }

duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WAV")"
start=$(python3 -c 'import time; print(time.perf_counter())')
"$WHISPER_CLI" -m "$MODEL" -f "$WAV" -l de -t "$THREADS" -nt -np >/dev/null 2>&1
end=$(python3 -c 'import time; print(time.perf_counter())')

python3 - "$MODEL_NAME" "$THREADS" "$duration" "$start" "$end" <<'EOF'
import platform, sys
model, threads, duration, start, end = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
elapsed = end - start
print("| Datum | Rechner | Modell | Threads | Audio (s) | Dauer (s) | Echtzeitfaktor |")
print("| --- | --- | --- | --- | --- | --- | --- |")
import datetime
print(f"| {datetime.date.today()} | {platform.machine()} | {model} | {threads} | {duration:.1f} | {elapsed:.2f} | {elapsed / duration:.3f} |")
EOF

#!/bin/sh
# Startet whisper-server (nur localhost) und den Mitschrift-Adapter.
# Konfiguration über Umgebungsvariablen, siehe README.md. MITSCHRIFT_TOKEN ist Pflicht.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${MODEL:-$SCRIPT_DIR/../../Models/ggml-small.bin}"
LANGUAGE="${LANGUAGE:-de}"
THREADS="${THREADS:-4}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8765}"
WHISPER_PORT="${WHISPER_PORT:-8080}"
WHISPER_BIN="${WHISPER_BIN:-whisper-server}"
# Optionen für whisper-server. Standard: Nicht-Sprache-Tokens wie [Musik] unterdrücken und Beam-Suche;
# auf einer 48-s-Aufnahme mit Musik im Hintergrund sank die Wortfehlerrate damit von 37,6 % auf 10,9 %.
WHISPER_ARGS="${WHISPER_ARGS:--sns -bs 5}"

if [ -z "${MITSCHRIFT_TOKEN:-}" ]; then
  echo "MITSCHRIFT_TOKEN ist nicht gesetzt." >&2
  exit 1
fi
if [ ! -f "$MODEL" ]; then
  echo "Modell nicht gefunden: $MODEL" >&2
  exit 1
fi

export MODEL LANGUAGE HOST PORT
export WHISPER_URL="http://127.0.0.1:$WHISPER_PORT"

# shellcheck disable=SC2086  # WHISPER_ARGS soll in einzelne Optionen zerfallen
"$WHISPER_BIN" --host 127.0.0.1 --port "$WHISPER_PORT" -m "$MODEL" -l "$LANGUAGE" -t "$THREADS" $WHISPER_ARGS &
WHISPER_PID=$!

cd "$SCRIPT_DIR"
uv run uvicorn asr_adapter.app:app --host "$HOST" --port "$PORT" &
ADAPTER_PID=$!

# Die Shell bleibt als Aufseher am Leben: Endet oder stirbt einer der beiden Prozesse, wird der andere
# mit beendet, damit kein verwaister whisper-server den Port 8080 belegt.
cleanup() {
  kill "$ADAPTER_PID" "$WHISPER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait "$ADAPTER_PID"
STATUS=$?
exit "$STATUS"

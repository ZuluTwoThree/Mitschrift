#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
MODELS_DIR="${MODELS_DIR:-$PROJECT_DIR/Models}"
mkdir -p "$MODELS_DIR"

download_model() {
  local model_name="$1"
  local expected_sha="$2"
  local destination="$MODELS_DIR/ggml-$model_name.bin"
  local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model_name.bin"

  if [[ ! -f "$destination" ]]; then
    echo "Lade Whisper-Modell '$model_name' herunter …"
    curl -L --fail --retry 3 --output "$destination" "$url"
  fi

  local actual_sha
  actual_sha="$(shasum -a 1 "$destination" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Prüfsummenfehler für $destination" >&2
    exit 1
  fi
  echo "OK: $destination"
}

download_model "base" "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
download_model "small" "55356645c2b361a969dfd0ef2c5a50d530afd8d5"

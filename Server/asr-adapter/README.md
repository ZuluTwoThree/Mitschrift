# ASR-Adapter

Kleiner Dienst vor `whisper-server` (whisper.cpp), der den Segment-Vertrag aus `docs/api/segment-contract.md` umsetzt: Sessions, Sequenznummern, Rollpuffer mit Finalisierung, Idempotenz, Token-Prüfung und Limits. `whisper-server` selbst bleibt auf `127.0.0.1` und ist nie direkt erreichbar.

## Voraussetzungen

- Python 3.11 oder neuer und [uv](https://docs.astral.sh/uv/)
- `whisper-server` aus whisper.cpp (macOS: `brew install whisper-cpp`; Linux: aus den Quellen bauen)
- Ein ggml-Modell, z. B. `Models/ggml-small.bin` aus dem Repo-Download-Skript

## Start

```sh
cd Server/asr-adapter
uv sync
export MITSCHRIFT_TOKEN="$(openssl rand -hex 32)"   # einmal erzeugen und sicher ablegen
MODEL=../../Models/ggml-small.bin ./run.sh
```

`run.sh` startet `whisper-server` auf `127.0.0.1:8080` und den Adapter auf `127.0.0.1:8765`. Die Veröffentlichung im Tailnet übernimmt `tailscale serve`, siehe `docs/ops/tailscale.md`.

## Konfiguration (Umgebungsvariablen)

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `MITSCHRIFT_TOKEN` | Pflicht | Bearer-Token, den die App mitschickt |
| `MODEL` | `../../Models/ggml-small.bin` | Pfad zum ggml-Modell |
| `LANGUAGE` | `de` | Standardsprache für `whisper-server` |
| `THREADS` | `4` | Threads für whisper.cpp |
| `HOST` / `PORT` | `127.0.0.1` / `8765` | Adresse des Adapters |
| `WHISPER_PORT` | `8080` | Port von `whisper-server` |
| `WINDOW_SECONDS` | `12` | Rollpuffer je Session |
| `FINALIZE_MARGIN_SECONDS` | `3` | Abstand zum Pufferende, ab dem Segmente final sind |
| `MAX_SESSIONS` | `4` | Parallele Sessions |
| `SESSION_IDLE_TIMEOUT_SECONDS` | `60` | Inaktive Sessions werden beendet und freigegeben |
| `WHISPER_TIMEOUT_SECONDS` | `15` | Timeout je Inferenz |

## Tests

```sh
uv run pytest
```

Die Tests laufen ohne `whisper-server` gegen einen Fake und erzeugen synthetische WAV-Daten.

## Manueller Test

```sh
curl -s http://127.0.0.1:8765/v1/health
curl -s -X POST http://127.0.0.1:8765/v1/live-transcriptions/segments \
  -H "Authorization: Bearer $MITSCHRIFT_TOKEN" \
  -H "Content-Type: audio/wav" \
  -H "X-Mitschrift-Session: $(uuidgen | tr A-Z a-z)" \
  -H "X-Mitschrift-Sequence: 0" \
  -H "X-Mitschrift-Language: de" \
  --data-binary @segment.wav
```

`segment.wav` muss PCM 16 Bit, mono, 16 kHz und 1 bis 5 s lang sein, z. B. aus `ffmpeg -i quelle.m4a -ar 16000 -ac 1 -c:a pcm_s16le -t 2.5 segment.wav`.

## Verhalten

- Pro Session hält der Adapter höchstens 12 s Audio im Speicher und transkribiert nach jedem Segment das gesamte Fenster.
- Segmente, die mindestens 3 s vor dem Pufferende enden, werden als `final` geliefert und aus dem Puffer entfernt. Der Rest ist `partial` und wird mit der nächsten Antwort ersetzt.
- Ein erneut gesendetes Segment mit bekannter Sequenznummer liefert die gespeicherte Antwort ohne neue Inferenz.
- Es werden weder Audio noch Transkripte geschrieben oder protokolliert. Logs enthalten Session-ID, Sequenznummer, Fensterlänge und Latenz.

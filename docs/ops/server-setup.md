# ASR-Server einrichten (Ubuntu 24.04, NVIDIA-GPU)

Ziel: whisper.cpp (CUDA) und NeMo-Speech.cpp laufen als Container, der Adapter davor ebenfalls, nur der Adapter ist über `tailscale serve` im Tailnet erreichbar. Alles unter `Server/deploy/`. Hostnamen und Token stehen nicht im Repository; Platzhalter sind `<server>` und `<nutzer>`.

## Voraussetzungen

- Ubuntu 24.04, NVIDIA-Treiber mit CUDA 12.8 oder neuer (`nvidia-smi` zeigt die Version), Tailscale verbunden.
- GPU-Speicher: `small` ~1 GB, `large-v3-turbo` q5_0 ~1,5 GB, `large-v3` f16 ~4 GB, Nemotron 3.5 ASR 0.6B q8 ~1,5 GB, Nemotron 3 Diarization ~0,3 GB. Für den Vergleich aller Modelle sollten 8 GB frei sein; andere GPU-Dienste vorher prüfen (`nvidia-smi --query-compute-apps=process_name,used_memory --format=csv`).
- Das offizielle whisper.cpp-CUDA-Image ist für die Architekturen 75/80/86/90 gebaut (Turing bis Hopper, also auch RTX 3090). Für Blackwell (RTX 50xx) muss das Image selbst mit `-DCMAKE_CUDA_ARCHITECTURES=120` gebaut werden.

## 1. Einmalig mit sudo: Docker und NVIDIA Container Toolkit

Vom Mac aus, fragt das Server-Passwort ab:

```sh
ssh -t <server> 'sudo bash -s' < Server/deploy/bootstrap-ubuntu.sh
```

Das Skript installiert Docker (falls nicht vorhanden), das NVIDIA Container Toolkit, konfiguriert die Docker-Runtime und nimmt den Nutzer in die Gruppe `docker` auf. Danach neu anmelden und prüfen:

```sh
docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
```

## 2. Modelle laden

Auf dem Server, ohne sudo:

```sh
mkdir -p ~/mitschrift/models && cd ~/mitschrift/models
W=https://huggingface.co/ggerganov/whisper.cpp/resolve/main
for m in ggml-small.bin ggml-medium.bin ggml-large-v3-turbo-q5_0.bin ggml-large-v3-turbo.bin ggml-large-v3.bin; do
  curl -L --fail --retry 5 -o "$m" "$W/$m"
done
curl -L --fail -o nemotron-3.5-asr-streaming-0.6b.q8_0.gguf \
  https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/main/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf
curl -L --fail -o parakeet-tdt-0.6b-v3.q8_0.gguf \
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/main/parakeet-tdt-0.6b-v3.q8_0.gguf
curl -L --fail -o Nemotron-3-Diarization.q8_0.gguf \
  https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/main/Nemotron-3-Diarization.q8_0.gguf
```

Modellwahl für Deutsch: In NeMo-Speech.cpp kann nur `nemotron-3.5-asr-streaming-0.6b` live streamen (40 Sprachen, Satzzeichen); `parakeet-tdt-0.6b-v3` arbeitet nur offline. Canary wird nicht unterstützt.

## 3. Repository und Konfiguration

```sh
git clone git@github.com:ZuluTwoThree/Mitschrift.git ~/mitschrift/repo
cd ~/mitschrift/repo/Server/deploy
cp .env.example .env
```

In `.env` eintragen: `MITSCHRIFT_TOKEN` (einmal `openssl rand -hex 32`), `MODELS_DIR=/home/<nutzer>/mitschrift/models`, Modell und Ports. Wenn Port 8080 auf dem Host belegt ist, bleibt das egal: Die Container binden auf `127.0.0.1:${WHISPER_PORT}` (Standard 8090) und `127.0.0.1:${NEMO_PORT}` (8095).

## 4. Starten

```sh
cd ~/mitschrift/repo/Server/deploy
docker compose --profile whisper --profile nemo build
docker compose --profile whisper --profile nemo up -d
docker compose ps
curl -s http://127.0.0.1:8765/v1/health
```

Nur Whisper: `--profile whisper`. Der Adapter spricht `whisper` über das Compose-Netz an; `nemo-speech` ist in der ersten Ausbaustufe nur für den Vergleich (`tools/replay.py` gegen den Adapter, eigener Vergleich gegen `http://127.0.0.1:8095/v1/audio/transcriptions`).

## 5. Im Tailnet veröffentlichen

Einmalig mit sudo auf dem Server (Admin-Konsole: „HTTPS Certificates“ aktiv, ACL siehe `docs/ops/tailscale.md`):

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:8765
tailscale serve status
```

Falls auf dem Server bereits andere `serve`-Einträge auf anderen Ports bestehen, bleiben sie unberührt; 443 kommt dazu. Die App bekommt `https://<server>.<tailnet>.ts.net` und den Token.

## 6. Prüfen

```sh
# vom Mac
curl -s https://<server>.<tailnet>.ts.net/v1/health
cd Server/asr-adapter
uv run python tools/replay.py --url https://<server>.<tailnet>.ts.net --token "$MITSCHRIFT_TOKEN" --language de --verbose aufnahme.wav
```

## Betrieb

- Logs: `docker compose logs -f adapter whisper nemo-speech`; Docker rotiert mit `json-file` standardmäßig nicht, deshalb in `/etc/docker/daemon.json` `{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"5"}}` setzen (sudo) oder in Compose `logging:` ergänzen.
- Updates: `git pull`, `docker compose pull`, `docker compose build`, `docker compose up -d`.
- Modell wechseln: `.env` anpassen, `docker compose up -d` (nur der betroffene Dienst startet neu).
- Nichts aus den Containern ist von außen erreichbar; `tailscale funnel status` muss leer bleiben.

## Fehlerbilder

- `could not select device driver "nvidia"`: Toolkit fehlt oder Docker nicht neu gestartet, Bootstrap erneut ausführen.
- `no kernel image is available for execution`: GPU-Architektur nicht im Image enthalten (Blackwell), eigenes Image bauen.
- Adapter `503 asr_unavailable`: whisper-server lädt noch (große Modelle brauchen 10 bis 30 s) oder ist abgestürzt (`docker compose logs whisper`).

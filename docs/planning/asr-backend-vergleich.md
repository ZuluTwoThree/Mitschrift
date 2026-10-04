# ASR-Backend-Vergleich und Anbindung von nemo-speech.cpp

Stand: 2026-10-04. Ergänzt `umsetzungsplan.md` (Meilenstein A, Modellentscheidung) um den neuen Server mit mehr RAM und GPU und um NVIDIA nemo-speech.cpp als zweites Backend. Ziel: Modell und Laufzeit mit Zahlen an den echten Aufnahmen entscheiden, nicht nach Datenblatt.

## Ausgangslage

- Der Adapter (`Server/asr-adapter`) spricht `whisper-server` (whisper.cpp) über HTTP an und baut Live-Verhalten mit Rollpuffer, Finalisierungsregeln und Überlaufschutz nach. Das funktioniert, verliert aber bei pausenloser Rede an erzwungenen Schnittstellen Wörter (Messung 10 bis 13 % Abweichung von der Offline-Transkription, siehe Adapter-README).
- `small` auf dem Mac (M3, 8 GB) ist die Obergrenze; `large-v3-turbo` lief offline mit Echtzeitfaktor 0,68, für das Fensterverfahren zu langsam.
- nemo-speech.cpp (Container `nvcr.io/nvidia/nemo-speech.cpp:0.1.0`) bietet Riva-kompatibles gRPC mit echtem Streaming (vorläufige und finale Ergebnisse vom Modell selbst), CUDA-Inferenz, Apache-2.0-Lizenz. Einschränkungen laut Container-Seite: nur CUDA (kein CPU-, kein Metal-Backend), Architektur linux/amd64 und linux/arm64, als ASR-Modelle gelistet sind Nemotron-Speech Streaming English 0.6B, Nemotron 3.5 ASR Streaming 0.6B und Parakeet CTC 1.1B. Ob und wie das multilinguale Parakeet-TDT 0.6B v3 (Deutsch) in dieser Version läuft, ist offen und das erste Tor dieses Plans.
- Alternative mit gleicher Modellfamilie: parakeet.cpp (ggml, C-API, cache-aware Streaming), falls der Container Deutsch nicht abdeckt.

## Entscheidungskriterien

Gemessen an denselben Aufnahmen, Reihenfolge nach Gewicht:

1. **Wortfehlerrate Deutsch** gegenüber einer Offline-Referenz mit dem jeweils besten Modell und gegenüber einer manuell korrigierten Referenz für mindestens eine Aufnahme.
2. **Verluste an Schnittstellen**: Zahl fehlender Wörter an Finalisierungsgrenzen (Diff gegen Offline-Text).
3. **Latenz** pro Fenster bzw. bis zum finalen Abschnitt, gemessen mit `tools/replay.py --realtime`.
4. **Halluzinationen** bei Musik, Stille und Nebengeräuschen (Tags wie `[Musik]`, erfundene Sätze).
5. **Satzzeichen, Groß-/Kleinschreibung, Zahlen**, weil die Mitschrift ohne Nachbearbeitung lesbar sein soll.
6. **Betrieb**: RAM/VRAM, Startzeit, Stabilität über 60 min, parallele Sessions.

## Arbeitspakete

### WP8 — Server aufsetzen und Backends installieren

Voraussetzung: Hardware-Daten (`nproc; free -h; lspci | grep -iE 'vga|3d|nvidia'; nvidia-smi`), Betriebssystem, Docker vorhanden, SSH-Zugang oder Ausführung durch dich.

- whisper.cpp aus dem Quellcode mit CUDA bauen (`cmake -B build -DGGML_CUDA=1`), `whisper-server` als systemd-Dienst, Modelle `small`, `medium`, `large-v3-turbo` (q5_0 und f16), `large-v3`. `Scripts/download-models.sh` um die Modelle mit Prüfsummen erweitern.
- nemo-speech.cpp als Container mit `--runtime=nvidia --gpus all`, Modelle als GGUF unter `/models`, gRPC auf 50051 nur an `127.0.0.1` gebunden.
- **Tor Deutsch:** Prüfen, ob ein deutschfähiges Modell (Parakeet-TDT 0.6B v3, Canary 1B v2) als GGUF für den Container verfügbar ist oder sich konvertieren lässt. Falls nein: parakeet.cpp mit Parakeet-TDT 0.6B v3 als Ersatz aufsetzen. Ergebnis in diesem Dokument festhalten, bevor WP10 beginnt.
- Adapter mit `uv` installieren, `tailscale serve` auf den Adapter zeigen lassen (Anleitung `docs/ops/tailscale.md`), Token setzen.

Prüfung: `whisper-server` und nemo-speech.cpp antworten lokal; `riva_streaming_asr_client` bzw. ein Python-Testclient liefert für eine WAV ein Ergebnis.

### WP9 — Messmatrix

Werkzeuge: `tools/replay.py` (segmentweises Einspielen wie die App), `tools/wer.py` (Wortfehlerrate), `Scripts/bench-asr.sh` (Echtzeitfaktor offline).

Aufnahmen: die drei vorhandenen (48 s Deutsch mit Musik, 56 s Englisch, 10 s Sprachsynthese) plus mindestens zwei neue: ein deutsches Gespräch von 3 bis 5 Minuten mit natürlichen Pausen und Fachbegriffen, und eine Aufnahme mit zwei Sprechenden. Referenzen: Offline-Transkription mit `large-v3`, für eine deutsche Aufnahme zusätzlich manuell korrigiert.

| Backend | Modell | Messung |
| --- | --- | --- |
| whisper.cpp CUDA | small, medium, large-v3-turbo q5_0, large-v3-turbo f16, large-v3 | WER, Latenz pro Fenster, RTF, Halluzinationen |
| nemo-speech.cpp oder parakeet.cpp | Parakeet-TDT 0.6B v3, ggf. Canary 1B v2 | WER, Latenz bis final, Halluzinationen, Streaming-Verhalten |
| nemo-speech.cpp | Nemotron 3 Diarization (WP12) | Diarization Error Rate an der Zwei-Sprecher-Aufnahme, Latenz offline und streaming |

Jede Zeile einmal mit `--realtime` (Latenzbild) und einmal so schnell wie möglich (Durchsatz). Ergebnis als Tabelle in `docs/ops/benchmarks.md`.

Prüfung: Tabelle vollständig, pro Backend ein bestes Modell benannt, Entscheidung in Issue #1 dokumentiert.

### WP10 — Zweites Backend im Adapter (Riva-gRPC-Streaming)

Nur wenn das Tor aus WP8 offen ist und WP9 einen Vorteil zeigt.

- `Transcriber`-Protokoll bleibt für Whisper. Neu: `StreamingTranscriber` mit Session-Lebenszyklus (`open`, `feed(samples)`, `results()`, `close`), umgesetzt als `RivaStreamingClient` über gRPC `StreamingRecognize` mit `interim_results=true`. Protobuf-Stubs aus den Riva-Protos (`riva_asr.proto`) generiert und eingecheckt.
- `SessionStore` bekommt einen Modus `streaming`: Segmente werden ohne Rollpuffer in den gRPC-Stream geschrieben; `is_final=false` wird zu `partial`, `is_final=true` zu `final`. Zeiten aus den Riva-Wortzeitstempeln auf die Sessionzeitachse abgebildet. Finalisierungsregeln, Überlaufschutz und Quiet-Cut entfallen in diesem Modus.
- Konfiguration `ASR_BACKEND=whisper|riva`, `RIVA_URL`, `RIVA_LANGUAGE`; Health-Endpunkt meldet Backend und Modell.
- Der Vertrag zur App (`docs/api/segment-contract.md`) bleibt unverändert. Die App merkt nur bessere Latenz und stabilere Finals.
- Tests mit einem Fake-gRPC-Server (interim/final-Folgen, Reconnect, Session-Timeout); Integrationstest wie bisher über `AdapterIntegrationTests`.

Prüfung: Replay der Messaufnahmen über `ASR_BACKEND=riva` erreicht die WER aus WP9; Gerätetest mit dem iPhone.

### WP11 — Betrieb festziehen

- systemd-Units bzw. `docker compose` für Backend und Adapter, Neustart bei Absturz, Logrotation, keine Inhalte im Log.
- `docs/ops/server-setup.md`: Installation beider Backends, Modellablage, Updates.
- Whisper bleibt als Fallback konfiguriert, Umschalten per Umgebungsvariable.

### WP12 — Sprechertrennung mit Nemotron 3 Diarization (optional, nach WP9)

Nemotron 3 Diarization ist ein offenes Streaming-Sortformer-Modell mit rund 100 M Parametern für bis zu 8 Sprechende, Labels in Reihenfolge des ersten Auftretens, offline oder in Echtzeit mit Pufferlatenz ab 80 ms. nemo-speech.cpp führt es in derselben Laufzeit wie die ASR-Modelle aus (GGUF-Architektur `sortformer`). Das Konzept in Issue #1 nennt Sprechertrennung als Nicht-Ziel der ersten Version; sie kommt deshalb erst nach der Backend-Entscheidung und zunächst als Nachbearbeitung.

- **Stufe 1, offline nach `finish`:** Der Adapter lässt die gespeicherte Sitzung (Audio bleibt dafür bis zum Abschluss im Speicher, danach gelöscht) durch das Diarization-Modell laufen und ordnet jedem finalen Abschnitt über die Wortzeitstempel den Sprecher mit dem größten Zeitanteil zu. Ergebnis: Mitschrift mit Sprecherwechseln („Sprecher 1:“, „Sprecher 2:“).
- **Stufe 2, live:** Die Streaming-Variante liefert Sprecherlabels pro Frame mit niedriger Latenz; sie läuft parallel zum ASR-Stream, Labels werden an `partial` und `final` gehängt. Sinnvoll erst, wenn WP10 (Riva-Streaming) steht.
- **Vertrag:** Segmente bekommen ein optionales Feld `speaker` (String, z. B. `"1"`); Antworten ohne dieses Feld bleiben gültig. Ältere App-Versionen ignorieren es.
- **App:** Anzeige der Sprecherwechsel in Live- und Ergebnisansicht, optional Umbenennung der Sprecher vor dem Export.
- **Messung:** Diarization Error Rate (DER) an der Zwei-Sprecher-Aufnahme aus WP9 mit manuell gesetzten Sprecherwechseln; Prüfen, wie oft bei Zwischenrufen und Überlappung die Zuordnung springt.
- **Grenzen:** Generische Labels, keine Namen; Erkennung derselben Stimme über mehrere Sitzungen hinweg ist nicht vorgesehen. Bei mehr als zwei Sprechenden mit ähnlichen Stimmen steigt die Fehlerrate deutlich.

Prüfung: Zwei-Sprecher-Aufnahme liefert eine Mitschrift mit korrekten Wechseln an mindestens 90 % der manuell markierten Stellen; Latenz der Nachbearbeitung unter 10 % der Aufnahmedauer.

## Risiken

- **Deutsch im Container:** Version 0.1.0 listet nur englische ASR-Modelle. Ohne deutschfähiges GGUF bleibt parakeet.cpp als Weg, mit eigener Serverschicht statt Riva-gRPC. Deshalb ist das Tor in WP8 vorgeschaltet.
- **Nur CUDA:** nemo-speech.cpp braucht eine NVIDIA-GPU auf dem Server; der Mac fällt für dieses Backend aus.
- **Zeitstempel-Abbildung:** Riva liefert Wortzeiten relativ zum Stream; die App erwartet Sekunden ab Sessionbeginn. Bei Reconnects muss der Offset mitgeführt werden.
- **Zwei Protokolle im Adapter** erhöhen die Testlast. Der Whisper-Pfad wird nicht umgebaut, nur gekapselt.
- **VRAM:** `large-v3` f16 braucht rund 3 GB, Parakeet 0.6B etwa 1,5 GB; mehrere Sessions parallel vervielfachen das bei Whisper nicht (ein Modell, sequenzielle Anfragen), bei Streaming-Sessions je nach Implementierung schon.

## Offene Fragen an dich

1. Hardware des neuen Servers: GPU-Modell und VRAM, CPU, RAM, Betriebssystem.
2. Darf Docker laufen (für den nemo-speech.cpp-Container)?
3. SSH-Zugang für mich über das Tailnet, oder Ausführung der Schritte durch dich nach Anleitung?
4. Eine neue deutsche Testaufnahme von 3 bis 5 Minuten mit Pausen, aufgenommen mit der App, Sprache „Deutsch“.

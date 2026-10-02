# Umsetzungsplan: iOS-Live-Transkription über privaten Tailscale-ASR-Server

Stand: 2026-10-02. Bezieht sich auf Issue #1 und `ios-tailnet-live-transcription.md`. Dieses Dokument übersetzt die Meilensteine A–E aus dem Konzept in konkrete, überprüfbare Arbeitspakete für dieses Repository.

## 1. Ausgangslage im Repo

- Die macOS-App ist eine einzelne Datei (`Sources/MitschriftApp.swift`, 459 Zeilen) ohne Xcode-Projekt und ohne SwiftPM. Sie wird mit `swiftc` über `Scripts/build-app.sh` gebaut.
- Plattformneutral sind bereits: `WorkState`, Zeitformatierung, Dateibenennung, Sprach-/Modellwahl, Transkript-Modell, `recordingsDirectory()`.
- Plattformspezifisch (AppKit/`Process`): `NSOpenPanel`, `NSSavePanel`, `NSPasteboard`, `NSWorkspace`, `runProcess` für `whisper-cli`/`ffmpeg`, `AVCaptureDevice`-Berechtigungsabfrage.
- Auf dem Entwicklungs-Mac fehlt Xcode (nur Command Line Tools). Ohne Xcode gibt es weder iOS-SDK noch Simulator noch Geräte-Signing. Das ist die erste Hürde.
- `whisper-server` aus Homebrew `whisper.cpp` 1.9.4 ist vorhanden. Er hält das Modell im Speicher, bietet `POST /inference` (Multipart-WAV, JSON-Antwort mit Segmenten) und unterstützt serverseitige VAD. Er hat keine Sitzungen, keine Sequenznummern und keine Authentifizierung; das übernimmt ein Adapter.
- Tailscale ist auf dem Mac installiert und aktiv. Im Tailnet existiert ein Linux-Rechner als Kandidat für den ASR-Server.

## 2. Zielstruktur des Repos

```text
Mitschrift/
├── Package.swift                 # SwiftPM: MitschriftCore + Tests (läuft mit CLT)
├── Sources/
│   ├── MitschriftCore/           # plattformneutral, keine AppKit/UIKit-Imports
│   │   ├── Model/                # Transcript, Segment, SegmentState, Session
│   │   ├── Recording/            # RecordingState, Timer, Dateibenennung
│   │   ├── Live/                 # SegmentQueue, LiveTranscriptionClient, Reconcile
│   │   └── Config/               # ServerEndpoint, Keychain-Protokoll
│   ├── MitschriftMac/            # bisherige App, auf Core umgestellt
│   └── MitschriftIOS/            # neue iOS-App
├── Tests/MitschriftCoreTests/
├── Server/asr-adapter/           # Python-Adapter vor whisper-server
├── ios/project.yml               # XcodeGen-Definition, .xcodeproj bleibt gitignoriert
├── Scripts/                      # bestehende Build-Skripte + build-ios.sh
└── docs/
    ├── planning/
    ├── api/segment-contract.md   # verbindlicher HTTP-Vertrag
    └── ops/                      # Server-, Tailscale-, iPhone-Anleitung
```

Begründungen:

- **SwiftPM für den Kern:** `swift build` und `swift test` laufen ohne Xcode, also auch in der jetzigen CLT-Umgebung und in CI. Der macOS-Build kompiliert die Core-Quellen weiterhin direkt mit `swiftc`; damit bleibt der bestehende Build-Weg erhalten.
- **XcodeGen statt eingechecktem `.xcodeproj`:** Die Projektdefinition liegt als `project.yml` im Git, das generierte Projekt nicht. Das vermeidet Merge-Konflikte und hält das Repo frei von Xcode-Rauschen.
- **Python-Adapter:** klein, schnell änderbar, FastAPI/uvicorn mit `uv`. Er spricht `whisper-server` über `localhost` an. Ein Swift-Server wäre möglich, bringt aber auf dem Linux-Zielrechner Mehraufwand.

## 3. Entwurfsentscheidung Segmentierung

Das Konzept sieht 2–3-s-Segmente mit 250–500 ms Überlappung und den Zuständen `partial`/`final` vor. Whisper liefert auf isolierten 2–3-s-Schnipseln schlechte Ergebnisse und kann daraus keine sinnvollen `partial`/`final`-Zustände ableiten. Vorschlag, der den Vertrag unverändert lässt:

- Der Client sendet weiterhin kurze Segmente mit `sequence`.
- Der Adapter hält pro Session einen Rollpuffer (z. B. die letzten 10–12 s PCM) und transkribiert bei jedem eingehenden Segment das gesamte Fenster.
- Segmente, deren Endzeit vor `Fensterende − Sicherheitsabstand` liegt (Startwert 3 s), werden als `final` markiert und ihr Audio aus dem Puffer entfernt. Der Rest ist `partial` und darf mit der nächsten Antwort überschrieben werden.
- Die Antwort enthält immer die vollständige aktuelle `partial`-Region plus neu finalisierte Segmente; die App ersetzt ihre Partial-Region komplett und hängt Finals an. So werden finalisierte Abschnitte nie umgeschrieben.
- Idempotenz: Der Adapter speichert pro Session die letzte Antwort je `sequence`; ein Duplikat liefert dieselbe Antwort ohne erneute Inferenz.

Dieser Ansatz entspricht dem Verfahren von `whisper-stream` und liefert echte Latenz-/Qualitätsmessungen, bevor über WebSockets entschieden wird.

## 4. Arbeitspakete

Jedes Paket ist ein eigener Branch von `dev` mit PR nach `dev`. Reihenfolge ist Abhängigkeitsreihenfolge; 0, 1 und 3 können parallel beginnen.

### WP0 — Entwicklungsumgebung (Voraussetzung, nicht im Repo)

- Xcode aus dem App Store installieren, `sudo xcode-select -s /Applications/Xcode.app`, iOS-Simulator-Runtime laden. Vorher Festplattenplatz schaffen: aktuell sind rund 15 GB frei, Xcode mit Simulator benötigt etwa 30–40 GB.
- `brew install xcodegen`.
- Apple-ID in Xcode hinterlegen. Kostenlose persönliche Signatur reicht für Entwicklung auf dem eigenen iPhone (Profil 7 Tage gültig, Hintergrund-Audio funktioniert). TestFlight setzt ein bezahltes Developer-Konto voraus.
- Prüfung: `xcodebuild -version` zeigt eine Xcode-Version; `xcrun simctl list runtimes` zeigt iOS.

### WP1 — Vertrag und Dokumentation (Meilenstein A)

Deliverables:

- `docs/api/segment-contract.md`: Endpunkte `POST /v1/live-transcriptions/segments`, `POST /v1/live-transcriptions/{sessionId}/finish`, `GET /v1/health`. Request-Header, Audioformat (WAV, PCM 16 bit, 16 kHz, mono), JSON-Antwort, Fehlercodes (400 ungültiges Audio, 401 Token, 409 Session beendet, 413 zu groß, 429 Überlast, 503 Modell lädt), Idempotenzregel, Größen- und Zeitlimits.
- `docs/ops/tailscale.md`: ACL-Beispiel mit Tag `tag:asr` und nur dem Dienstport, `tailscale serve` für HTTPS, ausdrücklich kein Funnel. Keine echten Hostnamen.
- Entscheidung zu den offenen Punkten 1–5 (siehe Abschnitt 6) im Issue festhalten.

Prüfung: Review des Vertrags gegen das Konzept; keine privaten Namen im Diff.

### WP2 — ASR-Adapter (Meilenstein C, Serverseite)

Deliverables in `Server/asr-adapter/`:

- `pyproject.toml` (FastAPI, uvicorn, httpx, numpy), Start über `uv run`.
- `app.py`: Session-Verwaltung im Speicher, Rollpuffer, Weiterleitung an `whisper-server`, Finalisierungslogik aus Abschnitt 3, Dedup je `sequence`, Bearer-Token aus Umgebungsvariable, Limits (max. Segmentgröße 1 MB, max. 4 parallele Sessions, Session-Timeout 60 s ohne Daten).
- `GET /v1/health`: Modellname, Ladezustand, aktive Sessions, Version. Keine Inhalte.
- Logging nur Betriebsdaten; temporäre Dateien werden nach jeder Anfrage gelöscht.
- `run.sh` startet `whisper-server --host 127.0.0.1 --port 8080 -m <modell> -l de --vad ...` und den Adapter auf dem Tailscale-Interface.
- `tests/`: pytest mit vorbereiteten deutschen WAV-Dateien aus `Models`-unabhängigen Fixtures; Test für Reihenfolge, Duplikate, Finalisierung, Token-Pflicht.
- `Scripts/bench-asr.sh`: misst Echtzeitfaktor und Latenz pro Modell auf der Zielhardware und schreibt ein Protokoll nach `docs/ops/benchmarks.md`.

Prüfung: Adapter lokal auf dem Mac mit `ggml-small.bin` gegen Test-WAVs; `curl` aus einem zweiten Tailnet-Gerät; Zugriff ohne Token wird mit 401 abgelehnt.

### WP3 — MitschriftCore extrahieren (Meilenstein B, Teil 1)

Deliverables:

- `Package.swift` mit Library `MitschriftCore` (Plattformen macOS 14, iOS 17) und Testtarget.
- Verschieben der plattformneutralen Typen aus `MitschriftApp.swift`. Neue Protokolle:
  - `AudioCapturing` (start/stop, liefert PCM-Puffer oder Datei-URL)
  - `TranscriptionEngine` (`transcribe(fileURL:)` für lokal, `LiveTranscriptionSession` für remote)
  - `TranscriptExporting` (kopieren/speichern)
  - `EndpointStore` (URL und Token; macOS: UserDefaults + Keychain, iOS: Keychain)
- Modell `Transcript` mit `finalSegments: [Segment]` und `partialSegments: [Segment]`; `Segment` mit `start`, `end`, `text`, `state`.
- `SegmentQueue`: begrenzte, geordnete Warteschlange (z. B. max. 60 Segmente ≈ 3 min) mit Zuständen `pending`, `inFlight`, `acknowledged`, `failed`; Wiederholung mit Backoff; sichtbarer Zustand `paused` bei vollem Puffer.
- `LiveTranscriptionClient` auf `URLSession`-Basis, der den Vertrag aus WP1 implementiert und Antworten in `Transcript` einarbeitet.
- Unit-Tests: Warteschlange (Reihenfolge, Überlauf, Retry), Reconcile-Logik (Finals werden nie überschrieben), Dateibenennung, Antwort-Decoding gegen Beispiel-JSON aus dem Vertrag.
- `Scripts/build-app.sh` kompiliert `Sources/MitschriftCore/**/*.swift` zusammen mit `Sources/MitschriftMac/*.swift`.
- CI: `swift build` und `swift test` ergänzen; bestehender Typecheck bleibt.

Prüfung: `swift test` grün; `make build` baut die unveränderte macOS-App; manueller Regressionstest Aufnahme + M4A-Import mit `base` und `small`.

### WP4 — iOS-Grundgerüst (Meilenstein B, Teil 2)

Deliverables:

- `ios/project.yml` (XcodeGen): Target `Mitschrift-iOS`, lokale Package-Abhängigkeit auf `MitschriftCore`, `UIBackgroundModes: audio`, `NSMicrophoneUsageDescription`, Bundle-ID `io.github.zulutwothree.mitschrift.ios`.
- `Scripts/build-ios.sh`: `xcodegen generate` und `xcodebuild` für Simulator.
- Einstellungsansicht: Server-URL, optionaler Token (Keychain), Sprache. Verbindungstest ruft `/v1/health` und zeigt Modell und Version an. Erkennung „kein Tailnet“: Host ist nur im Tailnet auflösbar; Timeout wird als „Tailnet nicht verbunden?“ erklärt.
- Datenschutzhinweis vor der ersten Aufnahme (Audio geht nur an den eigenen Server im Tailnet).
- `AVAudioSession` (`.record`, `.measurement`) und `AVAudioEngine`-Tap mit Konvertierung auf 16 kHz mono Int16; noch ohne Upload, Audio landet in einer lokalen Datei.
- Mikrofonberechtigung mit klarem Ablehnungszustand und Link in die Einstellungen.

Prüfung: Build im Simulator; auf realem iPhone Aufnahme in Datei, Hintergrundfortsetzung bei gesperrtem Bildschirm.

### WP5 — Live-Transkription Ende-zu-Ende (Meilenstein C, Clientseite)

Deliverables:

- `SegmentBuilder`: schneidet den Engine-Tap in Segmente von 2,5 s mit 300 ms Überlappung, schreibt WAV-Header, übergibt an `SegmentQueue`.
- Verdrahtung `SegmentQueue` → `LiveTranscriptionClient` → `Transcript` → Live-Ansicht.
- Live-Ansicht: Dauer, Serverstatus (verbunden / wartet / pausiert), Final-Text normal, Partial-Text abgesetzt (z. B. grau/kursiv), Warteschlangenanzeige.
- Stop-Ablauf: Warteschlange leeren, `/finish` aufrufen, letzte Finals übernehmen, Transkript und Audio unter `Documents/Mitschrift` speichern, Share-Sheet-Export.
- Fehlerzustände als nicht-technische Meldungen: Server nicht erreichbar, Token abgelehnt, Überlast, Warteschlange voll.

Prüfung: Testprotokoll mit deutschem Beispielgespräch (Latenz, Echtzeitfaktor); Netzwerkabbruch per Flugmodus für 20 s, danach müssen alle Segmente ankommen; Server-Neustart während der Aufnahme.

### WP6 — Robustheit und Produktreife (Meilenstein D)

- Unterbrechungen (`AVAudioSession.interruptionNotification`, Anrufe, Siri): Pause mit Hinweis, automatische Fortsetzung.
- Routenwechsel (Kopfhörer), Speicherbegrenzung für temporäre Segmentdateien, Löschen bestätigter Segmente.
- Leichte clientseitige Stille-Erkennung (RMS-Schwelle) als optionale Einsparung; Standard aus.
- Langzeittest 60 min: Speicherverbrauch App und Adapter, Warteschlange bleibt begrenzt.
- Mobilfunktest mit aktivem Tailnet.

### WP7 — Absicherung und Betrieb (Meilenstein E)

- Sicherheitscheck: Dienst nur an Tailscale-Interface gebunden, ACL getestet von einem nicht autorisierten Gerät und aus dem öffentlichen Netz, kein Funnel, Logrotation.
- `docs/ops/server-setup.md` (Linux und Mac), `docs/ops/iphone-setup.md`, README-Abschnitt iOS.
- Optional WP7b: LLM-Nachbearbeitung als separater, abschaltbarer Schritt im Adapter (`POST /v1/postprocess`), der nur Text erhält. Erst nach Abnahme von WP5.

### Später: WebSocket-Kanal (Stufe 2)

Nur wenn die gemessene Latenz aus WP5 unzureichend ist. Gleicher Session-/Sequenzvertrag, gleiche Finalisierungslogik.

## 5. Reihenfolge und Abhängigkeiten

```text
WP0 (Xcode) ─────────────┐
WP1 (Vertrag) ──┬── WP2 (Adapter) ──┐
                └── WP3 (Core) ──── WP4 (iOS) ── WP5 (Live) ── WP6 ── WP7
```

Empfohlener Einstieg: WP1 und WP3 sofort, weil beide ohne Xcode machbar sind und WP3 die macOS-App bereits testbar macht. WP2 direkt danach auf dem Mac entwickeln, Zielrechner später. WP0 parallel vorbereiten (Festplattenplatz, Download).

## 6. Empfehlungen zu den offenen Entscheidungen

1. **Hardware:** Entwicklung und erste Messungen auf dem vorhandenen Mac (Apple M3, 8 GB). Für Dauerbetrieb den Linux-Rechner im Tailnet prüfen; der Benchmark aus WP2 entscheidet. 8 GB RAM erlauben `small` und `medium` sicher; `large-v3-turbo` nur quantisiert (q5, ca. 600 MB) und nicht parallel zu Xcode.
2. **Modell:** Start mit `small` (bereits vorhanden, Prüfsumme bekannt). Danach `large-v3-turbo-q5_0` messen; dieses Modell ist für Deutsch deutlich besser und bei ähnlichem Tempo wie `medium`.
3. **Transport:** HTTPS-Segmentupload für den MVP, wie im Konzept. WebSocket erst nach Messung.
4. **Verteilung:** Persönliches Gerät mit kostenloser Signatur. TestFlight nur bei Bedarf für weitere Tester.
5. **Token:** Ja, zusätzlich zur Tailnet-Zugehörigkeit einen Bearer-Token verlangen. Kostet wenig, schützt gegen andere Geräte im selben Tailnet und gegen Fehlkonfiguration der ACL. Speicherung im iOS-Schlüsselbund, auf dem Server als Umgebungsvariable.

## 7. Risiken

- **Festplattenplatz für Xcode** ist aktuell nicht vorhanden. Ohne WP0 bleibt alles ab WP4 blockiert.
- **8 GB RAM** reichen nicht für Xcode, Simulator und whisper-server mit großem Modell gleichzeitig. Für Gerätetests den Adapter auf dem Linux-Rechner betreiben oder `small` verwenden.
- **Rollpuffer-Ansatz** vervielfacht die Inferenzlast (jedes Fenster wird mehrfach transkribiert). Auf CPU-only-Hardware kann das den Echtzeitfaktor über 1 treiben; der Benchmark in WP2 muss das früh zeigen.
- **Deutsche Qualität von `small`** ist für Fachbegriffe begrenzt. Das Akzeptanzkriterium „fortlaufend Text“ ist damit erfüllbar, „brauchbare Mitschrift“ eventuell erst mit `large-v3-turbo`.
- **Hintergrundaufnahme** auf iOS endet, wenn die App beendet wird oder das System sie wegen Speicher beendet. Audio muss segmentweise auf Platte liegen, damit nichts verloren geht.

## 8. Definition of Done je Paket

Ein Paket gilt als fertig, wenn der PR nach `dev` gemerged ist, CI grün ist, die im Paket genannte Prüfung dokumentiert durchgeführt wurde und keine Zugangsdaten, Tailnet-Namen oder privaten URLs im Diff stehen.

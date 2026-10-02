# Mitschrift

Native macOS-App (SwiftUI/AppKit) zum lokalen Aufnehmen und Transkribieren mit whisper.cpp, plus ein plattformneutraler Kern `MitschriftCore` (SwiftPM) für die geplante iOS-Live-Transkription über einen privaten ASR-Server (Issue #1, `docs/planning/`). Die macOS-App wird direkt mit `swiftc` über `Scripts/build-app.sh` gebaut; der Kern wird dabei mitkompiliert.

## Befehle

- `make models` – Whisper-Modelle (`base`, `small`) nach `Models/` laden, mit SHA-1-Prüfung
- `make build` – App nach `dist/Mitschrift.app` bauen (Icon, Binary, Modelle, Ad-hoc-Signatur)
- `make run` – bauen und starten
- `make test` – Core-Tests (`Scripts/test-core.sh`; setzt mit reinen Command Line Tools die Suchpfade für swift-testing)
- `swift build` – nur den Kern bauen
- Typecheck wie in CI (`.github/workflows/verify.yml`): `swiftc -typecheck` über `Sources/MitschriftCore/**/*.swift` und `Sources/MitschriftMac/*.swift` mit `-module-name Mitschrift`

## Voraussetzungen

macOS 14+, Xcode Command Line Tools, Homebrew mit `whisper.cpp` und `ffmpeg` (`brew install whisper-cpp ffmpeg`). Die App ruft `whisper-cli` und `ffmpeg` zur Laufzeit aus der Homebrew-Installation auf.

## Struktur

- `Package.swift` – SwiftPM mit Library `MitschriftCore` und Tests; macOS 14 / iOS 17
- `Sources/MitschriftCore/` – plattformneutral, nur Foundation/Combine: `Model` (Segment, Transcript, API-Modelle), `Live` (SegmentQueue, LiveTranscriptionSession, URLSession-Transport, WAVEncoder), `Recording` (Zustand, Dateinamen), `Config` (ServerEndpoint)
- `Sources/MitschriftMac/` – macOS-App: `MitschriftApp.swift` (UI, Aufnahme) und `LocalWhisperEngine.swift` (`whisper-cli`/`ffmpeg` per `Process`)
- `Tests/MitschriftCoreTests/` – swift-testing; `FakeTransport` in `Support/`
- `Tools/IconMaker.swift`, `Tools/ICNSMaker.swift` – Build-Helfer für das App-Icon
- `Server/asr-adapter/` – Python-Adapter (FastAPI) vor `whisper-server`, eigener README
- `docs/api/segment-contract.md` – verbindlicher HTTP-Vertrag zwischen App und Adapter
- `Resources/Info.plist` – Bundle-Metadaten und Mikrofon-Berechtigung
- `Scripts/` – Build- und Download-Skripte (zsh)
- `.build/` (Zwischenartefakte), `dist/` (fertige App), `Models/*.bin` sind gitignoriert

## Hinweise

- Bei Fehlern wie „PCH was compiled with module cache path …“ nach einem Verschieben des Repos: `rm -rf .build` und neu bauen.
- Core-Typen sind `public`, weil sie als Package gebaut werden; im macOS-Build landen sie im selben Modul.
- Keine Tailnet-Hostnamen, IP-Adressen oder Tokens ins Repo schreiben (Vorgabe aus Issue #1).

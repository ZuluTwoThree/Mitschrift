# Mitschrift

Native macOS-App (SwiftUI/AppKit) zum lokalen Aufnehmen und Transkribieren mit whisper.cpp. Kein Xcode-Projekt und kein SwiftPM: die App wird direkt mit `swiftc` über `Scripts/build-app.sh` gebaut.

## Befehle

- `make models` – Whisper-Modelle (`base`, `small`) nach `Models/` laden, mit SHA-1-Prüfung
- `make build` – App nach `dist/Mitschrift.app` bauen (Icon, Binary, Modelle, Ad-hoc-Signatur)
- `make run` – bauen und starten
- Typecheck wie in CI (`.github/workflows/verify.yml`):
  `swiftc -typecheck -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -framework UniformTypeIdentifiers Sources/MitschriftApp.swift`

## Voraussetzungen

macOS 14+, Xcode Command Line Tools, Homebrew mit `whisper.cpp` und `ffmpeg` (`brew install whisper-cpp ffmpeg`). Die App ruft `whisper-cli` und `ffmpeg` zur Laufzeit aus der Homebrew-Installation auf.

## Struktur

- `Sources/MitschriftApp.swift` – die gesamte App in einer Datei
- `Sources/IconMaker.swift`, `Sources/ICNSMaker.swift` – Build-Helfer für das App-Icon
- `Resources/Info.plist` – Bundle-Metadaten und Mikrofon-Berechtigung
- `Scripts/` – Build- und Download-Skripte (zsh)
- `.build/` (Zwischenartefakte), `dist/` (fertige App), `Models/*.bin` sind gitignoriert

## Hinweise

- Bei Fehlern wie „PCH was compiled with module cache path …“ nach einem Verschieben des Repos: `rm -rf .build` und neu bauen.
- Es gibt keine Tests; der CI-Workflow führt nur den Typecheck aus.

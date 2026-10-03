# Mitschrift

Eine native macOS-App zum lokalen Aufnehmen und Transkribieren von Gesprächen mit [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Audio und Mitschriften bleiben auf dem Mac; kein Cloud-Konto und keine laufenden API-Kosten sind erforderlich.

## Funktionen

- Aufnahme über das MacBook-Mikrofon
- Lokale Transkription auf Deutsch, Englisch oder per automatischer Spracherkennung
- Wahl zwischen `small` (Standard, höhere Genauigkeit) und `base` (schneller)
- Import von Audiodateien, einschließlich `.m4a` aus Sprachmemos
- Kopieren oder Speichern der Mitschrift
- Automatische Ablage unter `~/Documents/Mitschrift`

## Voraussetzungen

- macOS 14 oder neuer
- Xcode Command Line Tools
- Homebrew
- `whisper.cpp` und `ffmpeg`

```sh
brew install whisper-cpp ffmpeg
```

## Build

```sh
git clone git@github.com:ZuluTwoThree/Mitschrift.git
cd Mitschrift
zsh Scripts/download-models.sh
zsh Scripts/build-app.sh
open dist/Mitschrift.app
```

Beim ersten Start verlangt macOS die Berechtigung zum Zugriff auf das Mikrofon. Die Modelle werden bewusst nicht versioniert: Sie sind groß und können jederzeit mit dem Download-Skript inklusive SHA-1-Prüfung neu beschafft werden.

## Architektur

Die App ist eine reine SwiftUI-/AppKit-Anwendung. Sie zeichnet 16-kHz-Mono-WAV auf und ruft die lokal installierte `whisper-cli` auf. Für nicht direkt unterstützte Formate wie M4A wandelt sie die Datei temporär mit `ffmpeg` in WAV um; das Original bleibt unverändert.

## Entwicklung

Temporäre Build-Artefakte liegen in `.build/`, die fertige App in `dist/`. Beide sowie die Modelle in `Models/` sind von Git ausgeschlossen.

Der plattformneutrale Kern liegt als SwiftPM-Package `MitschriftCore` unter `Sources/MitschriftCore` und wird mit `make test` getestet. Die geplante iOS-Variante mit Live-Transkription über einen privaten Server im Tailnet ist in `docs/planning/` beschrieben.

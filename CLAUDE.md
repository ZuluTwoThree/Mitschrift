# Mitschrift

Native macOS-App (SwiftUI/AppKit) zum lokalen Aufnehmen und Transkribieren mit whisper.cpp, plus ein plattformneutraler Kern `MitschriftCore` (SwiftPM) für die geplante iOS-Live-Transkription über einen privaten ASR-Server (Issue #1, `docs/planning/`). Die macOS-App wird direkt mit `swiftc` über `Scripts/build-app.sh` gebaut; der Kern wird dabei mitkompiliert.

## Befehle

- `make models` – Whisper-Modelle (`base`, `small`) nach `Models/` laden, mit SHA-1-Prüfung
- `make build` – App nach `dist/Mitschrift.app` bauen (Icon, Binary, Modelle, Ad-hoc-Signatur)
- `make run` – bauen und starten
- `make test` – Core-Tests (`Scripts/test-core.sh`; setzt mit reinen Command Line Tools die Suchpfade für swift-testing)
- `swift build` – nur den Kern bauen
- Integrationstest gegen einen laufenden Adapter (sonst übersprungen): `MITSCHRIFT_ADAPTER_URL=http://127.0.0.1:8765 MITSCHRIFT_ADAPTER_TOKEN=<token> MITSCHRIFT_TEST_WAV=<16-kHz-WAV> swift test --filter AdapterIntegrationTests`; Testclip z. B. mit `say -v Anna -o clip.aiff "…"` und `ffmpeg -i clip.aiff -ar 16000 -ac 1 -c:a pcm_s16le clip.wav`
- Simulator mit lokalem Adapter (nur Debug-Build): `SIMCTL_CHILD_MITSCHRIFT_DEV_ENDPOINT=http://127.0.0.1:8765 SIMCTL_CHILD_MITSCHRIFT_DEV_TOKEN=<token> xcrun simctl launch <udid> io.github.zulutwothree.mitschrift.ios`; `http` ist nur für Loopback-Adressen erlaubt
- `zsh Scripts/build-ios.sh` – iOS-App für den Simulator bauen (XcodeGen + xcodebuild); `… device` für das Gerät, braucht `ios/Local.xcconfig` mit `DEVELOPMENT_TEAM` (Vorlage: `ios/Local.xcconfig.example`)
- Typecheck wie in CI (`.github/workflows/verify.yml`): `swiftc -typecheck` über `Sources/MitschriftCore/**/*.swift` und `Sources/MitschriftMac/*.swift` mit `-module-name Mitschrift`

## Voraussetzungen

macOS 14+, Homebrew mit `whisper.cpp` und `ffmpeg` (`brew install whisper-cpp ffmpeg`). Die macOS-App ruft `whisper-cli` und `ffmpeg` zur Laufzeit aus der Homebrew-Installation auf. Für die macOS-App und die Core-Tests reichen die Command Line Tools; die iOS-App braucht Xcode und `xcodegen` (`brew install xcodegen`).

## Struktur

- `Package.swift` – SwiftPM mit Library `MitschriftCore` und Tests; macOS 14 / iOS 17
- `Sources/MitschriftCore/` – plattformneutral, nur Foundation/Combine: `Model` (Segment, Transcript, API-Modelle), `Live` (SegmentQueue, LiveTranscriptionSession, URLSession-Transport, WAVEncoder), `Recording` (Zustand, Dateinamen), `Config` (ServerEndpoint; `ServerProfile` + `ServerProfileStore` für mehrere gespeicherte Server, Profile als JSON in UserDefaults, Token je Profil über `TokenStore` im Schlüsselbund, Migration der alten Einzelkonfiguration aus `KeychainEndpointStore`)
- `Sources/MitschriftIOS/` – iOS-App: `MitschriftIOSApp` (Tabs Aufnahme/Server), `Audio/AudioCaptureEngine` (AVAudioEngine → 16 kHz mono Int16, Unterbrechungen), `Recording/RecordingController` (Berechtigung, WAV-Datei, Segmente), `Settings/` (Serverprofile mit Menüauswahl, Keychain, Verbindungstest), `Views/`
- `ios/project.yml` – XcodeGen-Definition; `ios/Mitschrift.xcodeproj`, `ios/Info.plist` und `ios/Local.xcconfig` werden erzeugt und sind gitignoriert
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
- Core-Typen sind `public`, weil sie als Package gebaut werden; im macOS-Build landen sie im selben Modul, die iOS-App bindet das Package über XcodeGen ein.
- iOS-Target baut mit `SWIFT_STRICT_CONCURRENCY=complete`; Audio-Callbacks laufen auf einer eigenen Queue, UI-Zustand nur auf dem Main-Actor.
- Simulator-Builds müssen ad hoc signiert sein (kein `CODE_SIGNING_ALLOWED=NO`), sonst schlägt der Schlüsselbund mit `errSecMissingEntitlement` fehl.
- Keine Tailnet-Hostnamen, IP-Adressen oder Tokens ins Repo schreiben (Vorgabe aus Issue #1).

# Mitschrift iOS: Deine Aufgaben

Stand: 2026-10-03. Gegenstück zu `umsetzungsplan.md`: was nur du tun kannst, nach Dringlichkeit geordnet. Die Pakete WP1 bis WP3 sind umgesetzt (PRs #2, #3, #4 nach `dev`). Ab WP4 (iOS-App) hängt alles an Xcode und deinem iPhone.

## Checkliste

- [x] Mindestens 40 GB auf dem Mac frei (Stand 2026-10-03: 91 GB)
- [x] macOS aktualisiert (aktuelles Xcode verlangt eine neuere macOS-Version als 15.7)
- [x] Xcode installiert, Lizenz angenommen, iOS-Plattform geladen
- [x] `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` ausgeführt
- [x] `brew install xcodegen` ausgeführt (2.46.0)
- [x] Apple-ID in Xcode hinterlegt (Personal Team)
- [x] iPhone: Entwicklermodus an, Mac vertraut (iPhone 11 Pro Max, iOS 26.6.2)
- [x] Tailscale auf dem iPhone installiert und angemeldet
- [ ] Entscheidungen in Abschnitt 3 bestätigt oder geändert
- [ ] Hardware-Ausgabe des Linux-Rechners geschickt
- [ ] SSH-Zugang für Claude entschieden
- [ ] Tailscale-ACL eingetragen
- [x] `tailscale serve` auf dem Server aktiviert (Mac, für den ersten Gerätetest)
- [ ] Token erzeugt und sicher abgelegt

## 1. Sofort: macOS und Xcode

Xcode braucht etwa 12 GB Download, rund 25 GB nach dem Entpacken und weitere 8 GB für die iOS-Simulator-Runtime. Das aktuelle Xcode setzt eine neuere macOS-Version voraus, deshalb zuerst macOS aktualisieren.

0. macOS über Systemeinstellungen → Allgemein → Softwareupdate aktualisieren. Nach dem Neustart prüfen, ob Homebrew-Werkzeuge noch laufen: `whisper-cli --help` und `ffmpeg -version`. Falls nicht: `brew reinstall whisper-cpp ffmpeg`.
1. Xcode aus dem Mac App Store laden (kostenlos, Apple-ID nötig). Alternativ von developer.apple.com als `.xip`, das ist oft schneller.
2. Xcode einmal starten, die Lizenz annehmen und bei der Komponentenauswahl die iOS-Plattform mitinstallieren. Falls später nötig: Xcode → Settings → Components → iOS.
3. Im Terminal die aktive Entwicklerumgebung umstellen:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
xcrun simctl list runtimes | grep iOS
```

4. XcodeGen installieren: `brew install xcodegen`.

Fertig ist der Schritt, wenn `xcodebuild -version` eine Versionsnummer zeigt und eine iOS-Runtime gelistet wird. Der bestehende macOS-Build mit `make build` funktioniert danach weiterhin.

## 2. Signing: Apple-ID in Xcode und iPhone vorbereiten

Für Tests auf deinem eigenen iPhone reicht die kostenlose persönliche Signatur. Du brauchst kein bezahltes Developer-Programm, solange niemand anderes die App bekommt.

1. Xcode → Settings → Accounts → „+“ → Apple-ID anmelden. Es erscheint ein „Personal Team“.
2. iPhone per Kabel an den Mac anschließen, auf dem iPhone „Diesem Computer vertrauen“ bestätigen.
3. Nach der ersten Installation durch Xcode auf dem iPhone den Entwicklermodus einschalten: Einstellungen → Datenschutz & Sicherheit → Entwicklermodus. Das iPhone startet neu.
4. Beim ersten Start der App: Einstellungen → Allgemein → VPN & Geräteverwaltung → deiner Apple-ID vertrauen.
5. Tailscale auf dem iPhone installieren und mit demselben Konto anmelden wie auf dem Mac.

Grenzen der kostenlosen Signatur: Das Profil läuft nach 7 Tagen ab, dann muss die App neu installiert werden. Maximal 3 Apps gleichzeitig und 10 App-IDs pro Woche. TestFlight für weitere Tester setzt das Developer-Programm für 99 € pro Jahr voraus, das ist für den MVP nicht nötig.

Sag Bescheid, wenn Xcode und Apple-ID stehen. Dann kann die App per `xcodebuild` und `devicectl` auf das angeschlossene iPhone installiert werden.

## 3. Entscheidungen bestätigen

Die Umsetzung läuft mit den Empfehlungen in der mittleren Spalte. Wenn du anders entscheidest, Vertrag und Code werden angepasst.

| Frage | Empfehlung, mit der gestartet wurde | Was sich ändert, wenn du anders entscheidest |
| --- | --- | --- |
| ASR-Hardware | Entwicklung auf deinem Mac (M3, 8 GB). Dauerbetrieb auf dem Linux-Rechner im Tailnet, sobald der Benchmark vorliegt. | Bei CPU-only-Linux ohne GPU bleibt nur `small`; dann sinkt die Qualität. |
| Modell | Start mit `small`. Danach `large-v3-turbo` quantisiert (q5, rund 600 MB) messen. | Größere Modelle brauchen mehr RAM; auf dem 8-GB-Mac nicht parallel zu Xcode. |
| Transport | HTTPS-Segmentupload für den MVP. WebSocket erst, wenn die gemessene Latenz nicht reicht. | WebSocket von Anfang an verdoppelt den Aufwand in Adapter und App. |
| Verteilung | Persönliches iPhone mit kostenloser Signatur. | TestFlight braucht das Developer-Programm (99 €/Jahr) und App-Review-Metadaten. |
| Token | Ja, zusätzlich zum Tailnet ein Bearer-Token im iOS-Schlüsselbund. | Ohne Token kann jedes Gerät im Tailnet Audio an den Server schicken. |

Offene Rückfrage: Wird der Linux-Rechner im Tailnet der Dauer-Server und der Mac dient nur zum Entwickeln, oder soll der Mac den Dienst dauerhaft betreiben?

## 4. Server und Tailscale

Der Adapter ist auf dem Mac entwickelt und getestet. Für den Betrieb auf dem Linux-Rechner und die Absicherung im Tailnet fehlt Folgendes.

1. **Hardware des Linux-Rechners nennen.** Dort ausführen und die Ausgabe schicken:

```sh
nproc; free -h; lspci | grep -iE 'vga|3d|nvidia'; nvidia-smi 2>/dev/null | head -15
```

2. **Zugang entscheiden.** Soll Claude per SSH über das Tailnet auf dem Linux-Rechner arbeiten dürfen? Falls ja: Nutzer und Host nennen und sicherstellen, dass ein SSH-Key vom Mac hinterlegt ist. Falls nein: Anleitung und Skripte werden geliefert, du führst sie aus.
3. **Tailscale-ACL in der Admin-Konsole anlegen** (login.tailscale.com → Access Controls). Die Policy-Vorlage liegt unter `docs/ops/tailscale.md`. Kern: ein Tag `tag:asr` für den Server, Zugriff nur von deinen Geräten auf den Dienstport, kein Funnel.
4. **Auf dem Server HTTPS per `tailscale serve` einschalten.** Das braucht einmalig Admin-Rechte und in der Admin-Konsole die Option „HTTPS Certificates“ unter DNS. Der Befehl steht in `docs/ops/tailscale.md`.
5. **Token erzeugen** und nirgends ins Repo schreiben:

```sh
openssl rand -hex 32
```

Der Wert wird auf dem Server als Umgebungsvariable `MITSCHRIFT_TOKEN` eingetragen, du tippst ihn einmal in die iOS-App. Danach liegt er nur im Schlüsselbund.

Bitte keine Tailnet-Hostnamen, IP-Adressen oder den Token in Issues, Commits oder Screenshots schreiben. Das ist eine Vorgabe aus dem Konzept.

## 5. Später: Tests am iPhone

Diese Punkte werden erst ab WP5 relevant. Bauen und installieren geht automatisiert, sprechen, Flugmodus schalten oder anrufen nicht. Pro Testlauf bitte eine kurze Notiz mit Datum, Modell, Netz (WLAN oder Mobilfunk) und Beobachtung; sie wandert ins Testprotokoll unter `docs/ops/`.

- Deutsches Beispielgespräch von 3 bis 5 Minuten mit Pausen, langen Sätzen und ein paar Fachbegriffen. Notieren, wie weit der Text hinter dem Gesprochenen liegt.
- Während einer Aufnahme 20 Sekunden Flugmodus einschalten, dann wieder aus. Prüfen, ob alle Segmente nachkommen.
- Bildschirm sperren und 2 Minuten weitersprechen. Prüfen, ob die Aufnahme weiterläuft.
- Einen Anruf annehmen und beenden. Prüfen, ob die App pausiert und danach weitermacht.
- Einmal über Mobilfunk statt WLAN, Tailscale aktiv.
- Eine Aufnahme von 60 Minuten, um Speicher und Warteschlange zu beobachten.
- Von einem Gerät ohne Tailscale versuchen, den Server zu erreichen. Erwartung: keine Verbindung.

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
- [x] Entscheidungen in Abschnitt 3: Server `kiworkstation` (RTX 3090), Docker erlaubt, SSH-Zugang; Modellentscheidung bewusst offen (Messungen in `docs/ops/benchmarks.md`)
- [x] Hardware der Server erfasst (kiworkstation: i9-11900K, 64 GB, RTX 3090 24 GB; bequietUbuntu: 9800X3D, 60 GB, RTX 5080 16 GB)
- [x] SSH-Zugang über das Tailnet eingerichtet
- [ ] Tailscale-ACL eingetragen (Vorlage in `docs/ops/tailscale.md`; derzeit greift nur der Token)
- [x] `tailscale serve` auf dem Server aktiviert (Mac für den ersten Test, jetzt kiworkstation auf 443 → Adapter)
- [x] Token erzeugt, liegt in der `.env` des Servers und im Schlüsselbund des iPhones

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

## Testprotokoll

| Datum | Gerät | Server | Modell | Netz | Aufnahme | Beobachtung |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-03 | iPhone 11 Pro Max, iOS 26.6.2 | Mac (M3), `tailscale serve` | `small` | WLAN, Tailnet | 27 s, Sprache „Deutsch“ auf englisches Audio | Verbindungstest ok, Segmente alle 200, Latenz 550–810 ms; Text unbrauchbar wegen Sprachwahl |
| 2026-10-03 | dito | dito | `small` | dito | 56 s, Sprache „Englisch“ | 26 Segmente, `finish` ok; erste ~5 s fehlten durch Pufferüberlauf (behoben in PR #8); Replay mit Fix fast deckungsgleich mit Offline-Referenz |
| 2026-10-03 | dito | dito | `small` | dito | 19 s, Sprache „Englisch“ auf deutsches Audio | erwartungsgemäß unbrauchbar |
| 2026-10-03 | dito | dito | `small` | dito | 48 s, Sprache „Deutsch“, Video mit Hintergrundmusik | 22 Segmente, `finish` ok; Anfang als `[Musik]` verworfen (WER 37,6 %). Mit `whisper-server -sns -bs 5` im Replay 10,9 % (jetzt Standard in `run.sh`) |

| 2026-10-04 | iPhone 11 Pro Max | kiworkstation (RTX 3090), Docker-Stack, Nemotron 3.5 Streaming + Diarization | `nemotron-3.5-asr-streaming-0.6b` q8 | WLAN, Tailnet, `tailscale serve` | 137 s, Deutsch, 4 Sprechende | Vom iPhone gegen den Server: Transkript angekommen; Replay-Messung WER 15,9 % gegenüber whisper turbo offline, keine Wortverluste, 4 Sprechende erkannt (`docs/ops/benchmarks.md`) |

Offen: handkorrigierte Referenz für die 137-s-Aufnahme, Modellentscheidung nach weiteren Aufnahmen. Der Langzeittest (61 min) ist bestanden. Die App-Version mit Sprecheranzeige, Serverprofilen und eigenem Icon ist seit 2026-10-04 auf dem iPhone installiert.

## Stand 2026-10-04, zweite Runde: Aufnahmenliste, Sprechernamen, Protokoll-Assistent

Auf dem Server ist erledigt: `LLM_URL` und `LLM_MODEL` in der `.env` auf kiworkstation zeigen auf den laufenden Qwen3-8B-`llama-server` (über die Tailnet-HTTPS-Adresse des Hosts, weil der Container `127.0.0.1` des Hosts nicht erreicht), Adapter neu gebaut, `/v1/health` meldet `notes: true`. Der Qwen3-8B-Server muss dafür laufen; ist er gestoppt, zeigt die App beim Protokoll „Der Protokoll-Assistent ist auf dem Server nicht eingerichtet oder gerade nicht erreichbar.“

Zum Prüfen auf dem iPhone, nach dem Update der App:

- [ ] Aufnahme machen und stoppen. Erwartung: nach wenigen Sekunden steht in der Liste (Knopf mit Listensymbol oben rechts) eine `M4A`-Datei statt `WAV`, etwa ein Fünftel so groß.
- [ ] „Sprecher benennen“ unter der Mitschrift: Namen vergeben, sichern. Erwartung: Spalte zeigt Initialen, Export und Protokoll verwenden die Namen.
- [ ] „Protokoll erstellen“: dauert bei 2 min Gespräch etwa 3–5 s, bei einer Stunde bis zu einer Minute. Erwartung: Protokoll mit Zusammenfassung, Themen, Entscheidungen, Aufgaben (mit Belegzitat) und offenen Punkten; Teilen als `.md`.
- [ ] In der Liste eine alte Aufnahme öffnen, „Nachträglich transkribieren“, danach Protokoll. Löschen über Papierkorb oder „Bearbeiten“ mit Mehrfachauswahl.
- [ ] Live-Ansicht während einer Aufnahme nach oben scrollen. Erwartung: kein Zwangsscroll mehr, stattdessen Knopf „Zum Ende“.
- [ ] Mit ausgeschaltetem Tailscale eine Aufnahme starten. Erwartung: nach wenigen Sekunden steht unter dem Titel „Server nicht erreichbar, ist Tailscale auf dem iPhone an? …“; die Aufnahme läuft lokal weiter.
- [ ] App während einer Aufnahme hart beenden (App-Umschalter, nach oben wischen), neu starten. Erwartung: die Aufnahme steht in der Liste mit Marke „unterbrochen“ und ist abspielbar und nachträglich transkribierbar.
- [ ] Die Gerätetests aus dem Abschnitt oben (Flugmodus, Anruf, Bildschirmsperre, Mobilfunk) stehen weiterhin aus.
- [ ] Die kostenlose Signatur läuft um den 11. Oktober 2026 ab; danach die App einmal neu installieren (`zsh Scripts/build-ios.sh device`, iPhone im selben WLAN reicht).

## Stand 2026-10-06: Mitschrift bearbeiten, Zusammenfassung

Unter der Mitschrift gibt es „Bearbeiten“ (Schere): Abschnitte entfernen, etwa ein Nebengespräch, weil die Aufnahme weiterlief, und Texte korrigieren, bevor Protokoll oder Zusammenfassung entstehen. Auf Wunsch verschwinden die Stellen auch aus der Audiodatei (Anfang und Ende werden abgeschnitten, dazwischen stummgeschaltet). Daneben steht „Zusammenfassung erstellen“ für Vorträge, Trainings und Infoveranstaltungen. Hinweis: Während der Aufnahme geht das Audio live an den eigenen ASR-Server; der Adapter speichert es nicht.

Zum Prüfen auf dem iPhone:

- [ ] Eine Aufnahme mit einem Nebengespräch am Ende machen, stoppen, „Bearbeiten“: den ersten Satz des Nebengesprächs nach rechts wischen („Ab hier“). Erwartung: Hinweis „N Abschnitte entfernt“, Schalter „Auch aus der Audiodatei entfernen“ an, „Sichern“ fragt nach und kürzt. In der Liste ist die Aufnahme kürzer, beim Abspielen fehlt das Ende.
- [ ] Einen Abschnitt in der Mitte entfernen (nach links wischen) und einen Text antippen und korrigieren; „Rückgängig“ und „Auswählen“ ausprobieren.
- [ ] „Zusammenfassung erstellen“ bei einer Schulung oder einem Vortrag. Erwartung: Überblick, Kernaussagen, Inhalte nach Themen, Fragen und Antworten (nur echte Fragen), Hinweise. In der Liste erscheint die Marke „Zusammenfassung“ und öffnet sie direkt.
- [ ] Nach dem Kürzen einer Aufnahme mit vorhandenem Protokoll steht ein gelber Hinweis, dass es aus der alten Fassung stammt; „Neu erstellen“ im Menü des Protokolls aktualisiert es.


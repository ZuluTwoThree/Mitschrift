## Ziel

Mitschrift soll als iPhone-App Gespräche aufnehmen und eine nahezu live aktualisierte Transkription anzeigen. Die Spracherkennung läuft nicht auf dem iPhone und auch nicht über einen öffentlichen Cloud-Dienst, sondern auf einer selbst betriebenen Maschine im privaten Tailscale-Tailnet.

Die Lösung soll einen leistungsfähigen ASR-Dienst (z. B. `whisper.cpp` mit einem geeigneten Whisper-Modell) auf dem Server nutzen. Ein lokaler LLM-Server mit Ollama, llama.cpp oder OpenWebUI kann anschließend optional zur Bereinigung, Strukturierung oder Zusammenfassung des Texts eingesetzt werden; er ersetzt den ASR-Dienst nicht.

## Nutzerfluss

1. Die Person öffnet Mitschrift auf dem iPhone und startet eine Aufnahme.
2. Die App erfasst das Mikrofon und zeigt fortlaufend vorläufige Textabschnitte an.
3. Kurze Audioabschnitte werden verschlüsselt über das Tailnet an den eigenen ASR-Server gesendet.
4. Der Server liefert Textsegmente zurück. Noch unsichere Segmente dürfen aktualisiert werden; bestätigte Segmente werden finalisiert.
5. Beim Beenden der Aufnahme speichert Mitschrift Audio und die finalisierte Transkription lokal und bietet Export bzw. Weiterverarbeitung an.

## Nicht-Ziele für die erste Version

- Keine öffentliche Erreichbarkeit des ASR-Dienstes und kein Tailscale Funnel.
- Kein Upload zu OpenAI oder einem anderen externen Transkriptionsanbieter.
- Kein Mitschnitt von System-, Telefon- oder Videokonferenz-Audio.
- Keine Sprechertrennung, Übersetzung oder automatische Zusammenfassung während der ersten Live-Transkriptionsversion.
- Keine On-Device-Whisper-Inferenz auf dem iPhone.
- Keine Abhängigkeit von Ollama, OpenWebUI oder llama.cpp für die eigentliche Spracherkennung.

## Zielarchitektur

```text
+-------------------+        privates Tailnet         +-------------------------+
| Mitschrift iOS    | -- HTTPS / später WebSocket --> | ASR-Maschine            |
|                   | <--- Textsegmente / Status ---- | whisper.cpp / ASR-Modell|
| AVAudioEngine     |                                 | optional: lokaler LLM    |
+-------------------+                                 +-------------------------+
```

- **iPhone:** Erfasst Audio, segmentiert es, sendet es an den konfigurierten privaten Endpunkt und stellt vorläufige sowie finale Textsegmente dar.
- **Tailscale:** Stellt das private, verschlüsselte Netz zwischen iPhone und ASR-Maschine bereit. Der Server wird über MagicDNS bzw. eine private Tailnet-Adresse angesprochen.
- **ASR-Server:** Nimmt Audiodaten entgegen, führt Whisper-Inferenz aus und liefert segmentierte Transkription zurück. Für den Start kann ein kleiner Adapter vor dem vorhandenen `whisper-server`-Endpunkt stehen.
- **Optionaler LLM:** Erhält ausschließlich bereits transkribierten Text und darf diesen auf Wunsch glätten, formatieren oder zusammenfassen. Roh-Audio wird nicht an den LLM weitergegeben.

## API- und Transportkonzept

### Stufe 1: robuste Segment-API (MVP)

Die erste Version verwendet HTTPS-Uploads kurzer, überlappender PCM/WAV-Segmente. Dies ist deutlich einfacher zu testen und wiederaufzunehmen als ein dauerhafter Stream.

- Segmentlänge: zunächst 2–3 Sekunden.
- Überlappung: zunächst 250–500 ms, damit Wörter an Segmentgrenzen nicht verloren gehen.
- Jede Anfrage enthält mindestens `sessionId`, fortlaufende `sequence`, Aufnahmezeitpunkt, Sprache und Audioformat.
- Die Antwort enthält mindestens `sequence`, Text, Start-/Endzeit, einen Status `partial` oder `final` sowie optionale Diagnosewerte (z. B. Server-Latenz).
- Die App darf ein Segment bei Netzfehlern idempotent erneut senden. Der Server muss doppelte Sequenznummern erkennen oder die Antwort reproduzierbar machen.
- Die Server-URL und ein optionaler Anwendungstoken werden konfigurierbar gehalten; eine URL darf nicht fest in die App kompiliert werden.

Ein möglicher, bewusst schlanker Vertrag:

```http
POST /v1/live-transcriptions/segments
Content-Type: audio/wav
X-Mitschrift-Session: <uuid>
X-Mitschrift-Sequence: <integer>
X-Mitschrift-Language: de
```

```json
{
  "sessionId": "…",
  "sequence": 42,
  "segments": [
    { "start": 83.0, "end": 85.4, "text": "…", "state": "final" }
  ]
}
```

### Stufe 2: echter Streamingkanal

Nach einem stabilen HTTP-MVP kann ein WebSocket- oder vergleichbarer bidirektionaler Kanal ergänzt werden. Der gleiche Sequenz- und Sitzungsvertrag bleibt erhalten. Ziel ist eine niedrigere wahrgenommene Latenz, nicht ein anderer Datenschutz- oder Berechtigungsweg.

## Arbeiten in der iOS-App

### Plattformaufteilung

Die bestehende macOS-App enthält AppKit- und Prozess-Aufrufe, die auf iOS nicht verfügbar sind. Transkriptionsdomäne, Aufnahmezustand, Dateibenennung, Exportmodell und API-Client sollen deshalb in eine plattformneutrale Swift-Schicht ausgelagert werden. macOS- und iOS-spezifische Funktionen erhalten getrennte Adapter.

- Neues iOS-Target und gemeinsames Core-Modul anlegen.
- AppKit-spezifische Datei-Dialoge und `Process`-basierte lokale Whisper-Ausführung für iOS kapseln bzw. ersetzen.
- Bestehende lokale macOS-Transkription unverändert funktionsfähig halten.

### Audio und Aufnahme

- Mikrofonzugriff sauber anfordern und einen verständlichen Ablehnungszustand anzeigen.
- Aufnahme mit `AVAudioEngine`/`AVAudioSession` implementieren.
- Ein für Sprachübertragung geeignetes lineares Audioformat wählen und serverseitig dokumentieren.
- Leichte Sprachaktivitätserkennung (VAD) oder Stilleerkennung verwenden, um unnötige Segmente zu reduzieren; die erste Version muss auch ohne VAD korrekt funktionieren.
- Segmentpuffer, Überlappungen und lokale temporäre Audiodateien so verwalten, dass Speicher begrenzt bleibt.
- Aufnahme im zulässigen iOS-Hintergrundmodus fortführen; bei einer vom Betriebssystem erzwungenen Unterbrechung verständlich pausieren und nach Rückkehr fortsetzen.

### Live-UI

- Aufnahmebildschirm mit Dauer, Verbindungs-/Serverstatus und eindeutiger Mikrofonanzeige.
- Finale Abschnitte visuell von noch vorläufigen Abschnitten unterscheiden.
- Textkorrekturen dürfen nur den noch nicht finalen Fensterbereich verändern; bereits finalisierte Abschnitte dürfen nicht unerwartet umgeschrieben werden.
- Anzeige für Warteschlange, Wiederverbindung und fehlendes Tailnet.
- Nach Aufnahmeende: finalen Server-Abgleich abwarten, Transkription persistent speichern und Export ermöglichen.

## Arbeiten auf der ASR-Maschine

- Whisper-/ASR-Laufzeit mit einem für die Hardware geeigneten Modell bereitstellen; als Ausgangspunkt Modellqualität und Echtzeitfaktor messen.
- Einen kleinen authentifizierten Dienst oder Adapter vor `whisper-server` betreiben, der den oben beschriebenen Segmentvertrag implementiert.
- Der Dienst darf nur im Tailnet lauschen bzw. durch Tailscale veröffentlicht werden, nicht direkt im öffentlichen Netz.
- Temporäre Audiodateien nach erfolgreicher Verarbeitung zuverlässig entfernen. Transkriptionen nur speichern, wenn dies bewusst als spätere Funktion aktiviert wird.
- Begrenzungen für Anfragegröße, parallele Sessions, Zeitüberschreitungen und Warteschlangen vorsehen, damit eine blockierte Sitzung den Dienst nicht dauerhaft lahmlegt.
- Serverdiagnostik auf Betriebsdaten beschränken; weder Audio noch Transkriptinhalt standardmäßig protokollieren.

## Tailscale- und Sicherheitsmodell

- Das iPhone und die ASR-Maschine sind Mitglieder desselben Tailnets.
- Für den Endpunkt MagicDNS oder eine feste private Adresse verwenden; der konkrete Hostname wird nicht im Repository oder in Screenshots fest verdrahtet.
- Zugriff mit Tailscale-ACLs auf die relevante Geräteidentität bzw. ein Tag und ausschließlich den benötigten Dienstport einschränken.
- Für HTTPS `tailscale serve` oder eine gleichwertige private HTTPS-Konfiguration einsetzen. Kein Funnel aktivieren.
- Falls ein Anwendungs-Token nötig wird, diesen im iOS-Schlüsselbund speichern und nicht im Quellcode, in Konfigurationsbeispielen oder in Protokollen hinterlegen.
- Bei der Wahl eines Tailscale-HTTPS-Namens berücksichtigen, dass Zertifikatsnamen öffentlich nachvollziehbar sein können; neutrale Gerätenamen verwenden.
- Die App erklärt vor Start der Aufnahme klar: Audio wird über das private Tailnet an den eigenen ASR-Server gesendet; es erfolgt kein Upload an einen externen Transkriptionsdienst.

## Fehlertoleranz und Offline-Verhalten

- Zeitüberschreitungen, nicht erreichbarer Server, fehlendes Tailnet, abgelehnte Berechtigungen und Serverüberlastung erhalten konkrete, nicht-technische UI-Meldungen.
- Nicht bestätigte Audiosegmente bleiben lokal in einer begrenzten Warteschlange und werden bei Wiederverbindung in Reihenfolge übertragen.
- Ist die Warteschlange voll oder die Verbindung zu lange unterbrochen, wird die Aufnahme nicht stillschweigend als erfolgreich transkribiert: Die App informiert sichtbar über eine pausierte Live-Übertragung und ermöglicht späteres Nachreichen bzw. lokale Sicherung.
- Beim Beenden einer Sitzung werden ausstehende Segmente final übertragen oder als ausstehend markiert; kein Text darf unbemerkt verloren gehen.
- Serverseitig liefert ein Health-Endpunkt Modellstatus, Auslastung und Version ohne personenbezogene Inhalte.

## Akzeptanzkriterien

- [ ] Auf einem realen iPhone kann ein privater ASR-Endpunkt konfiguriert und mit einem Verbindungstest geprüft werden.
- [ ] Eine deutschsprachige Aufnahme zeigt im Vordergrund fortlaufend Text; die wahrgenommene Latenz und der Echtzeitfaktor sind im Testprotokoll festgehalten.
- [ ] Die gesamte Audioübertragung bleibt innerhalb des Tailnets; der Dienst ist nicht über einen öffentlichen Funnel erreichbar.
- [ ] Ein kurzer Netzwechsel oder eine Unterbrechung führt nicht zu stillschweigend verlorenen finalen Segmenten.
- [ ] Beim Stoppen der Aufnahme wird eine finalisierte Mitschrift lokal persistiert und kann exportiert werden.
- [ ] Mikrofonberechtigung, nicht erreichbarer Server und fehlende Tailnet-Verbindung sind verständlich behandelt.
- [ ] Der bestehende macOS-Aufnahme- und M4A-Importpfad wird automatisiert oder manuell regressionsgetestet und bleibt funktionsfähig.
- [ ] Es existieren keine Zugangsdaten, Tailnet-Namen oder echten privaten URLs im Git-Repository.

## Meilensteine

### A — Entscheidung und Vertrag

- [ ] Zielhardware der ASR-Maschine, Modell (Qualität/Geschwindigkeit) und gewünschte Ziel-Latenz festlegen.
- [ ] HTTP-Segmentvertrag, Fehlercodes, Health-Check und Authentifizierungsentscheidung dokumentieren.
- [ ] Tailscale-ACL und HTTPS-Bereitstellung minimal und privat einrichten.

### B — Gemeinsamer App-Kern und iOS-Grundgerüst

- [ ] Gemeinsames Core-Modul extrahieren.
- [ ] iOS-Target, Berechtigungen, Aufnahmezustand und Konfigurationsansicht anlegen.
- [ ] Tailnet-Verbindungscheck und sichere Speicherung der Endpunktkonfiguration umsetzen.

### C — Server-MVP und segmentierte Transkription

- [ ] ASR-Adapter implementieren und lokal gegen Test-WAVs prüfen.
- [ ] iOS-Audio in Segmente aufteilen, hochladen und Antworten in die Live-Ansicht einarbeiten.
- [ ] Reihenfolge, Wiederholung und Finalisierung mit simulierten Netzfehlern testen.

### D — Produktreife Live-Erfahrung

- [ ] Vorläufige/finale Textdarstellung, Warteschlangenanzeige und Wiederverbindung verbessern.
- [ ] Hintergrundaufnahme, Unterbrechungen und Sitzungabschluss auf realer Hardware testen.
- [ ] Export und lokale Persistenz integrieren.

### E — Absicherung und Dokumentation

- [ ] Datenschutz-/Sicherheitscheck einschließlich ACL, öffentlicher Erreichbarkeit und Log-Rotation durchführen.
- [ ] Installations- und Betriebsanleitung für ASR-Server, Tailscale und iPhone-Konfiguration schreiben.
- [ ] Optional: lokale LLM-Nachbearbeitung als klar getrennte, abschaltbare Funktion ergänzen.

## Offene Entscheidungen

1. Welche Hardware stellt den ASR-Server bereit (Mac mit Apple Silicon, Linux mit GPU, CPU-only)?
2. Welches ASR-Modell erfüllt das gewünschte Verhältnis aus deutscher Qualität, Latenz und Stromverbrauch? Kandidaten sind unter anderem `small`, `medium`, `large-v3` und `large-v3-turbo`, abhängig von der Serverhardware.
3. Soll der MVP mit robustem HTTPS-Segmentupload starten oder wird ein WebSocket-Kanal bereits für die erste nutzbare Version benötigt?
4. Wie soll die iPhone-App verteilt werden (persönliches Gerät/Development, TestFlight, App Store)? Das beeinflusst Signing, Testabläufe und Hintergrundtests.
5. Soll die Server-URL allein durch Tailnet-Mitgliedschaft geschützt sein oder zusätzlich einen Anwendungstoken verlangen?

## Testplan

- Funktionstest mit echtem iPhone im WLAN und über Mobilfunk, jeweils mit aktivem Tailnet.
- Deutschsprachige Beispielgespräche mit kurzen Pausen, langen Sätzen, Fachbegriffen und mehreren Gesprächspartnern.
- Simulierter Server-Neustart, WLAN-Wechsel und kurzfristiger Tailnet-Ausfall während einer aktiven Aufnahme.
- Langzeittest, um Speicherverbrauch, Warteschlangenbegrenzung und Serverlast zu prüfen.
- Kontrolltest, dass der Dienst von einem nicht autorisierten Tailnet-Gerät sowie aus dem öffentlichen Internet nicht erreichbar ist.
- Regressionstest für macOS: Mikrofonaufnahme, Import einer `.m4a`-Datei und Transkription mit `base` und `small`.

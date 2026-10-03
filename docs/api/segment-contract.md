# Segment-API: Vertrag zwischen Mitschrift-App und ASR-Adapter

Version 1, Stand 2026-10-02. Dieser Vertrag ist verbindlich für die iOS-App (`MitschriftCore/Live`) und den Adapter unter `Server/asr-adapter`. Änderungen erhöhen die Versionsnummer im Pfad.

## Grundsätze

- Transport ist HTTPS innerhalb des Tailnets. Der Adapter lauscht nur auf dem Tailscale-Interface oder hinter `tailscale serve`.
- Jede Anfrage trägt einen Bearer-Token im Header `Authorization`. Ohne gültigen Token antwortet der Server mit 401, ohne weitere Details.
- Eine **Session** entspricht einer Aufnahme. Die App erzeugt die `sessionId` als UUID v4 und verwendet sie für alle Segmente dieser Aufnahme.
- Die **Sequenznummer** beginnt bei 0 und steigt pro Segment um 1. Sie ist der Schlüssel für Idempotenz: Ein erneut gesendetes Segment mit bekannter Nummer liefert dieselbe Antwort ohne erneute Inferenz.
- Der Server hält Audio nur im Speicher für das aktuelle Fenster und schreibt weder Audio noch Text auf Platte, solange keine spätere Funktion das ausdrücklich aktiviert.

## Audioformat

| Eigenschaft | Wert |
| --- | --- |
| Container | WAV (RIFF) mit 44-Byte-Standardheader |
| Codierung | PCM, 16 Bit, signed, little-endian |
| Abtastrate | 16 000 Hz |
| Kanäle | 1 (mono) |
| Segmentlänge | 2,5 s Sollwert, erlaubt 1,0 s bis 5,0 s |
| Überlappung | 300 ms zum vorherigen Segment, die App liefert sie bereits im Audio mit |
| Maximale Größe | 1 048 576 Byte (1 MiB) je Anfrage |

Der Adapter verwirft Segmente mit anderem Format mit 400. Er führt keine Konvertierung durch.

## Endpunkte

### `GET /v1/health`

Ohne Token erreichbar, liefert nur Betriebsdaten.

```json
{
  "status": "ok",
  "version": "0.1.0",
  "model": "ggml-small.bin",
  "modelLoaded": true,
  "activeSessions": 1,
  "maxSessions": 4,
  "language": "de"
}
```

`status` ist `ok`, `loading` (Modell wird noch geladen, HTTP 503) oder `degraded` (Modell geladen, aber `whisper-server` antwortet nicht, HTTP 503).

### `POST /v1/live-transcriptions/segments`

Nimmt ein Audiosegment entgegen und liefert den aktuellen Transkriptionsstand der Session.

Request-Header:

| Header | Pflicht | Bedeutung |
| --- | --- | --- |
| `Authorization: Bearer <token>` | ja | Anwendungstoken |
| `Content-Type: audio/wav` | ja | Audio im oben beschriebenen Format |
| `X-Mitschrift-Session: <uuid>` | ja | Session-ID der Aufnahme |
| `X-Mitschrift-Sequence: <int>` | ja | Fortlaufende Sequenznummer ab 0 |
| `X-Mitschrift-Language: de` | ja | `de`, `en` oder `auto` |
| `X-Mitschrift-Captured-At: <RFC 3339>` | nein | Aufnahmezeitpunkt des Segmentbeginns auf dem Gerät |
| `X-Mitschrift-Client: <string>` | nein | App-Version für Diagnose, z. B. `ios/0.1.0` |

Body: das WAV-Segment.

Antwort 200:

```json
{
  "sessionId": "9b6c2c1e-9d4a-4c4e-9f3c-2a2f1d5c7e10",
  "sequence": 42,
  "windowStart": 97.5,
  "windowEnd": 105.0,
  "final": [
    { "start": 97.8, "end": 100.1, "text": "Wir beginnen mit dem zweiten Punkt." }
  ],
  "partial": [
    { "start": 100.4, "end": 104.6, "text": "Dabei geht es um die" }
  ],
  "diagnostics": {
    "serverLatencyMs": 420,
    "realtimeFactor": 0.17,
    "queuedSegments": 0
  }
}
```

Bedeutung der Felder:

- `windowStart`, `windowEnd`: Zeitbereich in Sekunden ab Sessionbeginn, den der Server für diese Antwort transkribiert hat.
- `final`: Segmente, die in dieser Antwort **neu** finalisiert wurden. Die App hängt sie an ihre Liste finaler Segmente an. Ein finales Segment wird nie erneut geliefert und nie geändert.
- `partial`: Der vollständige aktuelle Stand des noch nicht finalisierten Bereichs. Die App **ersetzt** ihre Partial-Liste komplett. Die Liste darf leer sein.
- Zeiten beziehen sich auf die Sessionzeitachse. Sie werden aus Sequenznummer, Segmentlänge und Überlappung berechnet, nicht aus `X-Mitschrift-Captured-At`.
- `diagnostics` ist optional und enthält keine Inhalte.

Idempotenz: Ein Segment mit bereits verarbeiteter `sequence` liefert die gespeicherte Antwort von damals mit HTTP 200. Ein Segment mit einer Sequenznummer, die mehr als 1 über der letzten liegt, wird mit 409 abgelehnt; die App muss Segmente in Reihenfolge senden.

### `POST /v1/live-transcriptions/{sessionId}/finish`

Schließt die Session. Der Server transkribiert den Restpuffer, finalisiert alles und gibt den Speicher frei.

Request-Header: `Authorization`, optional `X-Mitschrift-Client`. Kein Body.

Antwort 200:

```json
{
  "sessionId": "9b6c2c1e-9d4a-4c4e-9f3c-2a2f1d5c7e10",
  "lastSequence": 118,
  "final": [
    { "start": 100.4, "end": 105.0, "text": "Dabei geht es um die Terminplanung." }
  ],
  "partial": []
}
```

`final` enthält nur die in diesem Schritt neu finalisierten Segmente. `partial` ist immer leer. Ein zweiter `finish`-Aufruf derselben Session liefert 200 mit leeren Listen und derselben `lastSequence`.

## Finalisierungsregel

Der Server hält je Session einen Rollpuffer von höchstens 12 s Audio. Nach jedem Segment transkribiert er den gesamten Puffer. Ein erkanntes Segment gilt als final, wenn sein Ende mindestens 3,0 s vor dem Pufferende liegt **und** eine der folgenden Bedingungen erfüllt ist:

- zum nächsten erkannten Segment besteht eine Lücke von mindestens 0,2 s (Sprechpause) oder es gibt kein weiteres Segment,
- der Text endet mit `.`, `!` oder `?` (Satzende),
- das Segmentende liegt mindestens 8 s vor dem Pufferende (Zwangsfinalisierung, damit bei durchgehender Rede nichts aus dem Puffer fällt).

Hintergrund: Whisper setzt Segmentgrenzen gelegentlich mitten in ein Wort, wenn das Fenster dort endete. Würde der Server genau dort finalisieren und den Puffer abschneiden, ginge der Wortrest verloren.

Finalisierte Segmente werden aus dem Puffer entfernt. Der Schnitt liegt nicht exakt am Segmentende, sondern an der leisesten 50-ms-Stelle bis zu 0,4 s danach (und vor dem Beginn des nächsten Segments). Alles hinter dem Schnitt wird als `partial` geliefert.

Die Konstanten (Puffer 12 s, Sicherheitsabstand 3 s, Pause 0,2 s, Zwangsfrist 8 s, Suchfenster 0,4 s) sind Serverkonfiguration und können ohne Vertragsänderung angepasst werden.

## Fehlercodes

| HTTP | Bedeutung | Verhalten der App |
| --- | --- | --- |
| 400 | Ungültiges Audio, fehlender Header, ungültige Sprache | Segment verwerfen, Fehler anzeigen, Aufnahme läuft lokal weiter |
| 401 | Token fehlt oder falsch | Übertragung pausieren, Einstellungen prüfen lassen |
| 404 | Session unbekannt (nur bei `finish`) | Als beendet behandeln |
| 409 | Session bereits beendet oder Sequenzlücke | Session beenden, neue Session für weitere Segmente |
| 413 | Segment größer als 1 MiB | Segment verwerfen, Fehler protokollieren |
| 429 | Zu viele Sessions oder Anfragen | Mit Backoff erneut senden, Hinweis „Server ausgelastet“ |
| 503 | Modell lädt oder `whisper-server` nicht erreichbar | Mit Backoff erneut senden, Hinweis „Server startet“ |

Fehlerantworten tragen einen JSON-Body `{ "error": "<code>", "message": "<kurzer Text>" }`. Der `message`-Text enthält nie Audio- oder Transkriptinhalt.

## Limits (Serverkonfiguration, Startwerte)

| Limit | Wert |
| --- | --- |
| Parallele Sessions | 4 |
| Session-Timeout ohne Segment | 60 s, danach wird die Session wie `finish` behandelt und der Speicher freigegeben |
| Maximale Sessiondauer | 4 h |
| Anfrage-Timeout | 15 s |
| Anfragen pro Session | 2 gleichzeitig; weitere werden mit 429 abgewiesen |

## Verhalten der App

- Segmente werden lokal in einer begrenzten Warteschlange gehalten (Startwert 60 Segmente, rund 2,5 min) und in Reihenfolge gesendet. Es ist höchstens ein Segment gleichzeitig in Übertragung.
- Bei 5xx, 429 und Netzfehlern wiederholt die App mit exponentiellem Backoff ab 1 s bis höchstens 30 s. Die Aufnahme läuft derweil lokal weiter.
- Ist die Warteschlange voll, zeigt die App „Live-Übertragung pausiert“ an und speichert Audio weiterhin lokal. Die Aufnahme kann nach dem Stoppen nachträglich übertragen werden.
- Bei `finish` wartet die App auf alle ausstehenden Segmente, sendet dann `finish` und übernimmt die letzten finalen Segmente. Erst danach gilt die Mitschrift als vollständig.

# Aufnahmeformat: WAV während der Aufnahme, AAC danach

Stand 2026-10-04. Frage: Müssen Aufnahmen als WAV auf dem iPhone liegen, oder reicht ein sparsameres Format?

## Ausgangslage

Die App schreibt während der Aufnahme PCM 16 Bit, 16 kHz, mono als WAV (`WAVFileWriter`). Das ist das
Vertragsformat der Live-Übertragung, lässt sich ohne Codec fortlaufend schreiben und nach einem Absturz mit
einer Kopfreparatur retten. Der Preis: 32 KB/s, also **115 MB je Stunde**. Nach einigen Wochen Nutzung wären das
Gigabyte an Sprachaufnahmen auf dem iPhone.

## Varianten

| Format | Größe je Stunde | Verlustfrei | Absturzsicher beim Schreiben | Nachträglich transkribierbar | Teilen |
| --- | --- | --- | --- | --- | --- |
| WAV PCM16 (bisher) | 115 MB | ja | ja (Kopfreparatur) | ja | überall |
| FLAC (AVAudioFile) | ca. 55–65 MB | ja | nein (Container unvollständig) | ja | fast überall |
| AAC-LC 32 kbit/s, `.m4a` | 15 MB (gemessen) | nein | nein (`moov`-Atom fehlt nach Absturz) | ja, WER +0,9 Punkte | überall |
| AAC-LC 48 kbit/s, `.m4a` | 22 MB (gemessen) | nein | nein | ja, WER +0,3 Punkte | überall |
| Opus | 10–15 MB | nein | nein | ja | iOS kann Opus nicht in `.m4a`/`.caf` schreiben, nur `.ogg` über Fremdcode |

Messung mit der 137-s-Aufnahme G137 (4 Sprechende) über den Adapter (Nemotron 3.5 Streaming, Referenz
whisper turbo offline, `tools/wer.py`): Original 15,9 %, nach AAC 32 kbit/s 16,8 %, nach AAC 48 kbit/s 16,2 %.
Das Streaming ist deterministisch (zwei Durchläufe des Originals: 0,0 % Abweichung), die Differenz geht also
auf den Codec zurück und liegt an Stellen, die ohnehin falsch erkannt werden (Namen). Kodierzeit 0,2 s für
137 s Audio, also rund 5 s je Stunde.

## Entscheidung

**Aufnehmen bleibt WAV, Archivieren wird AAC 48 kbit/s.** Während der Aufnahme schreibt die App weiter die
WAV-Datei (absturzsicher, keine Codec-Latenz, identisch mit dem Live-Stream). Nach dem Stopp wandelt
`AudioArchiver` die Datei im Hintergrund in `.m4a` um und löscht die WAV-Datei erst, wenn die AAC-Datei
vollständig lesbar ist. Scheitert die Umwandlung, bleibt die WAV-Datei liegen. Ergebnis: ein Fünftel der
Größe, Qualität der nachträglichen Transkription praktisch unverändert, auf jedem Gerät abspielbar.

Nachträgliche Übertragung („Nachträglich transkribieren“) liest beide Formate über `AudioFileReader`
(AVFoundation → 16 kHz mono Int16). Die Liste zeigt das Format je Aufnahme an; alte WAV-Dateien bleiben
unverändert nutzbar.

Nicht gewählt: FLAC, weil der Gewinn (halbe Größe) klein ist gegenüber AAC (ein Fünftel) und die Live-Erkennung
ohnehin nicht von der Datei abhängt. Opus, weil iOS keinen schreibenden Codec in einem gängigen Container
mitbringt.

# Review-Regeln

## Haltung

- Prüfe den Diff im Kontext des umgebenden Codes, nicht isoliert. Lies aufgerufene Funktionen, Schemas und Konfiguration nach, bevor du etwas behauptest.
- Melde nur, was du belegen kannst. Bei Unsicherheit formuliere als Frage, nicht als Befund.
- Qualität vor Menge: Wenige, relevante Anmerkungen sind besser als viele triviale. Kein Lob, keine Zusammenfassung dessen, was der PR tut.

## Schweregrade

Jeder Kommentar beginnt mit genau einer Kennzeichnung:

- `[BLOCKER]` – Fehlverhalten, Datenverlust, Sicherheitslücke, Breaking Change ohne Migration. Muss vor dem Merge behoben werden.
- `[WICHTIG]` – Wahrscheinliche Bugs in Randfällen, fehlende Fehlerbehandlung, fehlende Tests für kritische Pfade, deutliche Performance-Probleme.
- `[HINWEIS]` – Wartbarkeit, Lesbarkeit, bessere Alternative. Optional umzusetzen.

## Prüfschwerpunkte (in dieser Reihenfolge)

### 1. Korrektheit

- Logikfehler, Off-by-one, falsche Bedingungen, vertauschte Argumente
- Umgang mit `None`/leeren Collections/leeren Strings, Grenzwerten, Zeitzonen, Encoding
- Stimmt das Verhalten mit PR-Beschreibung, Docstrings und Funktionsnamen überein?

### 2. Sicherheit

- Hartcodierte Secrets, Tokens, Zugangsdaten oder interne Hostnamen
- SQL-/Command-/Path-Injection; ungeprüfte externe Eingaben
- Unsichere Deserialisierung (`pickle`, `yaml.load`, `eval`)
- Sensible Daten in Logs, Fehlermeldungen oder Prompts an externe Dienste

### 3. Daten & Persistenz

- Schema-Änderungen ohne Migration oder ohne Rückwärtskompatibilität
- Fehlende Transaktionen bei zusammengehörigen Schreibvorgängen
- Nicht idempotente Pipeline-Schritte (doppelte Ausführung darf keine Duplikate erzeugen)
- Fehlende Indizes bei neuen Abfragemustern; Vektor-Dimensionen und Distanzmetriken konsistent mit dem Index
- Kostenintensive Abfragen gegen externe Data Warehouses ohne Begrenzung (Partitionierung, `LIMIT`, Spaltenauswahl statt `SELECT *`)

### 4. Fehlerbehandlung & Robustheit

- Verschluckte Exceptions (`except: pass`, zu breite `except Exception`)
- Fehlende Timeouts und Retries bei Netzwerk- und Modellaufrufen
- Ressourcen-Lecks (Dateien, Verbindungen, Prozesse ohne Context Manager)
- Abbruch langer Läufe ohne Checkpoint/Wiederaufnahme

### 5. LLM- und Modellintegration

- Modellausgaben werden ohne Validierung weiterverarbeitet (JSON-Parsing, Schema-Prüfung, Fallback)
- Prompt-Injection über eingebettete Fremdtexte (Dokumente, Patente, Webinhalte)
- Kontextlänge, Batch-Größen und Token-Limits nicht abgesichert
- Nicht reproduzierbare Ergebnisse, wo Reproduzierbarkeit nötig ist (Temperatur, Seed, Modellversion nicht fixiert)

### 6. Performance

- N+1-Abfragen, wiederholte Arbeit in Schleifen, unnötiges Laden kompletter Datensätze in den Speicher
- Blockierende Aufrufe in asynchronem Code
- Nur melden, wenn der Pfad realistisch heiß ist – keine Mikrooptimierungen

### 7. Tests

- Neue Logik ohne Tests, insbesondere Fehler- und Randfälle
- Tests, die nichts prüfen (fehlende Asserts, nur Happy Path, übermäßiges Mocking)
- Tests, die von Netzwerk, Uhrzeit oder Reihenfolge abhängen

### 8. Wartbarkeit

- Duplizierter Code, der bestehende Hilfsfunktionen ignoriert
- Irreführende Namen, Magic Numbers, toter Code, auskommentierte Blöcke
- Fehlende Typannotationen an öffentlichen Schnittstellen
- Neue Abhängigkeiten: notwendig, gepflegt, Version gepinnt?

## Nicht kommentieren

- Formatierung und Stil, die ein Linter/Formatter abdeckt
- Persönliche Geschmacksfragen ohne konkreten Nachteil
- Code, den der PR nicht verändert – außer er wird durch die Änderung fehlerhaft
- Generierte Dateien, Lockfiles, Vendor-Verzeichnisse

## Format

- Inline-Kommentar an der betroffenen Zeile: Schweregrad, Problem in einem Satz, Begründung, konkreter Lösungsvorschlag (bei kleinen Fixes als Suggestion-Block).
- Abschließender Gesamtkommentar, höchstens fünf Zeilen: Anzahl der Befunde je Schweregrad und eine Empfehlung: Mergen, Mergen nach Fixes oder Überarbeiten.
- Wenn nichts Relevantes gefunden wurde: Das in einem Satz sagen, ohne künstliche Hinweise zu erzeugen.
- Sprache der Kommentare: Deutsch.

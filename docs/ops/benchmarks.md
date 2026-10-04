# Benchmarks ASR-Backends

Server: Ubuntu 24.04, RTX 3090 (24 GB), Stack aus `Server/deploy` (whisper.cpp CUDA-Image, NeMo-Speech.cpp v0.2.0 CUDA-Tarball). Replay mit `tools/replay.py --realtime` über den Adapter, Wortfehlerrate (WER) mit `tools/wer.py`. Referenz ist, sofern nicht anders angegeben, whisper `large-v3-turbo` offline mit demselben Audio; sie bevorzugt also Whisper und bestraft Nemotron für abweichende Schreibweisen (Zahlen, Abkürzungen). Eine handkorrigierte Referenz für die deutsche Gesprächsaufnahme steht noch aus.

## Aufnahmen

| Kürzel | Inhalt | Dauer |
| --- | --- | --- |
| G137 | Deutsches Gespräch, 4 Sprechende, Studio, iPhone-Aufnahme | 137 s |
| V48 | Deutscher Videoton mit Hintergrundmusik, iPhone-Aufnahme | 48 s |
| E56 | Englischer Videoton, durchgehende Rede, iPhone-Aufnahme | 56 s |
| T10 | Deutsche Sprachsynthese (`say`), zwei Sätze | 10 s |

## Live über den Adapter (Echtzeit-Replay), 2026-10-04

| Backend / Modell | Aufnahme | WER | Wörter (Ref.) | Finals während der Aufnahme | Antwortzeit Adapter |
| --- | --- | --- | --- | --- | --- |
| whisper.cpp `large-v3-turbo` q5_0, Fensterverfahren, `-sns -bs 5` | G137 | 17,7 % | 303 (345) | 25 | 306 ms |
| NeMo-Speech `nemotron-3.5-asr-streaming-0.6b` q8_0, Streaming, Endpointing 700 ms | G137 | 15,9 % | 351 (345) | 24 | 28 ms |
| whisper.cpp `large-v3-turbo` q5_0, Fensterverfahren | V48 | 16,0 % | 88 (94) | 9 | 270 ms |
| NeMo-Speech `nemotron-3.5` Streaming | V48 | 26,6 % | 98 (94) | 4 | 25 ms |

Lesart: Whisper verliert im Fensterverfahren Wörter an Schnittstellen (G137: 42 von 345 fehlen, sichtbar als abgeschnittene Wörter wie „Ausschnitt d von dem“). Nemotron verliert nichts; seine Abweichungen sind Erkennungsfehler bei Namen und Zahlen („ins Spannen“ für „Jens Spahn“, „fünf, neun GB“ für „5,9 GB“). Die Adapter-Antwortzeit ist bei Nemotron nur Weiterleitung, weil die Inferenz im Stream läuft; das erste Wort erscheint etwa 1 s nach Sprechbeginn, Finals rund 1 s nach einer Pause.

## Offline (ganze Datei), 2026-10-04

| Backend / Modell | Aufnahme | WER | Rechenzeit |
| --- | --- | --- | --- |
| NeMo-Speech `nemotron-3.5` GPU, mit deutscher ITN-Grammatik | G137 | 15,9 % | 2,8 s |
| NeMo-Speech `nemotron-3.5` GPU | V48 | 33,0 % | 1,3 s |
| NeMo-Speech `nemotron-3.5` GPU | E56 (Referenz turbo, en) | 3,6 % | 0,8 s |
| NeMo-Speech `nemotron-3.5` GPU | T10 | 3,6 % (ein Komma) | 0,2 s |
| NeMo-Speech `nemotron-3.5` CPU (16 Kerne) | V48 | 41,6 % (ohne ITN) | 6,8 s |
| whisper.cpp `large-v3-turbo` q5_0, Mac M3 Metal | G137 | Referenz | 15 s |

Nemotron streamt ohne Qualitätsverlust (G137 offline 15,9 % = live 15,9 %). Zahlen kommen ausgeschrieben, die ITN-Grammatik (`itn_configs.tar.bz2` aus dem Release) wandelt einen Teil in Ziffern („98“, „61“), Dezimalzahlen und Versionsnummern bleiben Wörter.

## Sprechertrennung (Nemotron 3 Diarization), G137

| Modus | Sprechende erkannt | Segmente | Rechenzeit |
| --- | --- | --- | --- |
| streaming | 4 (korrekt) | 11 | 3,9 s |
| offline | 3 | 16 | 1,0 s |

`POST /v1/audio/transcriptions` mit `diarization=true` liefert je Wort ein `speaker`-Feld; daraus entsteht eine Mitschrift mit 7 Sprecherwechseln, die den Verlauf des Gesprächs plausibel wiedergibt (Moderation, Zitat, zwei Gäste). Eine Messung der Fehlerrate gegen manuell markierte Wechsel steht aus.

Live über den Adapter (PR #14, `NEMO_SPEAKER_DIARIZATION=true`, Realtime-Kanal mit `speaker_diarization`): 32 finale Segmente, alle mit Label, Sprecher 1 bis 4; Äußerungen mit Wechsel werden in Sprecherläufe geteilt; WER unverändert 15,9 %.

## Langzeittest, 2026-10-04

G137 in Schleife, 61,5 min, Echtzeit-Replay über den Adapter (NeMo-Streaming mit Sprechertrennung, eine Session):

| Messgröße | Ergebnis |
| --- | --- |
| Segmente | 1678, alle HTTP 200, `finish` erfolgreich |
| Antwortzeit Adapter | 48 ms im Mittel, erste 400 Segmente 44 ms, letzte 400 Segmente 46 ms, Maximum 824 ms |
| Arbeitsspeicher Container | Adapter 52 → 54 MiB, NeMo-Speech 864 → 898 MiB, Whisper unverändert |
| VRAM | unverändert (NeMo-Speech 3,65 GB mit Diarization, Whisper 1,16 GB) |
| Fehler in Logs | keine |
| Wörter | 9332 erkannt zu 9315 erwartet (27 Wiederholungen) |

Keine Qualitätsdrift: Die Wortfehlerrate je Wiederholung (an der wiederkehrenden Anfangsphrase ausgerichtet) liegt über die ganze Stunde konstant zwischen 16,8 % und 19,1 % (Mittel erste fünf 18,1 %, letzte fünf 18,0 %). Eine erste Auswertung mit gleich großen Wortblöcken hatte eine scheinbare Drift gezeigt; das war ein Artefakt der Blockaufteilung.

## Mac M3 (8 GB), `small`, Fensterverfahren, 2026-10-03

| Aufnahme | Standard | `-sns -bs 5` |
| --- | --- | --- |
| V48 | 37,6 % | 10,9 % |
| E56 | 13,3 % | 12,4 % |
| T10 | 0,0 % | 0,0 % |

## Vorläufiges Fazit

Nemotron 3.5 über NeMo-Speech.cpp ist für die Live-Mitschrift das bessere Backend: keine Wortverluste, echte Satzgrenzen, Satzzeichen, Sprechertrennung aus derselben Laufzeit, 1,4 GB VRAM. Whisper bleibt als Fallback und für Offline-Nachbearbeitung (bessere Zahlen- und Namensschreibung). Offen: handkorrigierte Referenz für G137, Vergleich mit whisper `large-v3` f16 offline, Langzeittest.

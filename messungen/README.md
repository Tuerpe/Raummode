# Messungen

Pro Mess-Session ein Unterordner mit Datum, z. B. `2026-11-15_vorher/`, darin die
JSON-Dateien aus der App (und optional Roh-WAVs). Die Analyse schreibt nach
`<ordner>/analyse/` (ignoriert von git).

```
python pc/analyze.py messungen/2026-11-15_vorher
```

# Raummode – Linn Nexus mit dem iPhone messen und Equalizer APO einstellen

Ziel: Frequenzgang der Linn Nexus am Hörplatz messen (iPhone 15 Pro Max als Mikrofon,
iOS-Messmodus), daraus Equalizer-APO-Filter ableiten, einspielen, nachmessen.

```
PC spielt Sweep/Pink Noise ──Luft──▶ iPhone-App "Raummode" misst ──JSON──▶ pc/analyze.py ──▶ EQ-APO-Vorschlag
```

## Ordner

| Pfad | Inhalt |
| --- | --- |
| `pc/gen_signals.py` | erzeugt `pc/signals/sweep_20-20k_10s.wav` und `pink_noise_60s.wav` |
| `pc/eqapo_toggle.ps1` | schaltet Equalizer APO zwischen **Messen** (flach) und **EQ** um, sichert die Konfig |
| `pc/dsp_ref.py` | Python-Referenz des DSP (Sweep-Entfaltung, Glättung, RTA) |
| `pc/analyze.py` | Messungen → Zielkurve → Filter → `eqapo_vorschlag.txt`, `bericht.md`, `plot.png` |
| `pc/targets/` | Zielkurven `flach`, `raumkurve` (Standard), `harman` |
| `pc/tests/` | pytest für DSP und Analyse, Fixtures für den Kreuzvergleich mit Swift |
| `app/RaummodeDSP/` | Swift-Paket mit demselben DSP (pur Swift, Tests laufen auch unter Linux) |
| `app/Sources/`, `app/project.yml` | iOS-App (SwiftUI), Projekt wird per XcodeGen erzeugt |
| `.github/workflows/` | `dsp-tests.yml` (Ubuntu, bei jedem Push), `ios-build.yml` (macOS, manuell) |
| `messungen/` | hier landen die JSON-Dateien vom iPhone |

## Einmalige Einrichtung

### PC
```bash
python -m pip install numpy scipy matplotlib pytest
python pc/gen_signals.py
python -m pytest pc/tests -q
```

### App bauen (ohne Mac)
1. Repo auf GitHub, dann **Actions → „iOS-Build (unsigniert)" → Run workflow**.
   Nach ca. 10 Minuten liegt unter *Artifacts* `Raummode-ipa.zip` (darin `Raummode-unsigned.ipa`).
2. **Sideloadly** (Windows) installieren: <https://sideloadly.io>. Es bringt die Apple-Gerätetreiber mit.
3. iPhone per Kabel an den PC, in Sideloadly die `.ipa` ziehen, **eigene Apple-ID eingeben**
   (nur du, nicht ich), Start. Bei Zwei-Faktor-Abfrage den Code eingeben.
4. Am iPhone: *Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler-App → Vertrauen*.
5. Mit kostenloser Apple-ID läuft die App **7 Tage**; danach in Sideloadly einfach nochmal
   installieren (gleiche IPA, kein neuer Build nötig). Messdaten bleiben erhalten.

## Messablauf

1. **PC vorbereiten**
   ```powershell
   .\pc\eqapo_toggle.ps1 -Modus Messen
   ```
   Sound-Blaster-Software: SBX / Crystalizer / Bass / Smart Volume **aus**. Windows-Lautstärke
   auf einen festen Wert (notieren, z. B. 40 %), Lautstärke am Verstärker ebenfalls notieren.
   Fenster und Türen zu, Lüfter/Kühlschrank wenn möglich aus.
2. **Handy positionieren**: Hörplatz, Ohrhöhe, unteres Mikro Richtung Lautsprecher,
   auf Stativ/Kissen/Stuhllehne ablegen, nicht in der Hand.
3. **Sweep messen**: App → Tab *Sweep* → Name eingeben (z. B. `Hoerplatz`) → *Aufnahme 15 s* →
   sofort am PC `pc\signals\sweep_20-20k_10s.wav` starten (Doppelklick, Medienplayer).
   Qualität prüfen: Korrelation > 0,2, SNR > 20 dB, Spitze < −1 dBFS. Sonst lauter/leiser und wiederholen.
   *Zur Session hinzufügen*.
4. **3–5 Positionen**: Hörplatz, ±30 cm links/rechts, ±30 cm vor/zurück, evtl. 20 cm höher.
   Jeweils Schritt 3.
5. **Optional RTA**: `pink_noise_60s.wav` abspielen, Tab *RTA*, *Mittelung starten*, 20–30 s,
   *Speichern*. Gut, um beim Drehen am EQ live zu sehen, was passiert.
6. **Export**: Tab *Session* → *Als JSON speichern* → *Teilen* → *In Dateien sichern* → iCloud Drive,
   oder *Server im WLAN starten* und die angezeigte Adresse am PC im Browser öffnen.
   Die Datei nach `messungen\<datum>_<vorher|nachher>\` legen.
7. **EQ wieder an** (bis zur Analyse):
   ```powershell
   .\pc\eqapo_toggle.ps1 -Modus EQ
   ```

## Analyse und Einspielen

```bash
python pc/analyze.py messungen/2026-11-15_vorher            # Zielkurve: raumkurve
python pc/analyze.py messungen/2026-11-15_vorher --target harman --max-filters 8
```
Ergebnis in `messungen/<ordner>/analyse/`: `plot.png` ansehen, `bericht.md` lesen, dann

```powershell
.\pc\eqapo_toggle.ps1 -Modus EQ -Datei .\messungen\2026-11-15_vorher\analyse\eqapo_vorschlag.txt
```
Danach **nachmessen** (gleiche Lautstärke, gleiche Positionen, Ordner `..._nachher`) und beide
Ordner vergleichen. Das letzte Wort hat das Ohr: Filter, die sich schlechter anhören, raus.

Für Claude: Messordner nennen („analysiere `messungen/2026-11-15_vorher`"), dann kommen
Vorschlag und Erklärung; Änderungen an `config.txt` macht Levin oder das Toggle-Skript.

## Grenzen

- iPhone-Mikro ist unkalibriert: unter ~50 Hz und über ~15 kHz nur relativ lesen.
  Raummoden (+8–12 dB Spitzen) sind trotzdem gut sichtbar. Mit einem USB-Messmikro
  (z. B. miniDSP UMIK-1) kann die Kalibrierdatei per `--mic-cal` genutzt werden.
- Alle Pegel sind relativ (300 Hz–3 kHz = 0 dB), kein SPL.
- Die 7-Tage-Signatur ist eine Apple-Einschränkung der kostenlosen Apple-ID.

## Entwicklung

- Swift-Tests lokal ohne Toolchain (Docker in WSL):
  `wsl -d Ubuntu -- docker run --rm -v /mnt/c/Tools/ClaudeCode/StandardPC/Raummode:/w -w /w/app/RaummodeDSP swift:5.10 swift test -c release -Xswiftc -enable-testing`
- Sweep-Konstanten sind an drei Stellen identisch zu halten: `pc/gen_signals.py`,
  `pc/dsp_ref.py`, `app/RaummodeDSP/Sources/RaummodeDSP/Sweep.swift`.
- JSON-Schema 1 siehe `Measurement.swift` bzw. Docstring in `analyze.py`.

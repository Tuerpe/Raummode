# RaummodeDSP

Reines Swift-Paket (nur Foundation, kein Accelerate), damit dieselben Tests auf dem
iPhone, unter macOS und auf dem Ubuntu-Runner laufen. Referenzimplementierung und
Kreuzvergleich: `pc/dsp_ref.py`, `pc/tests/`.

## Oeffentliche API

| Typ / Funktion | Zweck |
| --- | --- |
| `SweepSpec` | Feste Konstanten: 48 kHz, 20 Hz–20 kHz, 10 s, Fades, −6 dBFS, 15 s Aufnahme |
| `SweepAnalyzer()` | erzeugt Referenz-Sweep und inversen Filter einmalig (ca. 1 s) |
| `.findSweep(in:)` | Offset + Korrelationsguete des Sweeps in einer Aufnahme |
| `.deconvolve(_:offset:)` | Impulsantwort + Index des Direktschalls |
| `SweepAnalyzer.windowIR / irToFR` | Fenster 5 ms / 500 ms, FFT 65536 → (Hz, dB) |
| `.analyze(recording:)` | komplette Pipeline → `SweepResult` (Log-Raster 48/Okt, 1/6 Okt geglaettet, normiert auf 300 Hz–3 kHz, `Quality`) |
| `ThirdOctave.levels(_:)` | 1/3-Oktav-RTA (Welch) fuer lange Aufnahmen |
| `ThirdOctave.levelsSingleBlock(_:)` | schnelle Variante fuer die Live-Anzeige |
| `Smoothing.*` | `fractionalOctave`, `logGrid`, `interpolateLog`, `normalize`, `powerAverage` |
| `Biquad.peaking` | EQ-APO-identischer PK-Filter (Simulation Vorher/Nachher) |
| `RoomMeasurement` | JSON-Schema 1 (Codable) fuer den Export, `recomputeAverage()` |
| `WavFile.read / writeFloat32` | WAV-Fixtures lesen, Rohaufnahmen exportieren |

## Tests

```bash
cd app/RaummodeDSP
swift test -c release -Xswiftc -enable-testing
```

Debug-Builds sind bei den 2^21-FFTs sehr langsam, deshalb Release. Der Fixture-Test
wird uebersprungen, wenn `pc/tests/fixtures/` fehlt (`python pc/tests/make_fixtures.py`).

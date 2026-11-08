#!/usr/bin/env python3
"""Erzeugt die Fixtures fuer den Kreuzvergleich Python <-> Swift.

pc/tests/fixtures/
  synthetic_recording.wav   15 s "Aufnahme": Sweep durch synthetischen Raum
                            (42 Hz Q8 +9 dB, 120 Hz Q4 -6 dB), Pegel 0.3,
                            Offset 59256 Samples (1,2345 s), weisses Rauschen -40 dB
  synthetic_expected.json   Ergebnis der Python-Pipeline (Log-Raster, normiert)
                            plus wahre Raumkurve (gleich geglaettet) und Qualitaet
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import dsp_ref as d  # noqa: E402
from gen_signals import write_wav_24bit  # noqa: E402

FIXTURES = HERE / "fixtures"
OFFSET = 59256
LEVEL = 0.3
NOISE_DB = -40.0
ROOM = [(42.0, 9.0, 8.0), (120.0, -6.0, 4.0)]   # (fc, gain, Q)
SEED = 4242


def synthetic_recording(offset: int = OFFSET, seed: int = SEED,
                        room=ROOM, level: float = LEVEL, noise_db: float = NOISE_DB) -> np.ndarray:
    x = d.reference_sweep().copy()
    for fc, g, q in room:
        b, a = d.peaking_coeffs(fc, g, q)
        x = d.apply_biquad(x, b, a)
    x *= level
    rec = np.zeros(int(d.RECORD_SECONDS * d.FS))
    n = min(len(x), len(rec) - offset)
    rec[offset: offset + n] = x[:n]
    rng = np.random.default_rng(seed)
    noise_rms = np.sqrt(np.mean(x ** 2)) * 10 ** (noise_db / 20)
    rec += rng.standard_normal(len(rec)) * noise_rms
    return rec


def true_room_curve(room=ROOM, smoothing: int = d.DEFAULT_SMOOTHING) -> np.ndarray:
    """Wahre Raumkurve auf dem Log-Raster, genauso geglaettet und normiert wie die Messung."""
    freq = np.fft.rfftfreq(d.NFFT_FR, 1 / d.FS)
    db = np.zeros_like(freq)
    for fc, g, q in room:
        b, a = d.peaking_coeffs(fc, g, q)
        db += d.biquad_response_db(freq, b, a)
    sm = d.smooth_fractional_octave(freq, db, smoothing)
    grid = d.log_grid()
    return d.normalize(grid, d.interpolate_log(freq, sm, grid))


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    rec = synthetic_recording()
    wav = FIXTURES / "synthetic_recording.wav"
    write_wav_24bit(wav, rec)
    # Fuer den Vergleich dieselben quantisierten Werte verwenden, die Swift liest
    q = np.round(np.clip(rec, -1, 1) * (2 ** 23 - 1)) / (2 ** 23 - 1)
    res = d.analyze_sweep_recording(q)
    out = {
        "description": "Synthetischer Raum: Sweep -> PK 42 Hz +9 dB Q8 -> PK 120 Hz -6 dB Q4, Pegel 0.3, Rauschen -40 dB",
        "offset": OFFSET,
        "room": [{"fc": fc, "gainDb": g, "q": qq} for fc, g, qq in ROOM],
        "smoothing": "1/%d" % d.DEFAULT_SMOOTHING,
        "freq": [round(float(f), 4) for f in res["freq"]],
        "db": [round(float(v), 4) for v in res["db"]],
        "truthDb": [round(float(v), 4) for v in true_room_curve()],
        "quality": res["quality"],
    }
    (FIXTURES / "synthetic_expected.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"{wav.name}: {wav.stat().st_size/1e6:.2f} MB; Offset gefunden {res['quality']['offset']} "
          f"(soll {OFFSET}), corr {res['quality']['corr']:.3f}, SNR {res['quality']['snrDb']:.1f} dB")
    grid = res["freq"]
    for f0 in (42, 120, 1000):
        i = int(np.argmin(np.abs(grid - f0)))
        print(f"  {f0:>5} Hz: gemessen {res['db'][i]:+.2f} dB, wahr {out['truthDb'][i]:+.2f} dB")


if __name__ == "__main__":
    main()

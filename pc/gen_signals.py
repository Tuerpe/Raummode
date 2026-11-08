#!/usr/bin/env python3
"""Erzeugt die Testsignale fuer die Raummessung (Projekt Raummode).

Ausgabe nach pc/signals/:
  pink_noise_60s.wav        Rosa Rauschen, 60 s, Spitze -1 dBFS, RMS ca. -15 dBFS
                            (Crest-Faktor von Rauschen ~14 dB)   (fuer RTA in der App)
  sweep_20-20k_10s.wav      Log-Sweep 20 Hz -> 20 kHz, 10 s, -6 dBFS,
                            2 s Stille davor und danach          (fuer Sweep-Messung)
  sweep_reference.json      Die Sweep-Parameter als Referenz fuer App und Analyse

Die Konstanten unten sind FEST und muessen mit app/RaummodeDSP (Sweep.swift)
und pc/dsp_ref.py uebereinstimmen. Wer sie aendert, aendert sie ueberall.

Nur numpy noetig; WAV wird mit dem Standardmodul `wave` geschrieben
(24 Bit, Mono, 48 kHz).
"""
from __future__ import annotations

import json
import wave
from pathlib import Path

import numpy as np

# ---- Feste Konstanten ---------------------------------------------------
SAMPLE_RATE = 48000

SWEEP_F1 = 20.0          # Hz
SWEEP_F2 = 20000.0       # Hz
SWEEP_DURATION = 10.0    # s
SWEEP_FADE_IN = 0.050    # s, halbes Hann-Fenster
SWEEP_FADE_OUT = 0.020   # s
SWEEP_LEVEL_DBFS = -6.0  # Spitzenpegel
SWEEP_SILENCE = 2.0      # s Stille vor und nach dem Sweep

PINK_DURATION = 60.0     # s
PINK_LEVEL_DBFS = -12.0  # RMS
PINK_SEED = 20261108     # reproduzierbar

OUT_DIR = Path(__file__).resolve().parent / "signals"


# ---- Signale ------------------------------------------------------------
def make_sweep(fs: int = SAMPLE_RATE) -> np.ndarray:
    """Exponentieller Sweep nach Farina, mit Ein-/Ausblendung, ohne Stille."""
    n = int(round(SWEEP_DURATION * fs))
    t = np.arange(n) / fs
    r = np.log(SWEEP_F2 / SWEEP_F1)
    phase = 2 * np.pi * SWEEP_F1 * SWEEP_DURATION / r * (np.exp(t * r / SWEEP_DURATION) - 1.0)
    x = np.sin(phase)

    n_in = int(round(SWEEP_FADE_IN * fs))
    n_out = int(round(SWEEP_FADE_OUT * fs))
    x[:n_in] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(n_in) / n_in)
    x[n - n_out:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(n_out) / n_out)

    return x * 10 ** (SWEEP_LEVEL_DBFS / 20)


def make_sweep_file_signal(fs: int = SAMPLE_RATE, stop_hz: float | None = None) -> np.ndarray:
    """Sweep mit 2 s Stille davor und danach, so wie die WAV abgespielt wird.

    stop_hz: schonende Variante, die bei dieser Frequenz ausblendet (Hochtoener-Schutz).
    Der Anfang ist identisch zum vollen Sweep, deshalb erkennt die App ihn genauso;
    oberhalb stop_hz enthaelt die Messung dann aber nur Rauschen (analyze.py --max-freq).
    """
    sil = np.zeros(int(round(SWEEP_SILENCE * fs)))
    s = make_sweep(fs)
    if stop_hz is not None:
        t_stop = SWEEP_DURATION * np.log(stop_hz / SWEEP_F1) / np.log(SWEEP_F2 / SWEEP_F1)
        n_stop = int(round(t_stop * fs))
        n_out = int(round(SWEEP_FADE_OUT * fs))
        s = s[:n_stop].copy()
        s[n_stop - n_out:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(n_out) / n_out)
    return np.concatenate([sil, s, sil])


def make_pink_noise(fs: int = SAMPLE_RATE, duration: float = PINK_DURATION,
                    seed: int = PINK_SEED) -> np.ndarray:
    """Rosa Rauschen (1/f-Leistungsdichte) per Spektralformung von weissem Rauschen."""
    n = int(round(duration * fs))
    rng = np.random.default_rng(seed)
    white = rng.standard_normal(n)
    spec = np.fft.rfft(white)
    freqs = np.fft.rfftfreq(n, 1 / fs)
    # Amplitude ~ 1/sqrt(f) => Leistung ~ 1/f. DC und alles unter 10 Hz weg,
    # damit kein Tieffrequenz-Muell die Lautsprecher belastet.
    shape = np.zeros_like(freqs)
    valid = freqs >= 10.0
    shape[valid] = 1.0 / np.sqrt(freqs[valid])
    pink = np.fft.irfft(spec * shape, n=n)
    # Ein-/Ausblenden 100 ms gegen Knacken
    n_f = int(0.1 * fs)
    ramp = 0.5 - 0.5 * np.cos(np.pi * np.arange(n_f) / n_f)
    pink[:n_f] *= ramp
    pink[-n_f:] *= ramp[::-1]
    # RMS auf Zielpegel, Spitzen auf -1 dBFS begrenzen (weiches Clipping ist hier
    # unnoetig: rosa Rauschen hat Crest-Faktor ~ 4, also ~12 dB -> passt zu -12 dBFS RMS)
    pink *= 10 ** (PINK_LEVEL_DBFS / 20) / np.sqrt(np.mean(pink ** 2))
    peak = np.max(np.abs(pink))
    limit = 10 ** (-1.0 / 20)
    if peak > limit:
        pink *= limit / peak
    return pink


# ---- WAV schreiben --------------------------------------------------------
def write_wav_24bit(path: Path, x: np.ndarray, fs: int = SAMPLE_RATE) -> None:
    x = np.clip(x, -1.0, 1.0)
    ints = np.round(x * (2 ** 23 - 1)).astype(np.int32)
    # 24 Bit little endian: die unteren drei Bytes jedes int32
    data = ints.astype("<i4").view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(3)
        w.setframerate(fs)
        w.writeframes(data)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    sweep = make_sweep_file_signal()
    write_wav_24bit(OUT_DIR / "sweep_20-20k_10s.wav", sweep)
    write_wav_24bit(OUT_DIR / "sweep_20-4k_schonend.wav", make_sweep_file_signal(stop_hz=4000.0))

    pink = make_pink_noise()
    write_wav_24bit(OUT_DIR / "pink_noise_60s.wav", pink)

    ref = {
        "sampleRate": SAMPLE_RATE,
        "sweep": {
            "type": "exponential",
            "f1": SWEEP_F1, "f2": SWEEP_F2, "duration": SWEEP_DURATION,
            "fadeIn": SWEEP_FADE_IN, "fadeOut": SWEEP_FADE_OUT,
            "levelDbfs": SWEEP_LEVEL_DBFS, "silenceBefore": SWEEP_SILENCE,
            "silenceAfter": SWEEP_SILENCE,
        },
        "pink": {"duration": PINK_DURATION, "rmsDbfs": PINK_LEVEL_DBFS, "seed": PINK_SEED},
    }
    (OUT_DIR / "sweep_reference.json").write_text(json.dumps(ref, indent=2), encoding="utf-8")

    for name in ("sweep_20-20k_10s.wav", "sweep_20-4k_schonend.wav", "pink_noise_60s.wav", "sweep_reference.json"):
        p = OUT_DIR / name
        print(f"{p.name:26s} {p.stat().st_size / 1e6:6.2f} MB")
    print(f"Sweep: Spitze {20*np.log10(np.max(np.abs(sweep))):.1f} dBFS, "
          f"Pink: RMS {20*np.log10(np.sqrt(np.mean(pink**2))):.1f} dBFS, "
          f"Spitze {20*np.log10(np.max(np.abs(pink))):.1f} dBFS")


if __name__ == "__main__":
    main()

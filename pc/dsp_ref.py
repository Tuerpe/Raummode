#!/usr/bin/env python3
"""Python-Referenz des Raummode-DSP.

Dieselben Schritte sind in app/RaummodeDSP (Swift) umgesetzt. Beide muessen
numerisch uebereinstimmen (Kreuzvergleich in pc/tests und Tests/RaummodeDSPTests).
Wer hier etwas aendert, aendert es auch dort.

Pipeline Sweep-Messung:
  Aufnahme (15 s, 48 kHz, mono, Float)
    -> find_sweep        : Offset des Sweeps per Kreuzkorrelation, Korrelationsguete
    -> deconvolve        : Faltung mit dem inversen Filter -> Impulsantwort (IR)
    -> window_ir         : 5 ms vor / 500 ms nach dem Direktschall, Fenster
    -> ir_to_fr          : FFT (65536) -> Frequenzgang in dB (relativ)
    -> smooth_fractional_octave (1/6 Oktave)
    -> interpolate_log   : auf Log-Raster 48 Punkte/Oktave, 20 Hz .. 20 kHz
    -> normalize         : Mittel 300 Hz .. 3 kHz = 0 dB
Pipeline RTA:
  Pink-Noise-Aufnahme -> rta_third_octave (Welch, 1/3-Oktav-Baender IEC 61260)

Nur numpy. Konstanten kommen aus gen_signals.py.
"""
from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_signals import (SAMPLE_RATE, SWEEP_DURATION, SWEEP_F1, SWEEP_F2,  # noqa: E402
                         make_pink_noise, make_sweep)

FS = SAMPLE_RATE
N_SWEEP = int(round(SWEEP_DURATION * FS))
RECORD_SECONDS = 15.0

# Deconvolution: Ausschnitt um den gefundenen Sweep, spart FFT-Laenge
PRE_ROLL = 4800            # 0,1 s vor dem Sweep
POST_ROLL = 48000          # 1,0 s nach dem Sweep (Nachhall)
PEAK_SEARCH = 480          # +-10 ms um den erwarteten Direktschall

WINDOW_PRE_MS = 5.0
WINDOW_POST_MS = 500.0
NFFT_FR = 65536

GRID_POINTS_PER_OCTAVE = 48
GRID_F1 = 20.0
GRID_F2 = 20000.0
NORM_LO = 300.0
NORM_HI = 3000.0
DEFAULT_SMOOTHING = 6      # 1/6 Oktave

THIRD_OCTAVE_NOMINAL = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315,
                        400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000,
                        5000, 6300, 8000, 10000, 12500, 16000, 20000]
THIRD_OCTAVE_EXACT = 1000.0 * 2.0 ** (np.arange(-17, 14) / 3.0)
RTA_NPERSEG = 32768


# ---- Grundfunktionen ----------------------------------------------------
def next_pow2(n: int) -> int:
    p = 1
    while p < n:
        p <<= 1
    return p


def fft_convolve(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Lineare Faltung, Laenge len(a)+len(b)-1."""
    n = next_pow2(len(a) + len(b) - 1)
    return np.fft.irfft(np.fft.rfft(a, n) * np.fft.rfft(b, n), n)[: len(a) + len(b) - 1]


def cross_correlate(x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """r[k] = sum_n x[n+k] * y[n] fuer k = 0 .. len(x)-1."""
    n = next_pow2(len(x) + len(y))
    r = np.fft.irfft(np.fft.rfft(x, n) * np.conj(np.fft.rfft(y, n)), n)
    return r[: len(x)]


@lru_cache(maxsize=1)
def reference_sweep() -> np.ndarray:
    return make_sweep(FS)


@lru_cache(maxsize=1)
def make_inverse_filter() -> np.ndarray:
    """Zeitumgekehrter Sweep mit 6 dB/Oktave-Huellkurve (Farina), normiert so,
    dass sweep * inverse eine Spitze von genau 1.0 hat."""
    s = reference_sweep()
    n = len(s)
    L = np.log(SWEEP_F2 / SWEEP_F1)
    env = np.exp(-np.arange(n) * L / n)
    inv = s[::-1] * env
    c = fft_convolve(s, inv)
    return inv / np.max(np.abs(c))


# ---- Sweep-Pipeline -----------------------------------------------------
def find_sweep(recording: np.ndarray) -> tuple[int, float]:
    """Offset (Samples) des Sweep-Anfangs in der Aufnahme und normierte
    Korrelationshoehe (1.0 = identisch, < 0.3 = vermutlich kein Sweep)."""
    s = reference_sweep()
    r = cross_correlate(recording, s)
    max_lag = max(1, len(recording) - len(s) + 1) if len(recording) >= len(s) else len(recording)
    k = int(np.argmax(np.abs(r[:max_lag])))
    seg = recording[k: k + len(s)]
    denom = np.linalg.norm(seg) * np.linalg.norm(s[: len(seg)]) + 1e-20
    return k, float(abs(r[k]) / denom)


def deconvolve(recording: np.ndarray, offset: int) -> tuple[np.ndarray, int]:
    """Impulsantwort des Ausschnitts um den Sweep und Index des Direktschall-Maximums."""
    inv = make_inverse_filter()
    a = max(0, offset - PRE_ROLL)
    b = min(len(recording), offset + N_SWEEP + POST_ROLL)
    seg = recording[a:b]
    ir = fft_convolve(seg, inv)
    expected = (offset - a) + N_SWEEP - 1
    lo = max(0, expected - PEAK_SEARCH)
    hi = min(len(ir), expected + PEAK_SEARCH)
    peak = lo + int(np.argmax(np.abs(ir[lo:hi])))
    return ir, peak


def window_ir(ir: np.ndarray, peak: int, pre_ms: float = WINDOW_PRE_MS,
              post_ms: float = WINDOW_POST_MS, fs: int = FS) -> np.ndarray:
    pre = int(round(pre_ms / 1000 * fs))
    post = int(round(post_ms / 1000 * fs))
    out = np.zeros(pre + post)
    start = peak - pre
    src_lo = max(0, start)
    src_hi = min(len(ir), start + pre + post)
    out[src_lo - start: src_hi - start] = ir[src_lo:src_hi]
    w = np.ones(pre + post)
    i = np.arange(pre)
    w[:pre] = 0.5 - 0.5 * np.cos(np.pi * i / pre)
    tail = int(round(0.1 * post))
    j = np.arange(tail)
    w[pre + post - tail:] = 0.5 + 0.5 * np.cos(np.pi * j / tail)
    return out * w


def ir_to_fr(ir_windowed: np.ndarray, nfft: int = NFFT_FR, fs: int = FS) -> tuple[np.ndarray, np.ndarray]:
    H = np.fft.rfft(ir_windowed, nfft)
    freq = np.fft.rfftfreq(nfft, 1 / fs)
    db = 20 * np.log10(np.abs(H) + 1e-12)
    return freq, db


def smooth_fractional_octave(freq: np.ndarray, db: np.ndarray, fraction: int) -> np.ndarray:
    """Leistungsmittel ueber [f / 2^(1/2n), f * 2^(1/2n)], freq aufsteigend."""
    p = 10 ** (db / 10)
    c = np.concatenate([[0.0], np.cumsum(p)])
    half = 2 ** (1 / (2 * fraction))
    lo = np.searchsorted(freq, freq / half, side="left")
    hi = np.searchsorted(freq, freq * half, side="right")
    hi = np.maximum(hi, lo + 1)
    return 10 * np.log10((c[hi] - c[lo]) / (hi - lo) + 1e-30)


def log_grid(points_per_octave: int = GRID_POINTS_PER_OCTAVE,
             f1: float = GRID_F1, f2: float = GRID_F2) -> np.ndarray:
    n = int(np.floor(points_per_octave * np.log2(f2 / f1) + 1e-9))
    return f1 * 2.0 ** (np.arange(n + 1) / points_per_octave)


def interpolate_log(freq: np.ndarray, db: np.ndarray, grid: np.ndarray) -> np.ndarray:
    m = freq > 0
    return np.interp(np.log(grid), np.log(freq[m]), db[m])


def normalize(freq: np.ndarray, db: np.ndarray, lo: float = NORM_LO, hi: float = NORM_HI) -> np.ndarray:
    m = (freq >= lo) & (freq <= hi)
    return db - np.mean(db[m])


def power_average(curves) -> np.ndarray:
    arr = np.asarray(curves, dtype=float)
    return 10 * np.log10(np.mean(10 ** (arr / 10), axis=0))


def db_rms(x: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12))


def analyze_sweep_recording(recording: np.ndarray, smoothing: int = DEFAULT_SMOOTHING) -> dict:
    """Komplette Pipeline. Liefert Kurve auf dem Log-Raster (normiert) plus Qualitaet."""
    recording = np.asarray(recording, dtype=float)
    offset, corr = find_sweep(recording)
    ir, peak = deconvolve(recording, offset)
    irw = window_ir(ir, peak)
    freq, db = ir_to_fr(irw)
    sm = smooth_fractional_octave(freq, db, smoothing)
    grid = log_grid()
    curve = normalize(grid, interpolate_log(freq, sm, grid))

    sig = recording[offset: offset + N_SWEEP]
    if offset >= FS:
        noise = recording[offset - FS: offset]
    elif offset + N_SWEEP + FS // 2 + FS <= len(recording):
        noise = recording[offset + N_SWEEP + FS // 2: offset + N_SWEEP + FS // 2 + FS]
    else:
        noise = None
    snr = db_rms(sig) - db_rms(noise) if noise is not None and len(noise) > 0 else float("nan")
    quality = {
        "offset": int(offset),
        "corr": float(corr),
        "peakDbfs": float(20 * np.log10(np.max(np.abs(recording)) + 1e-12)),
        "snrDb": float(snr),
    }
    return {"freq": grid, "db": curve, "quality": quality,
            "rawFreq": freq, "rawDb": db, "ir": irw}


# ---- RTA ----------------------------------------------------------------
def welch_psd(x: np.ndarray, nperseg: int = RTA_NPERSEG, fs: int = FS) -> tuple[np.ndarray, np.ndarray]:
    """Einseitige Leistungsdichte, Hann, 50 % Ueberlappung."""
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(nperseg) / nperseg)
    step = nperseg // 2
    n_frames = max(1, (len(x) - nperseg) // step + 1)
    acc = np.zeros(nperseg // 2 + 1)
    for i in range(n_frames):
        seg = x[i * step: i * step + nperseg]
        if len(seg) < nperseg:
            seg = np.pad(seg, (0, nperseg - len(seg)))
        acc += np.abs(np.fft.rfft(seg * w)) ** 2
    psd = acc / n_frames * 2.0 / (fs * np.sum(w ** 2))
    psd[0] /= 2
    psd[-1] /= 2
    return np.fft.rfftfreq(nperseg, 1 / fs), psd


def rta_third_octave(x: np.ndarray, fs: int = FS) -> tuple[list, np.ndarray]:
    """Pegel je 1/3-Oktav-Band (dB, relativ zu Vollaussteuerung)."""
    f, psd = welch_psd(np.asarray(x, dtype=float), fs=fs)
    df = f[1] - f[0]
    edge = 2 ** (1 / 6)
    out = np.empty(len(THIRD_OCTAVE_EXACT))
    for i, fc in enumerate(THIRD_OCTAVE_EXACT):
        m = (f >= fc / edge) & (f < fc * edge)
        out[i] = 10 * np.log10(np.sum(psd[m]) * df + 1e-30)
    return THIRD_OCTAVE_NOMINAL, out


# ---- Biquad (fuer Tests und Simulation, identisch mit Equalizer APO "PK") ---
def peaking_coeffs(fc: float, gain_db: float, q: float, fs: int = FS) -> tuple[np.ndarray, np.ndarray]:
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / fs
    alpha = np.sin(w0) / (2 * q)
    b = np.array([1 + alpha * A, -2 * np.cos(w0), 1 - alpha * A])
    a = np.array([1 + alpha / A, -2 * np.cos(w0), 1 - alpha / A])
    return b / a[0], a / a[0]


def biquad_response_db(freq: np.ndarray, b: np.ndarray, a: np.ndarray, fs: int = FS) -> np.ndarray:
    z = np.exp(-1j * 2 * np.pi * freq / fs)
    H = (b[0] + b[1] * z + b[2] * z ** 2) / (a[0] + a[1] * z + a[2] * z ** 2)
    return 20 * np.log10(np.abs(H) + 1e-12)


def apply_biquad(x: np.ndarray, b: np.ndarray, a: np.ndarray) -> np.ndarray:
    from scipy.signal import lfilter
    return lfilter(b, a, x)


__all__ = [name for name in dir() if not name.startswith("_")]

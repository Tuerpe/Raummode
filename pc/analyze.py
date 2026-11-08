#!/usr/bin/env python3
"""Raummode-Analyse: Messungen (JSON der iPhone-App) -> Equalizer-APO-Vorschlag.

Aufruf:
  python pc/analyze.py messungen/2026-11-15 [--target raumkurve|flach|harman|<datei>]
                                            [--max-filters 10] [--mic-cal mic.frd]
                                            [--out messungen/2026-11-15/analyse]

Schritte:
  1. alle *.json im Ordner lesen (Schema 1), jede Position auf das Log-Raster
     (48 Punkte/Oktave, 20 Hz .. 20 kHz) interpolieren, optional Mikro-Korrektur abziehen
  2. Leistungsmittel ueber alle Positionen, Glaettung 1/6 Oktave unter 300 Hz,
     1/3 Oktave darueber, Pegelreferenz 300 Hz .. 3 kHz = 0 dB
  3. Zielkurve laden (pc/targets/*.txt), gleich normiert
  4. Greedy-Auto-EQ mit parametrischen Peaking-Filtern (EQ-APO-"PK"-Formeln):
       20 .. 300 Hz : Q bis 10, Absenkungen bevorzugt, Anhebung max. +3 dB, unter 30 Hz keine Anhebung
       300 Hz .. 16 kHz : Q <= 1,5, |Gain| <= 4 dB
  5. Ausgabe: eqapo_vorschlag.txt, bericht.md, plot.png

Die Entscheidung, was uebernommen wird, bleibt beim Menschen. Das Skript schlaegt vor.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import dsp_ref as d  # noqa: E402

GRID = d.log_grid()
TARGETS_DIR = HERE / "targets"

BASS_LIMIT = 300.0
EQ_LO, EQ_HI = 20.0, 16000.0
NO_BOOST_BELOW = 30.0
BASS_Q = (0.5, 10.0)
BASS_GAIN = (-15.0, 3.0)
TREBLE_Q = (0.3, 1.5)
TREBLE_GAIN = (-4.0, 4.0)
STOP_RMS_DB = 1.0
MIN_IMPROVEMENT_DB = 0.05
MIN_GAIN_DB = 0.4


# ---- Laden ----------------------------------------------------------------
def load_positions(folder: Path) -> tuple[list[dict], list[str]]:
    positions, warnings = [], []
    files = sorted(folder.glob("*.json"))
    if not files:
        raise SystemExit(f"Keine JSON-Dateien in {folder}")
    for f in files:
        try:
            m = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            warnings.append(f"{f.name}: nicht lesbar ({e})")
            continue
        if m.get("schema") != 1 or "positions" not in m:
            warnings.append(f"{f.name}: kein Raummode-Schema 1, uebersprungen")
            continue
        for p in m["positions"]:
            freq = np.asarray(p["freq"], float)
            db = np.asarray(p["db"], float)
            if len(freq) != len(db) or len(freq) < 8:
                warnings.append(f"{f.name}/{p.get('name')}: ungueltige Kurve, uebersprungen")
                continue
            positions.append({
                "file": f.name, "session": m.get("session", f.stem), "name": p.get("name", "?"),
                "mode": p.get("mode", "sweep"), "quality": p.get("quality", {}),
                "device": m.get("device", "?"), "created": m.get("created", "?"),
                "grid_db": d.interpolate_log(freq, db, GRID),
            })
    if not positions:
        raise SystemExit("Keine verwertbaren Positionen gefunden.")
    return positions, warnings


def load_two_column(path: Path) -> np.ndarray:
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip().replace(",", ".")
        if not s or s[0] in "#;*/":
            continue
        parts = s.replace("\t", " ").split()
        try:
            rows.append((float(parts[0]), float(parts[1])))
        except (ValueError, IndexError):
            continue
    if len(rows) < 2:
        raise SystemExit(f"{path}: keine Hz/dB-Paare gefunden")
    arr = np.array(sorted(rows))
    return d.interpolate_log(arr[:, 0], arr[:, 1], GRID)


def load_target(name_or_path: str) -> tuple[np.ndarray, str]:
    p = Path(name_or_path)
    if not p.exists():
        p = TARGETS_DIR / f"{name_or_path}.txt"
    if not p.exists():
        avail = ", ".join(sorted(x.stem for x in TARGETS_DIR.glob("*.txt")))
        raise SystemExit(f"Zielkurve '{name_or_path}' nicht gefunden. Verfuegbar: {avail}")
    return d.normalize(GRID, load_two_column(p)), p.stem


# ---- Aufbereitung ----------------------------------------------------------
def smooth_mixed(db: np.ndarray) -> np.ndarray:
    """1/6 Oktave unter 300 Hz, 1/3 Oktave darueber, weicher Uebergang 200..450 Hz."""
    s6 = d.smooth_fractional_octave(GRID, db, 6)
    s3 = d.smooth_fractional_octave(GRID, db, 3)
    w = np.clip((np.log2(GRID) - np.log2(200)) / (np.log2(450) - np.log2(200)), 0, 1)
    return (1 - w) * s6 + w * s3


def prepare(positions: list[dict], mic_cal: np.ndarray | None) -> tuple[np.ndarray, list[np.ndarray]]:
    curves = []
    for p in positions:
        c = p["grid_db"] - (mic_cal if mic_cal is not None else 0)
        curves.append(d.normalize(GRID, smooth_mixed(c)))
    mean = d.normalize(GRID, smooth_mixed(d.power_average([p["grid_db"] for p in positions])
                                          - (mic_cal if mic_cal is not None else 0)))
    return mean, curves


# ---- Auto-EQ ---------------------------------------------------------------
def filter_response(fc: float, gain: float, q: float) -> np.ndarray:
    b, a = d.peaking_coeffs(fc, gain, q)
    return d.biquad_response_db(GRID, b, a)


def eq_curve(filters: list[tuple[float, float, float]]) -> np.ndarray:
    out = np.zeros_like(GRID)
    for fc, g, q in filters:
        out += filter_response(fc, g, q)
    return out


def weights() -> np.ndarray:
    w = np.where((GRID >= EQ_LO) & (GRID <= EQ_HI), 1.0, 0.0)
    w[GRID < BASS_LIMIT] *= 2.0          # Raummoden sind das Hauptziel
    return w


def rms_error(resid: np.ndarray, w: np.ndarray) -> float:
    return float(np.sqrt(np.sum(w * resid ** 2) / np.sum(w)))


def fit_one(resid: np.ndarray, w: np.ndarray, fc0: float) -> tuple[float, float, float]:
    """Optimiert (fc, gain, q) eines Peaking-Filters gegen das gewichtete Residuum."""
    from scipy.optimize import minimize
    bass = fc0 < BASS_LIMIT
    qb = BASS_Q if bass else TREBLE_Q
    gb = list(BASS_GAIN if bass else TREBLE_GAIN)
    if fc0 < NO_BOOST_BELOW:
        gb[1] = 0.0
    i0 = int(np.argmin(np.abs(GRID - fc0)))
    g0 = float(np.clip(-resid[i0], gb[0], gb[1]))
    q0 = float(np.clip(estimate_q(resid, i0), qb[0], qb[1]))
    lf_lo, lf_hi = np.log2(fc0) - 1 / 3, np.log2(fc0) + 1 / 3
    lf_lo = max(lf_lo, np.log2(EQ_LO))
    lf_hi = min(lf_hi, np.log2(EQ_HI))
    if bass:
        lf_hi = min(lf_hi, np.log2(BASS_LIMIT))
        # Das Fenster darf die 30-Hz-Grenze nicht ueberschreiten, sonst wandert ein
        # Anhebungs-Filter von oben unter 30 Hz (dort gilt: keine Anhebung).
        if fc0 >= NO_BOOST_BELOW:
            lf_lo = max(lf_lo, np.log2(NO_BOOST_BELOW))
        else:
            lf_hi = min(lf_hi, np.log2(NO_BOOST_BELOW))
    else:
        lf_lo = max(lf_lo, np.log2(BASS_LIMIT))

    def cost(x):
        fc, g, q = 2 ** x[0], x[1], x[2]
        return np.sum(w * (resid + filter_response(fc, g, q)) ** 2)

    # Mehrere Startwerte fuer Q: der Optimierer bleibt sonst gern in der Naehe des Starts haengen
    best = None
    for qs in {q0, max(qb[0], q0 / 2), min(qb[1], q0 * 2)}:
        res = minimize(cost, x0=[np.log2(fc0), g0, qs], method="L-BFGS-B",
                       bounds=[(lf_lo, lf_hi), tuple(gb), qb])
        if best is None or res.fun < best.fun:
            best = res
    fc, g, q = 2 ** best.x[0], best.x[1], best.x[2]
    return float(fc), float(g), float(q)


def estimate_q(resid: np.ndarray, i0: int) -> float:
    """Q aus der Breite der Abweichung um i0: Bereich, in dem |resid| >= halbe Spitze bleibt."""
    peak = abs(resid[i0])
    if peak < 1e-6:
        return 2.0
    lo = i0
    while lo > 0 and abs(resid[lo - 1]) >= peak / 2 and np.sign(resid[lo - 1]) == np.sign(resid[i0]):
        lo -= 1
    hi = i0
    while hi < len(resid) - 1 and abs(resid[hi + 1]) >= peak / 2 and np.sign(resid[hi + 1]) == np.sign(resid[i0]):
        hi += 1
    bw = GRID[hi] - GRID[lo]
    return GRID[i0] / bw if bw > 0 else 10.0


def refine_jointly(filters: list[tuple[float, float, float]], resid0: np.ndarray, w: np.ndarray) -> list[tuple[float, float, float]]:
    """Alle Filter gemeinsam nachoptimieren (Greedy laesst Reste zwischen benachbarten Filtern).
    Grenzen je Filter wie beim Einzelfit; Ergebnis wird nur uebernommen, wenn es die
    Summen-Anhebung einhaelt und besser ist."""
    from scipy.optimize import minimize
    if len(filters) < 2:
        return filters
    x0, bounds = [], []
    for fc, g, q in filters:
        bass = fc < BASS_LIMIT
        qb = BASS_Q if bass else TREBLE_Q
        gb = list(BASS_GAIN if bass else TREBLE_GAIN)
        if fc < NO_BOOST_BELOW:
            gb[1] = 0.0
        lo = max(np.log2(fc) - 1 / 6, np.log2(EQ_LO), np.log2(BASS_LIMIT) if not bass else -np.inf)
        hi = min(np.log2(fc) + 1 / 6, np.log2(EQ_HI), np.log2(BASS_LIMIT) if bass else np.inf)
        if bass:
            if fc >= NO_BOOST_BELOW:
                lo = max(lo, np.log2(NO_BOOST_BELOW))
            else:
                hi = min(hi, np.log2(NO_BOOST_BELOW))
        x0 += [np.log2(fc), g, q]
        bounds += [(lo, hi), tuple(gb), qb]

    def unpack(x):
        return [(2 ** x[3 * k], x[3 * k + 1], x[3 * k + 2]) for k in range(len(filters))]

    def cost(x):
        return np.sum(w * (resid0 + eq_curve(unpack(x))) ** 2)

    res = minimize(cost, x0=x0, method="L-BFGS-B", bounds=bounds, options={"maxiter": 200})
    new = unpack(res.x)
    cap = np.where(GRID < BASS_LIMIT, BASS_GAIN[1], TREBLE_GAIN[1])
    if res.fun < cost(np.array(x0)) and np.all(eq_curve(new) <= cap + 0.05):
        return [(float(fc), float(g), float(q)) for fc, g, q in new]
    return filters


def limit_total_boost(eq_so_far: np.ndarray, fc: float, g: float, q: float) -> float:
    """Reduziert g so, dass die Summe aller Anhebungen die Grenzen einhaelt
    (Bass: BASS_GAIN[1], darueber TREBLE_GAIN[1]). Einzelne Filter duerfen sich
    nicht zu einer groesseren Anhebung stapeln."""
    if g <= 0:
        return g
    # Die "keine Anhebung unter 30 Hz"-Regel gilt pro Filter (fit_one); die Summe darf
    # dort durch Auslaeufer breiter Filter minimal positiv werden, das ist harmlos.
    cap = np.where(GRID < BASS_LIMIT, BASS_GAIN[1], TREBLE_GAIN[1])
    lo, hi = 0.0, g
    for _ in range(20):
        mid = (lo + hi) / 2
        if np.all(eq_so_far + filter_response(fc, mid, q) <= cap + 1e-6):
            lo = mid
        else:
            hi = mid
    return lo


def auto_eq(meas: np.ndarray, target: np.ndarray, max_filters: int) -> tuple[list[tuple[float, float, float]], list[dict]]:
    w = weights()
    filters: list[tuple[float, float, float]] = []
    log: list[dict] = []
    resid = meas - target
    blocked = np.zeros_like(GRID, dtype=bool)      # Kandidatenbereiche, die nichts gebracht haben
    tries = 0
    while len(filters) < max_filters and tries < 3 * max_filters:
        tries += 1
        before = rms_error(resid, w)
        if before < STOP_RMS_DB:
            break
        # Kandidat: groesste gewichtete Abweichung, leicht geglaettet gegen Ausreisser
        cand = d.smooth_fractional_octave(GRID, np.abs(resid), 3) * w
        cand[blocked] = 0
        if cand.max() <= 0:
            break
        i = int(np.argmax(cand))
        fc0 = float(GRID[i])
        fc, g, q = fit_one(resid, w, fc0)
        g = limit_total_boost(eq_curve(filters), fc, g, q)
        new_resid = resid + filter_response(fc, g, q)
        after = rms_error(new_resid, w)
        if abs(g) < MIN_GAIN_DB or before - after < MIN_IMPROVEMENT_DB:
            blocked |= np.abs(np.log2(GRID / fc0)) < 1 / 6   # +-1/6 Oktave sperren, weiter suchen
            continue
        j = int(np.argmin(np.abs(GRID - fc)))
        log.append({"fc": fc, "gain": g, "q": q, "resid_before_at_fc": float(resid[j]),
                    "resid_after_at_fc": float(new_resid[j]), "rms_before": before, "rms_after": after})
        filters.append((fc, g, q))
        resid = new_resid

    # Gemeinsame Nachoptimierung; Filter mit |Gain| < MIN_GAIN_DB danach entfernen
    resid0 = meas - target
    refined = refine_jointly(filters, resid0, w)
    final_resid = resid0 + eq_curve(refined)
    out = []
    for (fc, g, q), lg in zip(refined, log):
        if abs(g) < MIN_GAIN_DB:
            continue
        j = int(np.argmin(np.abs(GRID - fc)))
        lg = dict(lg, fc=fc, gain=g, q=q, resid_before_at_fc=float(resid0[j]),
                  resid_after_at_fc=float(final_resid[j]))
        out.append(((fc, g, q), lg))
    out.sort(key=lambda t: t[0][0])
    return [f for f, _ in out], [l for _, l in out]


def preamp_db(eq: np.ndarray) -> float:
    return -max(0.0, float(np.max(eq))) - 1.0


# ---- Berichte --------------------------------------------------------------
OCTAVE_BANDS = [(20, 40), (40, 80), (80, 160), (160, 315), (315, 630), (630, 1250),
                (1250, 2500), (2500, 5000), (5000, 10000), (10000, 16000)]


def band_table(resid_before: np.ndarray, resid_after: np.ndarray) -> list[tuple[str, float, float]]:
    rows = []
    for lo, hi in OCTAVE_BANDS:
        m = (GRID >= lo) & (GRID < hi)
        rows.append((f"{lo}–{hi} Hz", float(np.sqrt(np.mean(resid_before[m] ** 2))),
                     float(np.sqrt(np.mean(resid_after[m] ** 2)))))
    return rows


def quality_warnings(positions: list[dict], curves: list[np.ndarray]) -> list[str]:
    out = []
    for p in positions:
        q = p.get("quality") or {}
        tag = f"{p['file']} / {p['name']}"
        if p["mode"] == "sweep":
            if q.get("corr", 1) is not None and q.get("corr", 1) < 0.2:
                out.append(f"{tag}: Sweep schwach erkannt (corr {q.get('corr'):.2f}) – Messung wiederholen?")
            if q.get("snrDb", 99) is not None and 0 <= q.get("snrDb", 99) < 20:
                out.append(f"{tag}: geringer Stoerabstand ({q.get('snrDb'):.0f} dB) – lauter messen")
        if q.get("peakDbfs", -99) is not None and q.get("peakDbfs", -99) > -1:
            out.append(f"{tag}: Aufnahme uebersteuert ({q.get('peakDbfs'):.1f} dBFS)")
    if len(curves) > 1:
        arr = np.array(curves)
        m = (GRID >= 20) & (GRID <= BASS_LIMIT)
        spread = np.max(arr[:, m], axis=0) - np.min(arr[:, m], axis=0)
        if spread.max() > 6:
            f = GRID[m][int(np.argmax(spread))]
            out.append(f"Positionen weichen im Bass stark voneinander ab (bis {spread.max():.1f} dB bei {f:.0f} Hz): "
                       f"Korrektur dort nur moderat sinnvoll, Mittel ist ein Kompromiss")
    return out


def write_eqapo(path: Path, filters, pre: float, source: str, target_name: str) -> None:
    lines = [
        "# Equalizer APO - Vorschlag aus Raummode-Messung",
        f"# Erzeugt: {dt.datetime.now():%Y-%m-%d %H:%M}   Quelle: {source}   Zielkurve: {target_name}",
        "# Uebernahme: Inhalt nach C:\\Tools\\EQ_APO\\config\\config.txt kopieren",
        "#   oder: pc\\eqapo_toggle.ps1 -Modus EQ -Datei <diese Datei>",
        "# Vorher die bisherige GraphicEQ-Zeile entfernen - dieser Block ersetzt sie.",
        f"Preamp: {pre:.1f} dB",
    ]
    for n, (fc, g, q) in enumerate(filters, 1):
        lines.append(f"Filter {n}: ON PK Fc {fc:.1f} Hz Gain {g:.1f} dB Q {q:.2f}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_report(path: Path, positions, log, filters, pre, meas, target, eq, warns, target_name) -> None:
    resid_b = meas - target
    resid_a = meas + eq - target
    w = weights()
    L = [f"# Raummode-Analyse – {dt.datetime.now():%d.%m.%Y %H:%M}", ""]
    L += [f"Zielkurve: **{target_name}**  ·  Positionen: {len(positions)}  ·  "
          f"Geraet: {positions[0]['device']}  ·  Sessions: {', '.join(sorted({p['session'] for p in positions}))}", ""]
    L += ["## Positionen", "", "| Datei | Position | Modus | corr | SNR dB | Spitze dBFS |", "|---|---|---|---|---|---|"]
    for p in positions:
        q = p.get("quality") or {}
        fmt = lambda k, f: (f % q[k]) if q.get(k) is not None else "–"  # noqa: E731
        L.append(f"| {p['file']} | {p['name']} | {p['mode']} | {fmt('corr', '%.2f')} | {fmt('snrDb', '%.0f')} | {fmt('peakDbfs', '%.1f')} |")
    L += ["", "## Vorschlag", "", f"`Preamp: {pre:.1f} dB`", "",
          "| # | Fc (Hz) | Gain (dB) | Q | Abweichung vorher | nachher | Begruendung |", "|---|---|---|---|---|---|---|"]
    for n, ((fc, g, q), lg) in enumerate(zip(filters, log), 1):
        kind = "Raummode absenken" if (fc < BASS_LIMIT and g < 0) else ("Bass-Einbruch leicht anheben" if fc < BASS_LIMIT else
                                                                      ("breite Senke" if g < 0 else "breite Anhebung"))
        L.append(f"| {n} | {fc:.1f} | {g:+.1f} | {q:.2f} | {lg['resid_before_at_fc']:+.1f} dB | {lg['resid_after_at_fc']:+.1f} dB | {kind} |")
    L += ["", f"Gewichteter RMS-Fehler: **{rms_error(resid_b, w):.2f} dB → {rms_error(resid_a, w):.2f} dB**", "",
          "## Restfehler je Band (RMS)", "", "| Band | vorher | nachher |", "|---|---|---|"]
    for name, b, a in band_table(resid_b, resid_a):
        L.append(f"| {name} | {b:.1f} dB | {a:.1f} dB |")
    L += ["", "## Hinweise", ""]
    L += [f"- {x}" for x in warns] if warns else ["- keine Auffaelligkeiten in den Qualitaetswerten"]
    L += ["- iPhone-Mikro: unter ~50 Hz und ueber ~15 kHz mit Vorsicht lesen (keine Kalibrierung).",
          "- Filter mit |Gain| < 1 dB kann man weglassen. Nach dem Einspielen nachmessen.", ""]
    path.write_text("\n".join(L), encoding="utf-8")


def write_plot(path: Path, curves, positions, meas, target, eq, filters, target_name) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 8.5), sharex=True,
                                   gridspec_kw={"height_ratios": [3, 1.4]})
    for c, p in zip(curves, positions):
        ax1.semilogx(GRID, c, lw=0.8, alpha=0.45, label=p["name"])
    ax1.semilogx(GRID, meas, "k", lw=2.2, label="Mittel (geglaettet)")
    ax1.semilogx(GRID, target, "g--", lw=1.4, label=f"Ziel: {target_name}")
    ax1.semilogx(GRID, meas + eq, "r", lw=1.8, label="Mittel mit EQ (simuliert)")
    ax1.axvspan(20, 50, color="orange", alpha=0.08)
    ax1.set_ylabel("dB (rel. 300 Hz–3 kHz)")
    ax1.set_ylim(-20, 20)
    ax1.grid(True, which="both", alpha=0.3)
    ax1.legend(fontsize=8, ncol=2, loc="upper right")
    ax1.set_title("Raummode – Frequenzgang am Hoerplatz")
    for fc, g, q in filters:
        ax2.semilogx(GRID, filter_response(fc, g, q), lw=0.8, alpha=0.5)
    ax2.semilogx(GRID, eq, "r", lw=2, label="EQ gesamt")
    ax2.set_ylabel("EQ dB")
    ax2.set_xlabel("Hz")
    ax2.set_xlim(20, 20000)
    ax2.set_xticks([20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000])
    ax2.set_xticklabels(["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"])
    ax2.grid(True, which="both", alpha=0.3)
    ax2.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)


# ---- main ------------------------------------------------------------------
def run(folder: Path, target: str = "raumkurve", max_filters: int = 10,
        mic_cal: Path | None = None, out: Path | None = None) -> dict:
    positions, warns = load_positions(folder)
    cal = load_two_column(mic_cal) if mic_cal else None
    meas, curves = prepare(positions, cal)
    tgt, tgt_name = load_target(target)
    filters, log = auto_eq(meas, tgt, max_filters)
    eq = eq_curve(filters)
    pre = preamp_db(eq)
    warns += quality_warnings(positions, curves)

    out = out or (folder / "analyse")
    out.mkdir(parents=True, exist_ok=True)
    write_eqapo(out / "eqapo_vorschlag.txt", filters, pre, folder.name, tgt_name)
    write_report(out / "bericht.md", positions, log, filters, pre, meas, tgt, eq, warns, tgt_name)
    write_plot(out / "plot.png", curves, positions, meas, tgt, eq, filters, tgt_name)
    return {"filters": filters, "preamp": pre, "meas": meas, "target": tgt, "eq": eq,
            "warnings": warns, "out": out, "positions": positions}


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path, help="Ordner mit den JSON-Messungen")
    ap.add_argument("--target", default="raumkurve", help="raumkurve | flach | harman | Pfad zu Hz/dB-Datei")
    ap.add_argument("--max-filters", type=int, default=10)
    ap.add_argument("--mic-cal", type=Path, default=None, help="Mikrofon-Korrektur (Hz dB), wird abgezogen")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    r = run(a.folder, a.target, a.max_filters, a.mic_cal, a.out)
    print(f"Positionen: {len(r['positions'])}   Filter: {len(r['filters'])}   Preamp {r['preamp']:.1f} dB")
    for n, (fc, g, q) in enumerate(r["filters"], 1):
        print(f"  Filter {n}: ON PK Fc {fc:.1f} Hz Gain {g:+.1f} dB Q {q:.2f}")
    for w in r["warnings"]:
        print("  !", w)
    print(f"Ausgabe: {r['out']}")


if __name__ == "__main__":
    main()

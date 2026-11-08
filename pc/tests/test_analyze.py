"""pytest fuer pc/analyze.py mit synthetischen Messungen (Schema 1)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import analyze as an  # noqa: E402
import dsp_ref as d  # noqa: E402

FIX = HERE / "fixtures" / "analyze"
ROOM = [(42.0, 9.0, 8.0), (120.0, -6.0, 4.0)]


def make_fixtures(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    grid = d.log_grid()
    base = np.zeros_like(grid)
    for fc, g, q in ROOM:
        b, a = d.peaking_coeffs(fc, g, q)
        base += d.biquad_response_db(grid, b, a)
    rng = np.random.default_rng(11)
    positions = []
    for i, name in enumerate(["Hoerplatz", "links 30cm", "rechts 30cm"]):
        tilt = (i - 1) * 0.3 * np.log2(grid / 1000)          # leicht andere Neigung je Position
        noise = rng.normal(0, 0.4, len(grid))
        db = d.normalize(grid, base + tilt + noise)
        positions.append({"name": name, "mode": "sweep", "smoothing": "1/6",
                          "freq": [round(float(f), 3) for f in grid], "db": [round(float(v), 3) for v in db],
                          "quality": {"snrDb": 38.0, "peakDbfs": -12.0, "corr": 0.6, "offset": 60000}})
    m = {"schema": 1, "app": "Raummode", "device": "iPhone16,2", "ios": "18.1", "created": "2026-11-08T12:00:00Z",
         "session": "synthetisch", "sampleRate": 48000, "sweep": {"f1": 20, "f2": 20000, "duration": 10},
         "positions": positions, "average": None}
    (folder / "synthetisch.json").write_text(json.dumps(m), encoding="utf-8")


@pytest.fixture(scope="module")
def result(tmp_path_factory):
    if not (FIX / "synthetisch.json").exists():
        make_fixtures(FIX)
    out = tmp_path_factory.mktemp("analyse")
    return an.run(FIX, target="flach", max_filters=10, out=out)


def test_outputs_exist(result):
    out = result["out"]
    for name in ("eqapo_vorschlag.txt", "bericht.md", "plot.png"):
        assert (out / name).exists() and (out / name).stat().st_size > 0
    txt = (out / "eqapo_vorschlag.txt").read_text(encoding="utf-8")
    assert "Preamp:" in txt and "Filter 1: ON PK Fc" in txt


def test_finds_42hz_mode(result):
    cands = [f for f in result["filters"] if 36 <= f[0] <= 48]
    assert cands, f"kein Filter nahe 42 Hz, Filter: {result['filters']}"
    fc, g, q = max(cands, key=lambda f: -f[1])
    assert -11 <= g <= -6, f"Gain {g:.1f} dB unerwartet"
    assert q >= 3


def test_residual_small_after_eq(result):
    grid = d.log_grid()
    resid = result["meas"] + result["eq"] - result["target"]
    # Der -6-dB-Einbruch bei 120 Hz darf laut Regel nur um +3 dB angehoben werden,
    # dort bleiben also ~3 dB stehen. Ueberall sonst muss der Rest klein sein.
    dip = (grid >= 90) & (grid <= 160)
    m = (grid >= 40) & (grid <= 10000) & ~dip
    assert np.abs(resid[m]).max() < 1.5, f"Restfehler {np.abs(resid[m]).max():.2f} dB"
    i120 = int(np.argmin(np.abs(grid - 120)))
    assert -4.0 < resid[i120] < -1.5, f"120-Hz-Einbruch: Rest {resid[i120]:.2f} dB (erwartet ca. -3)"


def test_preamp_rule(result):
    eq = result["eq"]
    assert abs(result["preamp"] - (-max(0.0, eq.max()) - 1.0)) < 1e-6


def test_constraints(result):
    for fc, g, q in result["filters"]:
        assert an.EQ_LO <= fc <= an.EQ_HI
        if fc < an.BASS_LIMIT:
            assert an.BASS_GAIN[0] - 1e-6 <= g <= an.BASS_GAIN[1] + 1e-6
            assert q <= an.BASS_Q[1] + 1e-6
            if fc < an.NO_BOOST_BELOW:
                assert g <= 1e-6
        else:
            assert abs(g) <= an.TREBLE_GAIN[1] + 1e-6
            assert q <= an.TREBLE_Q[1] + 1e-6


def test_mic_cal_and_other_targets(tmp_path):
    if not (FIX / "synthetisch.json").exists():
        make_fixtures(FIX)
    cal = tmp_path / "mic.frd"
    cal.write_text("20 -3\n100 0\n20000 0\n", encoding="utf-8")
    for tgt in ("raumkurve", "harman"):
        r = an.run(FIX, target=tgt, max_filters=6, mic_cal=cal, out=tmp_path / tgt)
        assert (tmp_path / tgt / "plot.png").exists()
        assert len(r["filters"]) >= 1

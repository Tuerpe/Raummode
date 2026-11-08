"""pytest fuer pc/dsp_ref.py. Start: python -m pytest pc/tests -q"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import dsp_ref as d  # noqa: E402
import make_fixtures as mf  # noqa: E402


def test_inverse_filter_gives_clean_delta():
    s = d.reference_sweep()
    c = d.fft_convolve(s, d.make_inverse_filter())
    peak = int(np.argmax(np.abs(c)))
    assert abs(peak - (len(s) - 1)) <= 1
    assert abs(np.max(np.abs(c)) - 1.0) < 1e-9
    far = np.abs(np.concatenate([c[: peak - 2400], c[peak + 2400:]]))
    assert 20 * np.log10(far.max()) < -40, "Nebenmaxima der Entfaltung zu hoch"


@pytest.mark.parametrize("offset", [9600, 59256, 150001])
def test_find_sweep_offset(offset):
    rec = mf.synthetic_recording(offset=offset, seed=offset)
    # milder Nachhall dazu, damit die Suche nicht nur im Idealfall klappt
    rng = np.random.default_rng(1)
    tail = rng.standard_normal(int(0.3 * d.FS)) * np.exp(-np.arange(int(0.3 * d.FS)) / (0.05 * d.FS)) * 0.1
    rec = d.fft_convolve(rec, np.concatenate([[1.0], tail]))[: len(rec)]
    found, corr = d.find_sweep(rec)
    assert abs(found - offset) <= 2
    # Der Nachhall hier ist absichtlich extrem (Hallenergie ~11 dB ueber Direktschall);
    # die normierte Korrelation sinkt dann auf ~0,3. In der App gilt: > 0,2 brauchbar.
    assert corr > 0.2


def test_room_response_recovered():
    rec = mf.synthetic_recording()
    res = d.analyze_sweep_recording(rec)
    truth = mf.true_room_curve()
    grid = res["freq"]
    m = (grid >= 30) & (grid <= 15000)
    err = np.abs(res["db"][m] - truth[m])
    assert err.max() < 1.0, f"max. Abweichung {err.max():.2f} dB bei {grid[m][np.argmax(err)]:.0f} Hz"
    band = (grid >= 30) & (grid <= 60)
    f_peak = grid[band][np.argmax(res["db"][band])]
    assert abs(f_peak - 42.0) <= 2.0
    assert res["quality"]["snrDb"] > 30
    assert abs(res["quality"]["offset"] - mf.OFFSET) <= 2


def test_rta_pink_noise_is_flat():
    nominal, db = d.rta_third_octave(mf.d.make_pink_noise())
    assert len(nominal) == 31
    dev = db - np.median(db)
    assert np.abs(dev).max() < 1.5, f"Abweichung {np.abs(dev).max():.2f} dB"


def test_power_average_and_smoothing():
    assert abs(d.power_average([[0.0], [0.0]])[0]) < 1e-9
    assert abs(d.power_average([[0.0], [-100.0]])[0] + 3.0103) < 0.01
    freq = np.fft.rfftfreq(4096, 1 / d.FS)
    db = np.zeros_like(freq)
    assert np.allclose(d.smooth_fractional_octave(freq, db, 6), 0.0, atol=1e-9)


def test_fixture_matches_current_pipeline():
    """Stellt sicher, dass die eingecheckten Fixtures zum Code passen (sonst neu erzeugen)."""
    exp_path = HERE / "fixtures" / "synthetic_expected.json"
    if not exp_path.exists():
        pytest.skip("Fixtures fehlen: python pc/tests/make_fixtures.py")
    exp = json.loads(exp_path.read_text(encoding="utf-8"))
    rec = mf.synthetic_recording()
    q = np.round(np.clip(rec, -1, 1) * (2 ** 23 - 1)) / (2 ** 23 - 1)
    res = d.analyze_sweep_recording(q)
    assert np.abs(res["db"] - np.array(exp["db"])).max() < 0.01
    assert res["quality"]["offset"] == exp["quality"]["offset"]

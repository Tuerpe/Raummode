import XCTest
@testable import RaummodeDSP

final class SweepPipelineTests: XCTestCase {
    static let analyzer = SweepAnalyzer()

    /// Synthetischer Raum: 42 Hz Q8 +9 dB, 120 Hz Q4 -6 dB, Pegel 0.3.
    static func synthetic(offset: Int, seed: UInt64, noiseDb: Double = -40) -> [Double] {
        var x = analyzer.sweep
        x = Biquad.process(x, .peaking(fc: 42, gainDb: 9, q: 8))
        x = Biquad.process(x, .peaking(fc: 120, gainDb: -6, q: 4))
        x = x.map { $0 * 0.3 }
        let n = Int(SweepSpec.recordSeconds * SweepSpec.sampleRate)
        var rec = [Double](repeating: 0, count: n)
        var rng = SeededRandom(seed: seed)
        let rms = (x.map { $0 * $0 }.reduce(0, +) / Double(x.count)).squareRoot()
        let noise = rms * pow(10, noiseDb / 20)
        for i in 0..<n { rec[i] = rng.nextGaussian() * noise }
        for i in 0..<x.count where offset + i < n { rec[offset + i] += x[i] }
        return rec
    }

    static func truth() -> [Double] {
        let freq = FFT.rfftFrequencies(n: SweepSpec.nfftFR, sampleRate: SweepSpec.sampleRate)
        let a = Biquad.peaking(fc: 42, gainDb: 9, q: 8).responseDb(at: freq)
        let b = Biquad.peaking(fc: 120, gainDb: -6, q: 4).responseDb(at: freq)
        let db = zip(a, b).map(+)
        let sm = Smoothing.fractionalOctave(freq: freq, db: db, fraction: Smoothing.defaultFraction)
        let grid = Smoothing.logGrid()
        return Smoothing.normalize(freq: grid, db: Smoothing.interpolateLog(freq: freq, db: sm, to: grid))
    }

    func testInverseFilterIsDelta() {
        let a = Self.analyzer
        let c = FFT.convolve(a.sweep, a.inverseFilter)
        var peak = 0, pv = 0.0
        for (i, v) in c.enumerated() where abs(v) > pv { pv = abs(v); peak = i }
        XCTAssertLessThanOrEqual(abs(peak - (a.sweep.count - 1)), 1)
        XCTAssertEqual(pv, 1.0, accuracy: 1e-9)
    }

    func testFindsOffsetAndRecoversRoom() {
        for (offset, seed) in [(9600, 1), (59256, 2), (150001, 3)] as [(Int, UInt64)] {
            let rec = Self.synthetic(offset: offset, seed: seed)
            let res = Self.analyzer.analyze(recording: rec)
            XCTAssertLessThanOrEqual(abs(res.quality.offset! - offset), 2, "Offset \(offset)")
            XCTAssertGreaterThan(res.quality.corr, 0.5)
            XCTAssertGreaterThan(res.quality.snrDb, 30)
            let truth = Self.truth()
            var maxErr = 0.0, fAt = 0.0
            for i in 0..<res.freq.count where res.freq[i] >= 30 && res.freq[i] <= 15000 {
                let e = abs(res.db[i] - truth[i])
                if e > maxErr { maxErr = e; fAt = res.freq[i] }
            }
            XCTAssertLessThan(maxErr, 1.0, "max. Abweichung \(maxErr) dB bei \(fAt) Hz (Offset \(offset))")
            var fPeak = 0.0, vPeak = -1e9
            for i in 0..<res.freq.count where res.freq[i] >= 30 && res.freq[i] <= 60 && res.db[i] > vPeak {
                vPeak = res.db[i]; fPeak = res.freq[i]
            }
            XCTAssertEqual(fPeak, 42, accuracy: 2)
        }
    }

    func testPinkNoiseRTAIsFlat() {
        // Pink Noise per Spektralformung wie in gen_signals.py
        let n = 1 << 20
        var rng = SeededRandom(seed: 99)
        var re = (0..<n).map { _ in rng.nextGaussian() }
        var im = [Double](repeating: 0, count: n)
        let fft = FFT(n: n)
        fft.forward(re: &re, im: &im)
        let fs = SweepSpec.sampleRate
        for k in 0..<n {
            let f = Double(k <= n / 2 ? k : n - k) * fs / Double(n)
            let g = f >= 10 ? 1 / f.squareRoot() : 0
            re[k] *= g; im[k] *= g
        }
        fft.inverse(re: &re, im: &im)
        let levels = ThirdOctave.levels(re)
        XCTAssertEqual(levels.count, 31)
        let sorted = levels.sorted()
        let median = sorted[15]
        for (i, l) in levels.enumerated() {
            XCTAssertEqual(l, median, accuracy: 1.5, "Band \(ThirdOctave.nominal[i]) Hz")
        }
    }

    func testMeasurementJSONRoundTrip() throws {
        let rec = Self.synthetic(offset: 30000, seed: 5)
        let res = Self.analyzer.analyze(recording: rec)
        var m = RoomMeasurement(device: "Test", ios: "0", session: "unit", positions: [Position(name: "P1", sweep: res)])
        m.recomputeAverage()
        let data = try m.jsonData()
        let back = try RoomMeasurement.from(json: data)
        XCTAssertEqual(back.schema, 1)
        XCTAssertEqual(back.session, "unit")
        XCTAssertEqual(back.positions.count, 1)
        XCTAssertEqual(back.positions[0].mode, .sweep)
        XCTAssertEqual(back.positions[0].name, "P1")
        XCTAssertEqual(back.positions[0].quality.offset, res.quality.offset)
        XCTAssertEqual(back.positions[0].db.count, res.db.count)
        // Fliesskomma ueber JSON: nur bis 1e-9 vergleichen
        for i in 0..<res.db.count {
            XCTAssertEqual(back.positions[0].db[i], res.db[i], accuracy: 1e-9)
            XCTAssertEqual(back.average?.db[i] ?? .nan, res.db[i], accuracy: 1e-9)
        }
    }
}

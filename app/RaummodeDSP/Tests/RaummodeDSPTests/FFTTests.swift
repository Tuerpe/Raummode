import XCTest
@testable import RaummodeDSP

final class FFTTests: XCTestCase {
    func testMatchesNaiveDFT() {
        let n = 64
        var rng = SeededRandom(seed: 7)
        let re0 = (0..<n).map { _ in rng.nextGaussian() }
        let im0 = (0..<n).map { _ in rng.nextGaussian() }
        var re = re0, im = im0
        FFT(n: n).forward(re: &re, im: &im)
        for k in 0..<n {
            var sr = 0.0, si = 0.0
            for t in 0..<n {
                let a = -2 * Double.pi * Double(k * t) / Double(n)
                sr += re0[t] * cos(a) - im0[t] * sin(a)
                si += re0[t] * sin(a) + im0[t] * cos(a)
            }
            XCTAssertEqual(re[k], sr, accuracy: 1e-9)
            XCTAssertEqual(im[k], si, accuracy: 1e-9)
        }
    }

    func testInverseRoundTrip() {
        let n = 1024
        var rng = SeededRandom(seed: 3)
        let re0 = (0..<n).map { _ in rng.nextGaussian() }
        var re = re0
        var im = [Double](repeating: 0, count: n)
        let fft = FFT(n: n)
        fft.forward(re: &re, im: &im)
        fft.inverse(re: &re, im: &im)
        for i in 0..<n {
            XCTAssertEqual(re[i], re0[i], accuracy: 1e-10)
            XCTAssertEqual(im[i], 0, accuracy: 1e-10)
        }
    }

    func testConvolveAndCorrelateMatchDirect() {
        let a: [Double] = [1, 2, 3, 4, 5]
        let b: [Double] = [1, -1, 0.5]
        let c = FFT.convolve(a, b)
        XCTAssertEqual(c.count, 7)
        for k in 0..<7 {
            var s = 0.0
            for i in 0..<a.count where k - i >= 0 && k - i < b.count { s += a[i] * b[k - i] }
            XCTAssertEqual(c[k], s, accuracy: 1e-10)
        }
        let r = FFT.crossCorrelate(a, b)
        XCTAssertEqual(r.count, a.count)
        for k in 0..<a.count {
            var s = 0.0
            for n in 0..<b.count where n + k < a.count { s += a[n + k] * b[n] }
            XCTAssertEqual(r[k], s, accuracy: 1e-10)
        }
    }

    func testSmoothingBinarySearchMatchesNumpySemantics() {
        let a: [Double] = [0, 1, 2, 2, 3]
        XCTAssertEqual(Smoothing.lowerBound(a, 2), 2)
        XCTAssertEqual(Smoothing.upperBound(a, 2), 4)
        XCTAssertEqual(Smoothing.lowerBound(a, 2.5), 4)
        XCTAssertEqual(Smoothing.upperBound(a, 10), 5)
        XCTAssertEqual(Smoothing.lowerBound(a, -1), 0)
    }

    func testBiquadResponseMatchesProcessing() {
        // Sinus bei fc durch Peaking-Filter: Pegelgewinn muss dem Betragsgang entsprechen
        let fc = 1000.0, gain = 6.0
        let f = Biquad.peaking(fc: fc, gainDb: gain, q: 2)
        XCTAssertEqual(f.responseDb(at: [fc])[0], gain, accuracy: 0.01)
        let n = 48000
        let x = (0..<n).map { sin(2 * Double.pi * fc * Double($0) / 48000) }
        let y = Biquad.process(x, f)
        let rmsIn = (x[24000...].map { $0 * $0 }.reduce(0, +) / 24000).squareRoot()
        let rmsOut = (y[24000...].map { $0 * $0 }.reduce(0, +) / 24000).squareRoot()
        XCTAssertEqual(20 * log10(rmsOut / rmsIn), gain, accuracy: 0.05)
    }
}

/// Reproduzierbarer Zufall (LCG + Box-Muller), damit Tests deterministisch bleiben.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func nextUniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-300)
        let u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

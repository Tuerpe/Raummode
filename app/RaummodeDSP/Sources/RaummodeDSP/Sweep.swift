import Foundation

/// Feste Sweep-Parameter. Identisch mit pc/gen_signals.py und pc/dsp_ref.py.
public enum SweepSpec {
    public static let sampleRate: Double = 48000
    public static let f1: Double = 20
    public static let f2: Double = 20000
    public static let duration: Double = 10
    public static let fadeIn: Double = 0.050
    public static let fadeOut: Double = 0.020
    public static let levelDbfs: Double = -6
    public static let silence: Double = 2
    public static let recordSeconds: Double = 15

    public static var sampleCount: Int { Int((duration * sampleRate).rounded()) }

    // Pipeline-Konstanten
    static let preRoll = 4800
    static let postRoll = 48000
    static let peakSearch = 480
    public static let windowPreMs: Double = 5
    public static let windowPostMs: Double = 500
    public static let nfftFR = 65536
}

/// Ergebnis einer Sweep-Messung auf dem Log-Raster.
public struct SweepResult {
    public var freq: [Double]       // Log-Raster 20 Hz .. 20 kHz
    public var db: [Double]         // geglaettet, normiert (300 Hz .. 3 kHz = 0 dB)
    public var quality: Quality
    public var rawFreq: [Double]    // FFT-Bins
    public var rawDb: [Double]      // ungeglaettet, unnormiert
    public var impulseResponse: [Double]
}

/// Sweep erzeugen, in Aufnahmen finden und zur Impulsantwort entfalten.
public final class SweepAnalyzer {
    public let sweep: [Double]
    public let inverseFilter: [Double]

    public init() {
        sweep = SweepAnalyzer.makeSweep()
        inverseFilter = SweepAnalyzer.makeInverseFilter(sweep: sweep)
    }

    /// Exponentieller Sweep nach Farina mit Ein-/Ausblendung, ohne Stille.
    public static func makeSweep() -> [Double] {
        let fs = SweepSpec.sampleRate
        let n = SweepSpec.sampleCount
        let T = SweepSpec.duration
        let r = log(SweepSpec.f2 / SweepSpec.f1)
        var x = [Double](repeating: 0, count: n)
        let k = 2 * Double.pi * SweepSpec.f1 * T / r
        for i in 0..<n {
            let t = Double(i) / fs
            x[i] = sin(k * (exp(t * r / T) - 1))
        }
        let nIn = Int((SweepSpec.fadeIn * fs).rounded())
        let nOut = Int((SweepSpec.fadeOut * fs).rounded())
        for i in 0..<nIn {
            x[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(nIn))
        }
        for i in 0..<nOut {
            x[n - nOut + i] *= 0.5 + 0.5 * cos(Double.pi * Double(i) / Double(nOut))
        }
        let g = pow(10, SweepSpec.levelDbfs / 20)
        for i in 0..<n { x[i] *= g }
        return x
    }

    /// Zeitumgekehrter Sweep mit 6-dB/Oktave-Huellkurve, normiert auf Spitze 1.0.
    public static func makeInverseFilter(sweep: [Double]) -> [Double] {
        let n = sweep.count
        let L = log(SweepSpec.f2 / SweepSpec.f1)
        var inv = [Double](repeating: 0, count: n)
        for i in 0..<n {
            inv[i] = sweep[n - 1 - i] * exp(-Double(i) * L / Double(n))
        }
        let c = FFT.convolve(sweep, inv)
        var peak = 0.0
        for v in c { peak = max(peak, abs(v)) }
        for i in 0..<n { inv[i] /= peak }
        return inv
    }

    /// Offset des Sweep-Anfangs in der Aufnahme und normierte Korrelationshoehe.
    public func findSweep(in recording: [Double]) -> (offset: Int, corr: Double) {
        let r = FFT.crossCorrelate(recording, sweep)
        let maxLag: Int
        if recording.count >= sweep.count {
            maxLag = max(1, recording.count - sweep.count + 1)
        } else {
            maxLag = recording.count
        }
        var best = 0
        var bestVal = -1.0
        for k in 0..<maxLag where abs(r[k]) > bestVal {
            bestVal = abs(r[k])
            best = k
        }
        let segEnd = min(recording.count, best + sweep.count)
        var segNorm = 0.0
        var sweepNorm = 0.0
        for i in best..<segEnd {
            segNorm += recording[i] * recording[i]
            let s = sweep[i - best]
            sweepNorm += s * s
        }
        let denom = segNorm.squareRoot() * sweepNorm.squareRoot() + 1e-20
        return (best, bestVal / denom)
    }

    /// Impulsantwort des Ausschnitts um den Sweep und Index des Direktschall-Maximums.
    public func deconvolve(_ recording: [Double], offset: Int) -> (ir: [Double], peak: Int) {
        let n = sweep.count
        let a = max(0, offset - SweepSpec.preRoll)
        let b = min(recording.count, offset + n + SweepSpec.postRoll)
        let seg = Array(recording[a..<b])
        let ir = FFT.convolve(seg, inverseFilter)
        let expected = (offset - a) + n - 1
        let lo = max(0, expected - SweepSpec.peakSearch)
        let hi = min(ir.count, expected + SweepSpec.peakSearch)
        var peak = lo
        var pv = -1.0
        for i in lo..<hi where abs(ir[i]) > pv {
            pv = abs(ir[i])
            peak = i
        }
        return (ir, peak)
    }

    /// Fenster um den Direktschall: pre ms davor (halbes Hann rauf), post ms danach,
    /// die letzten 10 % mit halbem Hann runter.
    public static func windowIR(_ ir: [Double], peak: Int,
                                preMs: Double = SweepSpec.windowPreMs,
                                postMs: Double = SweepSpec.windowPostMs,
                                sampleRate fs: Double = SweepSpec.sampleRate) -> [Double] {
        let pre = Int((preMs / 1000 * fs).rounded())
        let post = Int((postMs / 1000 * fs).rounded())
        let len = pre + post
        var out = [Double](repeating: 0, count: len)
        let start = peak - pre
        for i in 0..<len {
            let src = start + i
            if src >= 0 && src < ir.count { out[i] = ir[src] }
        }
        for i in 0..<pre {
            out[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(pre))
        }
        let tail = Int((0.1 * Double(post)).rounded())
        for j in 0..<tail {
            out[len - tail + j] *= 0.5 + 0.5 * cos(Double.pi * Double(j) / Double(tail))
        }
        return out
    }

    /// FFT der gefensterten IR -> (Frequenzen, dB).
    public static func irToFR(_ irWindowed: [Double], nfft: Int = SweepSpec.nfftFR,
                              sampleRate fs: Double = SweepSpec.sampleRate) -> (freq: [Double], db: [Double]) {
        let mag = FFT.magnitudeSpectrum(irWindowed, n: nfft)
        let freq = FFT.rfftFrequencies(n: nfft, sampleRate: fs)
        let db = mag.map { 20 * log10($0 + 1e-12) }
        return (freq, db)
    }

    /// Komplette Pipeline: Aufnahme -> Kurve auf dem Log-Raster plus Qualitaet.
    public func analyze(recording: [Double], smoothing: Int = Smoothing.defaultFraction) -> SweepResult {
        let (offset, corr) = findSweep(in: recording)
        let (ir, peak) = deconvolve(recording, offset: offset)
        let irw = SweepAnalyzer.windowIR(ir, peak: peak)
        let (freq, db) = SweepAnalyzer.irToFR(irw)
        let sm = Smoothing.fractionalOctave(freq: freq, db: db, fraction: smoothing)
        let grid = Smoothing.logGrid()
        let curve = Smoothing.normalize(freq: grid, db: Smoothing.interpolateLog(freq: freq, db: sm, to: grid))

        let n = sweep.count
        let fs = Int(SweepSpec.sampleRate)
        let sigEnd = min(recording.count, offset + n)
        let sigRms = Levels.dbRms(recording, from: offset, to: sigEnd)
        var snr = Double.nan
        if offset >= fs {
            snr = sigRms - Levels.dbRms(recording, from: offset - fs, to: offset)
        } else if offset + n + fs / 2 + fs <= recording.count {
            snr = sigRms - Levels.dbRms(recording, from: offset + n + fs / 2, to: offset + n + fs / 2 + fs)
        }
        var peakAbs = 0.0
        for v in recording { peakAbs = max(peakAbs, abs(v)) }
        let quality = Quality(snrDb: snr, peakDbfs: 20 * log10(peakAbs + 1e-12), corr: corr, offset: offset)
        return SweepResult(freq: grid, db: curve, quality: quality, rawFreq: freq, rawDb: db, impulseResponse: irw)
    }
}

public enum Levels {
    public static func dbRms(_ x: [Double], from: Int, to: Int) -> Double {
        guard to > from else { return -240 }
        var acc = 0.0
        for i in from..<to { acc += x[i] * x[i] }
        return 20 * log10((acc / Double(to - from)).squareRoot() + 1e-12)
    }
}

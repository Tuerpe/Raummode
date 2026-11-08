import Foundation

/// Glaettung, Log-Raster, Normierung, Mittelung. Identisch mit pc/dsp_ref.py.
public enum Smoothing {
    public static let defaultFraction = 6          // 1/6 Oktave
    public static let gridPointsPerOctave = 48
    public static let gridF1: Double = 20
    public static let gridF2: Double = 20000
    public static let normLo: Double = 300
    public static let normHi: Double = 3000

    /// Leistungsmittel ueber [f / 2^(1/2n), f * 2^(1/2n)]; freq aufsteigend.
    public static func fractionalOctave(freq: [Double], db: [Double], fraction: Int) -> [Double] {
        let count = freq.count
        var cum = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { cum[i + 1] = cum[i] + pow(10, db[i] / 10) }
        let half = pow(2, 1 / (2 * Double(fraction)))
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let lo = lowerBound(freq, freq[i] / half)
            var hi = upperBound(freq, freq[i] * half)
            if hi < lo + 1 { hi = lo + 1 }
            out[i] = 10 * log10((cum[hi] - cum[lo]) / Double(hi - lo) + 1e-30)
        }
        return out
    }

    /// Erster Index mit a[i] >= v (numpy searchsorted side="left").
    static func lowerBound(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Erster Index mit a[i] > v (numpy searchsorted side="right").
    static func upperBound(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public static func logGrid(pointsPerOctave: Int = gridPointsPerOctave,
                               f1: Double = gridF1, f2: Double = gridF2) -> [Double] {
        let n = Int(floor(Double(pointsPerOctave) * log2(f2 / f1) + 1e-9))
        return (0...n).map { f1 * pow(2, Double($0) / Double(pointsPerOctave)) }
    }

    /// Lineare Interpolation ueber log(f); Bins mit f <= 0 werden ignoriert.
    public static func interpolateLog(freq: [Double], db: [Double], to grid: [Double]) -> [Double] {
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(freq.count)
        ys.reserveCapacity(freq.count)
        for i in 0..<freq.count where freq[i] > 0 {
            xs.append(log(freq[i]))
            ys.append(db[i])
        }
        var out = [Double](repeating: 0, count: grid.count)
        for (gi, g) in grid.enumerated() {
            let x = log(g)
            if x <= xs[0] { out[gi] = ys[0]; continue }
            if x >= xs[xs.count - 1] { out[gi] = ys[ys.count - 1]; continue }
            let j = lowerBound(xs, x)          // xs[j-1] < x <= xs[j]
            let x0 = xs[j - 1], x1 = xs[j]
            let t = (x - x0) / (x1 - x0)
            out[gi] = ys[j - 1] + t * (ys[j] - ys[j - 1])
        }
        return out
    }

    public static func normalize(freq: [Double], db: [Double], lo: Double = normLo, hi: Double = normHi) -> [Double] {
        var acc = 0.0
        var n = 0
        for i in 0..<freq.count where freq[i] >= lo && freq[i] <= hi {
            acc += db[i]
            n += 1
        }
        let mean = n > 0 ? acc / Double(n) : 0
        return db.map { $0 - mean }
    }

    /// Leistungsmittel mehrerer Kurven gleicher Laenge.
    public static func powerAverage(_ curves: [[Double]]) -> [Double] {
        guard let first = curves.first else { return [] }
        var out = [Double](repeating: 0, count: first.count)
        for i in 0..<first.count {
            var acc = 0.0
            for c in curves { acc += pow(10, c[i] / 10) }
            out[i] = 10 * log10(acc / Double(curves.count))
        }
        return out
    }
}

import Foundation

/// Peaking-EQ nach Audio-EQ-Cookbook, dieselben Formeln wie Equalizer APO fuer "PK".
/// Dient der Vorher/Nachher-Simulation in der App und den Tests.
public struct Biquad {
    public var b0: Double, b1: Double, b2: Double
    public var a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    public static func peaking(fc: Double, gainDb: Double, q: Double,
                               sampleRate fs: Double = SweepSpec.sampleRate) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * fc / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * cos(w0) / a0, b2: (1 - alpha * A) / a0,
                      a1: -2 * cos(w0) / a0, a2: (1 - alpha / A) / a0)
    }

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Betragsgang in dB an den gegebenen Frequenzen.
    public func responseDb(at freq: [Double], sampleRate fs: Double = SweepSpec.sampleRate) -> [Double] {
        freq.map { f in
            let w = 2 * Double.pi * f / fs
            // z^-1 = e^{-jw}
            let c1 = cos(w), s1 = sin(w)
            let c2 = cos(2 * w), s2 = sin(2 * w)
            let nr = b0 + b1 * c1 + b2 * c2
            let ni = -(b1 * s1 + b2 * s2)
            let dr = 1 + a1 * c1 + a2 * c2
            let di = -(a1 * s1 + a2 * s2)
            let num = nr * nr + ni * ni
            let den = dr * dr + di * di
            return 10 * log10(num / den + 1e-24)
        }
    }

    /// Filtert ein Signal (Direct Form II transposed), zustandslos aufgerufen.
    public static func process(_ x: [Double], _ filter: Biquad) -> [Double] {
        var f = filter
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let v = x[i]
            let y = f.b0 * v + f.z1
            f.z1 = f.b1 * v - f.a1 * y + f.z2
            f.z2 = f.b2 * v - f.a2 * y
            out[i] = y
        }
        return out
    }
}

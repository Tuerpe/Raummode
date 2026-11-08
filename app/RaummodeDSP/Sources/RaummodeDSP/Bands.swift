import Foundation

/// 1/3-Oktav-RTA (IEC 61260 Mittenfrequenzen 20 Hz .. 20 kHz) per Welch-Mittelung.
public enum ThirdOctave {
    public static let nominal: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315,
                                           400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000,
                                           5000, 6300, 8000, 10000, 12500, 16000, 20000]
    public static let exact: [Double] = (-17...13).map { 1000 * pow(2, Double($0) / 3) }
    public static let welchSegment = 32768

    /// Einseitige Leistungsdichte (Hann, 50 % Ueberlappung). Liefert (Frequenzen, PSD).
    public static func welchPSD(_ x: [Double], segment nperseg: Int = welchSegment,
                                sampleRate fs: Double = SweepSpec.sampleRate) -> (freq: [Double], psd: [Double]) {
        var w = [Double](repeating: 0, count: nperseg)
        var wsum = 0.0
        for i in 0..<nperseg {
            w[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(nperseg))
            wsum += w[i] * w[i]
        }
        let step = nperseg / 2
        let frames = max(1, (x.count - nperseg) / step + 1)
        let fft = FFT(n: nperseg)
        var acc = [Double](repeating: 0, count: nperseg / 2 + 1)
        var re = [Double](repeating: 0, count: nperseg)
        var im = [Double](repeating: 0, count: nperseg)
        for f in 0..<frames {
            let start = f * step
            for i in 0..<nperseg {
                let idx = start + i
                re[i] = idx < x.count ? x[idx] * w[i] : 0
                im[i] = 0
            }
            fft.forward(re: &re, im: &im)
            for i in 0...(nperseg / 2) {
                acc[i] += re[i] * re[i] + im[i] * im[i]
            }
        }
        let scale = 2.0 / (fs * wsum) / Double(frames)
        var psd = acc.map { $0 * scale }
        psd[0] /= 2
        psd[psd.count - 1] /= 2
        return (FFT.rfftFrequencies(n: nperseg, sampleRate: fs), psd)
    }

    /// Pegel je Band in dB (relativ zu Vollaussteuerung), 31 Werte.
    public static func levels(_ x: [Double], sampleRate fs: Double = SweepSpec.sampleRate) -> [Double] {
        let (f, psd) = welchPSD(x, sampleRate: fs)
        let df = f[1] - f[0]
        let edge = pow(2, 1.0 / 6.0)
        return exact.map { fc in
            var sum = 0.0
            let lo = fc / edge, hi = fc * edge
            for i in 0..<f.count where f[i] >= lo && f[i] < hi { sum += psd[i] }
            return 10 * log10(sum * df + 1e-30)
        }
    }

    /// Schnelle Variante fuer Live-RTA: ein einzelner Block (z. B. 16384 Samples) ohne Welch,
    /// fuer die Anzeige mit zeitlicher Glaettung in der App.
    public static func levelsSingleBlock(_ block: [Double], sampleRate fs: Double = SweepSpec.sampleRate) -> [Double] {
        let n = FFT.nextPow2(block.count)
        var w = [Double](repeating: 0, count: block.count)
        var wsum = 0.0
        for i in 0..<block.count {
            w[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(block.count))
            wsum += w[i] * w[i]
        }
        var x = [Double](repeating: 0, count: block.count)
        for i in 0..<block.count { x[i] = block[i] * w[i] }
        let mag = FFT.magnitudeSpectrum(x, n: n)
        let f = FFT.rfftFrequencies(n: n, sampleRate: fs)
        let df = f[1] - f[0]
        let scale = 2.0 / (fs * wsum)
        let edge = pow(2, 1.0 / 6.0)
        return exact.map { fc in
            var sum = 0.0
            let lo = fc / edge, hi = fc * edge
            for i in 0..<f.count where f[i] >= lo && f[i] < hi { sum += mag[i] * mag[i] * scale }
            return 10 * log10(sum * df + 1e-30)
        }
    }
}

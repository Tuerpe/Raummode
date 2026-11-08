import Foundation

/// Radix-2-FFT in purem Swift (keine Accelerate-Abhaengigkeit, damit die Tests
/// auch unter Linux/Windows laufen). Laenge muss Zweierpotenz sein.
public final class FFT {
    public let n: Int
    private let log2n: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitRev: [Int]

    public init(n: Int) {
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT-Laenge muss Zweierpotenz sein")
        self.n = n
        var l = 0
        while (1 << l) < n { l += 1 }
        log2n = l
        var c = [Double](repeating: 0, count: max(1, n / 2))
        var s = [Double](repeating: 0, count: max(1, n / 2))
        for k in 0..<(n / 2) {
            let a = -2.0 * Double.pi * Double(k) / Double(n)
            c[k] = cos(a)
            s[k] = sin(a)
        }
        cosTable = c
        sinTable = s
        var rev = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var x = i
            var r = 0
            for _ in 0..<l {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = r
        }
        bitRev = rev
    }

    /// Vorwaerts-FFT in place (e^{-i...}).
    public func forward(re: inout [Double], im: inout [Double]) {
        transform(re: &re, im: &im, inverse: false)
    }

    /// Inverse FFT in place, inklusive Division durch n.
    public func inverse(re: inout [Double], im: inout [Double]) {
        transform(re: &re, im: &im, inverse: true)
        let s = 1.0 / Double(n)
        for i in 0..<n {
            re[i] *= s
            im[i] *= s
        }
    }

    private func transform(re: inout [Double], im: inout [Double], inverse: Bool) {
        precondition(re.count == n && im.count == n)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                for i in 0..<n {
                    let j = bitRev[i]
                    if j > i {
                        rp.swapAt(i, j)
                        ip.swapAt(i, j)
                    }
                }
                let sign: Double = inverse ? -1.0 : 1.0
                var size = 2
                while size <= n {
                    let half = size / 2
                    let step = n / size
                    var start = 0
                    while start < n {
                        var k = 0
                        for j in 0..<half {
                            let wr = cosTable[k]
                            let wi = sign * sinTable[k]
                            let a = start + j
                            let b = a + half
                            let tr = rp[b] * wr - ip[b] * wi
                            let ti = rp[b] * wi + ip[b] * wr
                            rp[b] = rp[a] - tr
                            ip[b] = ip[a] - ti
                            rp[a] += tr
                            ip[a] += ti
                            k += step
                        }
                        start += size
                    }
                    size <<= 1
                }
            }
        }
    }

    // MARK: - Hilfsfunktionen

    public static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// Lineare Faltung, Laenge a.count + b.count - 1.
    public static func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        let outLen = a.count + b.count - 1
        let n = nextPow2(outLen)
        let fft = FFT(n: n)
        var ar = a + [Double](repeating: 0, count: n - a.count)
        var ai = [Double](repeating: 0, count: n)
        var br = b + [Double](repeating: 0, count: n - b.count)
        var bi = [Double](repeating: 0, count: n)
        fft.forward(re: &ar, im: &ai)
        fft.forward(re: &br, im: &bi)
        for i in 0..<n {
            let r = ar[i] * br[i] - ai[i] * bi[i]
            let im = ar[i] * bi[i] + ai[i] * br[i]
            ar[i] = r
            ai[i] = im
        }
        fft.inverse(re: &ar, im: &ai)
        return Array(ar[0..<outLen])
    }

    /// r[k] = sum_n x[n+k] * y[n], k = 0 ..< x.count
    public static func crossCorrelate(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = nextPow2(x.count + y.count)
        let fft = FFT(n: n)
        var xr = x + [Double](repeating: 0, count: n - x.count)
        var xi = [Double](repeating: 0, count: n)
        var yr = y + [Double](repeating: 0, count: n - y.count)
        var yi = [Double](repeating: 0, count: n)
        fft.forward(re: &xr, im: &xi)
        fft.forward(re: &yr, im: &yi)
        for i in 0..<n {
            // X * conj(Y)
            let r = xr[i] * yr[i] + xi[i] * yi[i]
            let im = xi[i] * yr[i] - xr[i] * yi[i]
            xr[i] = r
            xi[i] = im
        }
        fft.inverse(re: &xr, im: &xi)
        return Array(xr[0..<x.count])
    }

    /// Betragsspektrum (einseitig, n/2+1 Werte) eines reellen Signals, auf n Punkte gepolstert.
    public static func magnitudeSpectrum(_ x: [Double], n: Int) -> [Double] {
        let fft = FFT(n: n)
        var re = Array(x.prefix(n)) + [Double](repeating: 0, count: max(0, n - x.count))
        var im = [Double](repeating: 0, count: n)
        fft.forward(re: &re, im: &im)
        var out = [Double](repeating: 0, count: n / 2 + 1)
        for i in 0...(n / 2) {
            out[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot()
        }
        return out
    }

    /// Frequenzen der einseitigen FFT-Bins.
    public static func rfftFrequencies(n: Int, sampleRate: Double) -> [Double] {
        (0...(n / 2)).map { Double($0) * sampleRate / Double(n) }
    }
}

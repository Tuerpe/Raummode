import Foundation

/// Minimaler WAV-Leser/-Schreiber (RIFF, PCM 16/24/32 Bit und Float32, mono oder
/// erster Kanal). Fuer Tests (Fixtures) und zum Export von Rohaufnahmen aus der App.
public enum WavFile {
    public enum WavError: Error { case malformed(String) }

    public static func read(url: URL) throws -> (samples: [Double], sampleRate: Double) {
        try read(data: try Data(contentsOf: url))
    }

    public static func read(data d: Data) throws -> (samples: [Double], sampleRate: Double) {
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        guard d.count > 12, String(data: d[0..<4], encoding: .ascii) == "RIFF",
              String(data: d[8..<12], encoding: .ascii) == "WAVE" else {
            throw WavError.malformed("kein RIFF/WAVE")
        }
        var pos = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataStart = -1, dataLen = 0
        while pos + 8 <= d.count {
            let id = String(data: d[pos..<pos + 4], encoding: .ascii) ?? ""
            let len = u32(pos + 4)
            let body = pos + 8
            if id == "fmt " {
                format = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                if format == 0xFFFE && len >= 26 { format = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataStart = body
                dataLen = min(len, d.count - body)
                break
            }
            pos = body + len + (len & 1)
        }
        guard dataStart >= 0, channels > 0, bits > 0 else { throw WavError.malformed("fmt/data fehlt") }
        let bytesPerSample = bits / 8
        let frame = bytesPerSample * channels
        let n = dataLen / frame
        var out = [Double](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress! + dataStart
            for i in 0..<n {
                let o = i * frame
                switch (format, bits) {
                case (1, 16):
                    let v = Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)
                    out[i] = Double(v) / 32768
                case (1, 24):
                    var v = Int32(p[o]) | Int32(p[o + 1]) << 8 | Int32(p[o + 2]) << 16
                    if v & 0x800000 != 0 { v -= 0x1000000 }
                    out[i] = Double(v) / 8388608
                case (1, 32):
                    let v = Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)
                    out[i] = Double(v) / 2147483648
                case (3, 32):
                    let bitsU = UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
                    out[i] = Double(Float(bitPattern: bitsU))
                default:
                    out[i] = 0
                }
            }
        }
        if !(format == 1 && [16, 24, 32].contains(bits)) && !(format == 3 && bits == 32) {
            throw WavError.malformed("Format \(format)/\(bits) Bit nicht unterstuetzt")
        }
        return (out, Double(rate))
    }

    /// Schreibt Mono-Float32-WAV (verlustfrei fuer Rohaufnahmen).
    public static func writeFloat32(_ x: [Float], sampleRate: Int, to url: URL) throws {
        var d = Data()
        func put32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(x.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(3); put16(1); put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 4)); put16(4); put16(32)
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        x.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        try d.write(to: url)
    }
}

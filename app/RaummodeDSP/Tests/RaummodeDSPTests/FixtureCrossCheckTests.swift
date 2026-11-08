import XCTest
@testable import RaummodeDSP

/// Kreuzvergleich mit der Python-Referenz: pc/tests/fixtures (erzeugt von make_fixtures.py).
final class FixtureCrossCheckTests: XCTestCase {
    struct Expected: Decodable {
        var offset: Int
        var freq: [Double]
        var db: [Double]
        var truthDb: [Double]
    }

    static var fixturesDir: URL {
        // Tests/RaummodeDSPTests/<file> -> Raummode/pc/tests/fixtures
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RaummodeDSPTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RaummodeDSP
            .deletingLastPathComponent()   // app
            .appendingPathComponent("pc/tests/fixtures")
    }

    func testMatchesPythonReference() throws {
        let wav = Self.fixturesDir.appendingPathComponent("synthetic_recording.wav")
        let json = Self.fixturesDir.appendingPathComponent("synthetic_expected.json")
        guard FileManager.default.fileExists(atPath: wav.path), FileManager.default.fileExists(atPath: json.path) else {
            throw XCTSkip("Fixtures fehlen: python pc/tests/make_fixtures.py")
        }
        let (samples, rate) = try WavFile.read(url: wav)
        XCTAssertEqual(rate, SweepSpec.sampleRate)
        XCTAssertEqual(samples.count, Int(SweepSpec.recordSeconds * SweepSpec.sampleRate))
        let exp = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: json))

        let res = SweepAnalyzer().analyze(recording: samples)
        XCTAssertEqual(res.freq.count, exp.freq.count)
        XCTAssertLessThanOrEqual(abs(res.quality.offset! - exp.offset), 2)

        var maxErr = 0.0, fAt = 0.0
        for i in 0..<res.freq.count where res.freq[i] >= 50 && res.freq[i] <= 15000 {
            let e = abs(res.db[i] - exp.db[i])
            if e > maxErr { maxErr = e; fAt = res.freq[i] }
        }
        XCTAssertLessThan(maxErr, 0.5, "Swift vs. Python: \(maxErr) dB bei \(fAt) Hz")

        var truthErr = 0.0
        for i in 0..<res.freq.count where res.freq[i] >= 30 && res.freq[i] <= 15000 {
            truthErr = max(truthErr, abs(res.db[i] - exp.truthDb[i]))
        }
        XCTAssertLessThan(truthErr, 1.0, "Swift vs. wahre Raumkurve: \(truthErr) dB")
    }
}

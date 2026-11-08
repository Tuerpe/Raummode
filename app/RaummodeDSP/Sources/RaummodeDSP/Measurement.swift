import Foundation

/// JSON-Schema 1 der Mess-Exporte. Wird von pc/analyze.py gelesen.
public struct RoomMeasurement: Codable, Equatable {
    public var schema: Int = 1
    public var app: String = "Raummode"
    public var device: String
    public var ios: String
    public var created: String          // ISO-8601
    public var session: String
    public var sampleRate: Double = SweepSpec.sampleRate
    public var sweep: SweepParams = SweepParams()
    public var positions: [Position]
    public var average: Curve?

    public init(device: String, ios: String, created: Date = Date(), session: String,
                positions: [Position], average: Curve? = nil) {
        self.device = device
        self.ios = ios
        self.created = ISO8601DateFormatter().string(from: created)
        self.session = session
        self.positions = positions
        self.average = average
    }

    /// Leistungsmittel aller Positionen gleicher Rasterlaenge.
    public mutating func recomputeAverage() {
        guard let first = positions.first else { average = nil; return }
        let same = positions.filter { $0.freq.count == first.freq.count }
        average = Curve(freq: first.freq, db: Smoothing.powerAverage(same.map { $0.db }))
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func from(json: Data) throws -> RoomMeasurement {
        try JSONDecoder().decode(RoomMeasurement.self, from: json)
    }
}

public struct SweepParams: Codable, Equatable {
    public var f1: Double = SweepSpec.f1
    public var f2: Double = SweepSpec.f2
    public var duration: Double = SweepSpec.duration
    public init() {}
}

public enum MeasureMode: String, Codable {
    case sweep
    case rta
}

public struct Position: Codable, Equatable {
    public var name: String
    public var mode: MeasureMode
    public var smoothing: String        // "1/6" bei Sweep, "1/3" bei RTA
    public var freq: [Double]
    public var db: [Double]
    public var quality: Quality

    public init(name: String, mode: MeasureMode, smoothing: String, freq: [Double], db: [Double], quality: Quality) {
        self.name = name
        self.mode = mode
        self.smoothing = smoothing
        self.freq = freq
        self.db = db
        self.quality = quality
    }

    public init(name: String, sweep r: SweepResult) {
        self.init(name: name, mode: .sweep, smoothing: "1/\(Smoothing.defaultFraction)",
                  freq: r.freq, db: r.db, quality: r.quality)
    }
}

public struct Quality: Codable, Equatable {
    public var snrDb: Double
    public var peakDbfs: Double
    public var corr: Double
    public var offset: Int?

    public init(snrDb: Double, peakDbfs: Double, corr: Double, offset: Int? = nil) {
        self.snrDb = snrDb.isFinite ? snrDb : -1
        self.peakDbfs = peakDbfs
        self.corr = corr
        self.offset = offset
    }
}

public struct Curve: Codable, Equatable {
    public var freq: [Double]
    public var db: [Double]
    public init(freq: [Double], db: [Double]) {
        self.freq = freq
        self.db = db
    }
}

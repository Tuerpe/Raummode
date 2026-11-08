import Foundation
import RaummodeDSP
import UIKit

/// Aktuelle Mess-Session (mehrere Positionen) plus gespeicherte JSON-Dateien im
/// Dokumente-Ordner der App (sichtbar in der Dateien-App dank UIFileSharingEnabled).
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessionName: String = SessionStore.defaultName()
    @Published var positions: [Position] = []
    @Published var savedFiles: [URL] = []
    @Published var lastSavedURL: URL?
    @Published var message: String?

    nonisolated(unsafe) static let analyzer = SweepAnalyzer()   // einmalig, ~1 s

    init() { refreshSaved() }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return "Messung_" + f.string(from: Date())
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var average: [Double]? {
        guard !positions.isEmpty else { return nil }
        let n = positions[0].freq.count
        let same = positions.filter { $0.freq.count == n }
        return Smoothing.powerAverage(same.map { $0.db })
    }

    func add(_ p: Position) {
        positions.append(p)
    }

    func remove(at offsets: IndexSet) {
        positions.remove(atOffsets: offsets)
    }

    func clear() {
        positions = []
        sessionName = SessionStore.defaultName()
    }

    func measurement() -> RoomMeasurement {
        var m = RoomMeasurement(device: DeviceInfo.model, ios: UIDevice.current.systemVersion,
                            session: sessionName, positions: positions)
        m.recomputeAverage()
        return m
    }

    /// Schreibt <session>.json in Dokumente und liefert die URL (fuer ShareLink).
    @discardableResult
    func save() -> URL? {
        do {
            let data = try measurement().jsonData()
            let safe = sessionName.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
            let url = SessionStore.documents.appendingPathComponent("\(safe).json")
            try data.write(to: url, options: .atomic)
            lastSavedURL = url
            refreshSaved()
            message = "Gespeichert: \(url.lastPathComponent)"
            return url
        } catch {
            message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }

    func saveRawRecording(_ samples: [Double], name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        let url = SessionStore.documents.appendingPathComponent("\(safe).wav")
        do {
            try WavFile.writeFloat32(samples.map { Float($0) }, sampleRate: Int(SweepSpec.sampleRate), to: url)
            refreshSaved()
            return url
        } catch {
            message = "WAV fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }

    func refreshSaved() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: SessionStore.documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        savedFiles = items
            .filter { ["json", "wav"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshSaved()
    }

    func load(_ url: URL) {
        do {
            let m = try RoomMeasurement.from(json: Data(contentsOf: url))
            sessionName = m.session
            positions = m.positions
            message = "Geladen: \(url.lastPathComponent)"
        } catch {
            message = "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

enum DeviceInfo {
    /// z. B. "iPhone16,2" (iPhone 15 Pro Max)
    static var model: String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        let id = mirror.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }.map { Character(UnicodeScalar(UInt8($0))) }
        return String(id)
    }
}

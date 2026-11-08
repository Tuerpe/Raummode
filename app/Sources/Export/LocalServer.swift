import Foundation
import Network

/// Kleiner HTTP-Server (nur GET) fuer den Dokumente-Ordner: Dateiliste und Download,
/// damit der PC die Messungen im selben WLAN per Browser holen kann.
@MainActor
final class LocalServer: ObservableObject {
    @Published var isRunning = false
    @Published var urls: [String] = []
    @Published var lastError: String?

    private var listener: NWListener?
    private var directory: URL = FileManager.default.temporaryDirectory
    private let port: UInt16 = 8080

    func start(directory: URL) {
        self.directory = directory
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                        self?.urls = LocalServer.localAddresses().map { "http://\($0):\(self?.port ?? 8080)/" }
                    case .failed(let e):
                        self?.lastError = "Server-Fehler: \(e.localizedDescription)"
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            lastError = "Server-Start fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        urls = []
    }

    private nonisolated func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = req.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"
            let response = self.respond(path: path.removingPercentEncoding ?? path)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private nonisolated func respond(path: String) -> Data {
        let dir = MainActor.assumeIsolated { directory }
        let fm = FileManager.default
        if path == "/" || path.isEmpty {
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            var html = "<!doctype html><meta charset=utf-8><title>Raummode</title><h1>Raummode – Messdateien</h1><ul>"
            for f in files where !f.hasPrefix(".") {
                let esc = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
                html += "<li><a href=\"/\(esc)\" download>\(f)</a></li>"
            }
            html += "</ul><p>Dateien per Rechtsklick → „Ziel speichern unter“ nach messungen/ kopieren.</p>"
            return header(status: "200 OK", type: "text/html; charset=utf-8", length: html.utf8.count) + Data(html.utf8)
        }
        let name = String(path.dropFirst())
        guard !name.contains("/"), !name.contains(".."), let body = fm.contents(atPath: dir.appendingPathComponent(name).path) else {
            let msg = "404 nicht gefunden"
            return header(status: "404 Not Found", type: "text/plain", length: msg.utf8.count) + Data(msg.utf8)
        }
        let type = name.hasSuffix(".json") ? "application/json" : (name.hasSuffix(".wav") ? "audio/wav" : "application/octet-stream")
        return header(status: "200 OK", type: type, length: body.count) + body
    }

    private nonisolated func header(status: String, type: String, length: Int) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n".utf8)
    }

    /// IPv4-Adressen der WLAN-Schnittstelle (en0) und sonstiger Nicht-Loopback-Interfaces.
    nonisolated static func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: p.pointee.ifa_name)
                    let addr = String(cString: host)
                    if name.hasPrefix("en") { result.insert(addr, at: 0) } else if !addr.hasPrefix("169.254") { result.append(addr) }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return result
    }
}

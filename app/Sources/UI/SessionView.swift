import RaummodeDSP
import SwiftUI

/// Positionen sammeln, mitteln, als JSON speichern/teilen, Dateien verwalten, WLAN-Server.
struct SessionView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var server = LocalServer()
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section("Aktuelle Session") {
                    TextField("Name", text: $session.sessionName)
                    if session.positions.isEmpty {
                        Text("Noch keine Positionen. Im Tab Sweep oder RTA messen und hinzufuegen.")
                            .foregroundStyle(.secondary)
                    } else {
                        ResultChart(curves: chartCurves)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        ForEach(session.positions.indices, id: \.self) { i in
                            let p = session.positions[i]
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text(p.mode == .sweep ? String(format: "Sweep · corr %.2f · SNR %.0f dB", p.quality.corr, p.quality.snrDb) : "RTA")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { session.remove(at: $0) }
                    }
                }

                Section("Export") {
                    Button("Als JSON speichern") { session.save() }
                        .disabled(session.positions.isEmpty)
                    if let url = session.lastSavedURL {
                        ShareLink(item: url) { Label("Teilen (iCloud Drive, AirDrop, Mail)", systemImage: "square.and.arrow.up") }
                    }
                    Button("Session leeren", role: .destructive) { showClearConfirm = true }
                        .disabled(session.positions.isEmpty)
                    if let m = session.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("WLAN-Uebertragung") {
                    Toggle("Server im WLAN starten", isOn: Binding(
                        get: { server.isRunning },
                        set: { on in if on { server.start(directory: SessionStore.documents) } else { server.stop() } }))
                    if server.isRunning {
                        Text("Am PC im Browser oeffnen:").font(.footnote)
                        ForEach(server.urls, id: \.self) { u in
                            Text(u).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let e = server.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                }

                Section("Gespeicherte Dateien (Dateien-App → Raummode)") {
                    if session.savedFiles.isEmpty {
                        Text("keine").foregroundStyle(.secondary)
                    }
                    ForEach(session.savedFiles, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(fileInfo(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                            if url.pathExtension == "json" {
                                Button { session.load(url) } label: { Image(systemName: "arrow.down.doc") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { session.savedFiles[$0] }.forEach { session.delete($0) } }
                }
            }
            .navigationTitle("Session")
            .confirmationDialog("Alle Positionen verwerfen?", isPresented: $showClearConfirm) {
                Button("Verwerfen", role: .destructive) { session.clear() }
            }
            .onAppear { session.refreshSaved() }
        }
    }

    private var chartCurves: [(name: String, freq: [Double], db: [Double])] {
        var c = session.positions.map { (name: $0.name, freq: $0.freq, db: $0.db) }
        if session.positions.count > 1, let avg = session.average {
            c.append((name: "Mittel", freq: session.positions[0].freq, db: avg))
        }
        return c
    }

    private func fileInfo(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let date = (attrs?[.modificationDate] as? Date) ?? Date()
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · \(f.string(from: date))"
    }
}

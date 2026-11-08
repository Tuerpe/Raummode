import Charts
import RaummodeDSP
import SwiftUI

/// Sweep-Messung: 15 s aufnehmen, waehrend der PC sweep_20-20k_10s.wav abspielt.
struct SweepView: View {
    @EnvironmentObject var capture: CaptureEngine
    @EnvironmentObject var session: SessionStore

    @State private var positionName = "Hoerplatz"
    @State private var result: SweepResult?
    @State private var lastRecording: [Double] = []
    @State private var analyzing = false
    @State private var status = "Bereit"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let r = result {
                    ResultChart(curves: [("Messung", r.freq, r.db)])
                        .frame(maxHeight: .infinity)
                    qualityBox(r.quality)
                } else {
                    ContentUnavailableView("Noch keine Messung", systemImage: "waveform",
                                           description: Text("Aufnahme starten, dann sofort am PC den Sweep abspielen."))
                        .frame(maxHeight: .infinity)
                }
                controls
            }
            .padding()
            .navigationTitle("Sweep-Messung")
        }
    }

    private func qualityBox(_ q: Quality) -> some View {
        let ok = q.corr > 0.2 && q.snrDb > 20 && q.peakDbfs < -1
        return HStack(spacing: 16) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Korrelation %.2f  ·  SNR %.0f dB  ·  Spitze %.1f dBFS", q.corr, q.snrDb, q.peakDbfs))
                    .monospacedDigit()
                Text(hint(q)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func hint(_ q: Quality) -> String {
        if q.peakDbfs >= -1 { return "Uebersteuert: PC leiser machen." }
        if q.corr <= 0.2 { return "Sweep kaum erkannt: Lief der Sweep waehrend der Aufnahme? Lauter machen." }
        if q.snrDb <= 20 { return "Stoerabstand gering: lauter oder Raum ruhiger." }
        return "Messung brauchbar."
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if capture.isRecording {
                ProgressView(value: capture.recordingProgress) {
                    Text(String(format: "Aufnahme laeuft … %.0f %%   Pegel %.0f dBFS", capture.recordingProgress * 100, capture.levelDbfs))
                        .monospacedDigit()
                }
            } else {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Position", text: $positionName).textFieldStyle(.roundedBorder)
                Button(analyzing ? "Rechne …" : "Aufnahme 15 s") { Task { await measure() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(capture.isRecording || analyzing)
            }
            if result != nil {
                HStack {
                    Button("Zur Session hinzufuegen") {
                        if let r = result {
                            session.add(Position(name: positionName, sweep: r))
                            session.message = "Position \"\(positionName)\" hinzugefuegt (\(session.positions.count) gesamt)"
                            status = session.message ?? ""
                        }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Roh-WAV sichern") {
                        if let url = session.saveRawRecording(lastRecording, name: "\(session.sessionName)_\(positionName)_raw") {
                            status = "WAV gespeichert: \(url.lastPathComponent)"
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func measure() async {
        status = "Jetzt am PC sweep_20-20k_10s.wav starten!"
        let rec = await capture.record(seconds: SweepSpec.recordSeconds)
        lastRecording = rec
        analyzing = true
        status = "Analysiere …"
        let r = await Task.detached(priority: .userInitiated) { SessionStore.analyzer.analyze(recording: rec) }.value
        result = r
        analyzing = false
        status = String(format: "Fertig. Sweep bei %.2f s gefunden.", Double(r.quality.offset ?? 0) / SweepSpec.sampleRate)
    }
}

/// Linien-Chart mit logarithmischer Frequenzachse fuer eine oder mehrere Kurven.
struct ResultChart: View {
    let curves: [(name: String, freq: [Double], db: [Double])]
    var yDomain: ClosedRange<Double> = -20...20

    var body: some View {
        Chart {
            ForEach(curves.indices, id: \.self) { c in
                let cur = curves[c]
                ForEach(cur.freq.indices, id: \.self) { i in
                    LineMark(x: .value("Hz", cur.freq[i]), y: .value("dB", max(yDomain.lowerBound, min(yDomain.upperBound, cur.db[i]))))
                        .foregroundStyle(by: .value("Kurve", cur.name))
                        .interpolationMethod(.catmullRom)
                }
            }
            RuleMark(y: .value("0 dB", 0)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4]))
        }
        .chartXScale(domain: 20...20000, type: .log)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let f = v.as(Double.self) {
                        Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9))
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis { AxisMarks(values: .stride(by: 5)) }
        .chartLegend(curves.count > 1 ? .visible : .hidden)
    }
}

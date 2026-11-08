import Charts
import RaummodeDSP
import SwiftUI

/// Echtzeit-Analysator: 1/3-Oktav-Balken aus den Live-Bloecken des CaptureEngine.
struct RTAView: View {
    @EnvironmentObject var capture: CaptureEngine
    @EnvironmentObject var session: SessionStore

    @State private var display: [Double] = Array(repeating: -100, count: 31)
    @State private var slow = true
    @State private var averaging = false
    @State private var avgPower: [Double] = Array(repeating: 0, count: 31)
    @State private var avgCount = 0
    @State private var positionName = "RTA"
    @State private var normalize = true

    private let nominal = ThirdOctave.nominal

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                chart
                    .frame(maxHeight: .infinity)
                controls
            }
            .padding()
            .navigationTitle("RTA 1/3 Oktave")
            .onAppear { installHandler() }
            .onDisappear { capture.liveBlockHandler = nil }
        }
    }

    private var shown: [Double] {
        guard normalize else { return display }
        // Mittel 300 Hz .. 3 kHz auf 0 dB, damit die Kurve unabhaengig von der Lautstaerke lesbar ist
        let idx = nominal.indices.filter { nominal[$0] >= 300 && nominal[$0] <= 3000 }
        let mean = idx.map { display[$0] }.reduce(0, +) / Double(max(1, idx.count))
        return display.map { $0 - mean }
    }

    private var chart: some View {
        let data = shown
        return Chart {
            ForEach(nominal.indices, id: \.self) { i in
                BarMark(x: .value("Band", bandLabel(nominal[i])), y: .value("dB", max(-40, min(30, data[i]))))
                    .foregroundStyle(nominal[i] < 300 ? Color.orange : Color.accentColor)
            }
            if normalize {
                RuleMark(y: .value("0 dB", 0)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4]))
            }
        }
        .chartYScale(domain: normalize ? -30...20 : -100...0)
        .chartXAxis {
            AxisMarks(values: .automatic) { v in
                AxisValueLabel(orientation: .vertical).font(.system(size: 9))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(String(format: "Pegel %.0f dBFS", capture.levelDbfs)).monospacedDigit()
                Spacer()
                Toggle("Normiert", isOn: $normalize).toggleStyle(.button)
                Toggle(slow ? "Slow" : "Fast", isOn: $slow).toggleStyle(.button)
            }
            HStack {
                Button(averaging ? "Mittelung stoppen (\(avgCount))" : "Mittelung starten") {
                    if averaging { averaging = false } else {
                        avgPower = Array(repeating: 0, count: 31); avgCount = 0; averaging = true
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                TextField("Name", text: $positionName).textFieldStyle(.roundedBorder).frame(width: 120)
                Button("Speichern") { saveAverage() }
                    .disabled(avgCount == 0 || averaging)
            }
            Text("Am PC pink_noise_60s.wav abspielen, Handy an den Hoerplatz, Mittelung 20–30 s laufen lassen. Orange = Bassbereich (Raummoden).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func bandLabel(_ f: Double) -> String {
        f >= 1000 ? String(format: f.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", f / 1000)
                  : (f == 31.5 ? "31.5" : String(format: "%.0f", f))
    }

    private func installHandler() {
        capture.liveBlockHandler = { block in
            let levels = ThirdOctave.levelsSingleBlock(block)
            Task { @MainActor in
                let alpha = slow ? 0.15 : 0.5
                for i in 0..<31 {
                    display[i] = display[i] < -99 ? levels[i] : display[i] + alpha * (levels[i] - display[i])
                }
                if averaging {
                    for i in 0..<31 { avgPower[i] += pow(10, levels[i] / 10) }
                    avgCount += 1
                }
            }
        }
    }

    private func saveAverage() {
        let db = avgPower.map { 10 * log10($0 / Double(max(1, avgCount)) + 1e-30) }
        let freq = ThirdOctave.exact
        let norm = Smoothing.normalize(freq: freq, db: db)
        let q = Quality(snrDb: -1, peakDbfs: capture.levelDbfs, corr: -1)
        session.add(Position(name: positionName, mode: .rta, smoothing: "1/3", freq: freq, db: norm, quality: q))
        session.message = "RTA-Position \"\(positionName)\" zur Session hinzugefuegt"
        avgCount = 0
    }
}

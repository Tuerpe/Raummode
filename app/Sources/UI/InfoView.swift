import RaummodeDSP
import SwiftUI

struct InfoView: View {
    @EnvironmentObject var capture: CaptureEngine

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    row("Status", capture.isRunning ? "laeuft" : (capture.permissionDenied ? "Mikrofon verweigert" : "gestoppt"))
                    row("Eingang", capture.inputDescription)
                    row("Hardware-Rate", String(format: "%.0f Hz", capture.hardwareSampleRate))
                    row("Verarbeitung", "\(Int(SweepSpec.sampleRate)) Hz, Float32, mono")
                    if let e = capture.lastError { Text(e).foregroundStyle(.red) }
                    Button("Audio neu starten") { capture.stop(); capture.start() }
                }
                Section("Geraet") {
                    row("Modell", DeviceInfo.model)
                    row("iOS", UIDevice.current.systemVersion)
                }
                Section("Sweep-Referenz") {
                    row("Sweep", "\(Int(SweepSpec.f1))–\(Int(SweepSpec.f2)) Hz, \(Int(SweepSpec.duration)) s")
                    row("Aufnahme", "\(Int(SweepSpec.recordSeconds)) s")
                    row("Glaettung", "1/\(Smoothing.defaultFraction) Oktave")
                    row("Normierung", "300 Hz – 3 kHz = 0 dB")
                }
                Section("Ablauf") {
                    Text("""
                    1. Am PC: eqapo_toggle.ps1 -Modus Messen, Sound-Blaster-Effekte aus.
                    2. Handy am Hoerplatz auf Ohrhoehe, Mikro (unten) Richtung Lautsprecher, nicht in der Hand halten.
                    3. Tab Sweep: Aufnahme starten, sofort am PC sweep_20-20k_10s.wav abspielen.
                    4. Position benennen, zur Session hinzufuegen. 3–5 Positionen um den Hoerplatz.
                    5. Tab Session: JSON speichern, teilen oder per WLAN-Server an den PC.
                    6. Am PC: python pc/analyze.py messungen/<ordner>
                    """).font(.footnote)
                }
            }
            .navigationTitle("Info")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}

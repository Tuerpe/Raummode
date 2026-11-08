import AVFoundation
import Foundation
import RaummodeDSP

/// Mikrofon-Aufnahme im Messmodus: AVAudioSession .measurement (keine AGC, kein
/// Rauschfilter), unteres Mikro, Kugelcharakteristik, 48 kHz Float32 mono.
/// Liefert Live-Bloecke fuer den RTA und 15-s-Aufnahmen fuer die Sweep-Messung.
@MainActor
final class CaptureEngine: ObservableObject {
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var hardwareSampleRate: Double = 0
    @Published var inputDescription = "-"
    @Published var levelDbfs: Double = -120
    @Published var lastError: String?
    @Published var isRecording = false
    @Published var recordingProgress: Double = 0

    /// Wird mit dem letzten Block (16384 Samples @ 48 kHz) auf einem Hintergrund-Thread gerufen.
    nonisolated(unsafe) var liveBlockHandler: ((_ block: [Double]) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SweepSpec.sampleRate,
                                             channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var liveBuffer: [Double] = []
    private let liveBlockSize = 16384
    private var recordBuffer: [Float] = []
    private var recordTarget = 0
    private var recordContinuation: CheckedContinuation<[Double], Never>?

    func requestPermissionAndStart() async {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
        }
        guard granted else { permissionDenied = true; return }
        start()
    }

    func start() {
        guard !isRunning else { return }
        do {
            try configureSession()
            let input = engine.inputNode
            let hwFormat = input.outputFormat(forBus: 0)
            hardwareSampleRate = hwFormat.sampleRate
            if hwFormat.sampleRate != targetFormat.sampleRate || hwFormat.channelCount != 1 {
                converter = AVAudioConverter(from: hwFormat, to: targetFormat)
            } else {
                converter = nil
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
            describeInput()
        } catch {
            lastError = "Audio-Start fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: [])
        try s.setPreferredSampleRate(SweepSpec.sampleRate)
        try s.setPreferredIOBufferDuration(0.02)
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try s.setPreferredInput(mic)
            if let bottom = mic.dataSources?.first(where: { $0.orientation == .bottom }) {
                if bottom.supportedPolarPatterns?.contains(.omnidirectional) == true {
                    try? bottom.setPreferredPolarPattern(.omnidirectional)
                }
                try? mic.setPreferredDataSource(bottom)
            }
        }
        try s.setActive(true)
    }

    private func describeInput() {
        let s = AVAudioSession.sharedInstance()
        guard let port = s.currentRoute.inputs.first else { inputDescription = "kein Eingang"; return }
        var parts = [port.portName]
        if let ds = port.selectedDataSource {
            parts.append(ds.dataSourceName)
            if let p = ds.selectedPolarPattern { parts.append(p.rawValue) }
        }
        parts.append("\(Int(s.sampleRate)) Hz")
        parts.append("Modus \(s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))")
        inputDescription = parts.joined(separator: " · ")
    }

    // MARK: - Audio-Thread

    private nonisolated func handle(buffer: AVAudioPCMBuffer) {
        let samples: [Float]
        if let conv = converterRef() {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
            var consumed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData else { return }
            samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        } else {
            guard let ch = buffer.floatChannelData else { return }
            samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        guard !samples.isEmpty else { return }

        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        let db = 20 * log10(Double(peak) + 1e-9)

        var blockToDeliver: [Double]?
        var finished: (CheckedContinuation<[Double], Never>, [Double])?
        var progress: Double?

        lock.lock()
        liveBuffer.append(contentsOf: samples.map { Double($0) })
        if liveBuffer.count >= liveBlockSize {
            blockToDeliver = Array(liveBuffer.suffix(liveBlockSize))
            liveBuffer.removeFirst(liveBuffer.count - liveBlockSize / 2)
        }
        if recordTarget > 0 {
            recordBuffer.append(contentsOf: samples)
            progress = min(1, Double(recordBuffer.count) / Double(recordTarget))
            if recordBuffer.count >= recordTarget, let c = recordContinuation {
                let rec = recordBuffer.prefix(recordTarget).map { Double($0) }
                recordBuffer = []
                recordTarget = 0
                recordContinuation = nil
                finished = (c, rec)
            }
        }
        lock.unlock()

        if let b = blockToDeliver { liveBlockHandler?(b) }
        Task { @MainActor in
            self.levelDbfs = db
            if let p = progress { self.recordingProgress = p }
            if finished != nil { self.isRecording = false; self.recordingProgress = 1 }
        }
        if let (c, rec) = finished { c.resume(returning: rec) }
    }

    private nonisolated func converterRef() -> AVAudioConverter? {
        // Converter wird nur beim Start gesetzt; Lesen ohne Lock ist hier unkritisch.
        MainActor.assumeIsolated { converter }
    }

    /// Nimmt `seconds` Sekunden (48 kHz) auf und liefert die Samples.
    func record(seconds: Double) async -> [Double] {
        if !isRunning { start() }
        isRecording = true
        recordingProgress = 0
        return await withCheckedContinuation { c in
            lock.lock()
            recordBuffer = []
            recordBuffer.reserveCapacity(Int(seconds * SweepSpec.sampleRate))
            recordTarget = Int(seconds * SweepSpec.sampleRate)
            recordContinuation = c
            lock.unlock()
        }
    }
}

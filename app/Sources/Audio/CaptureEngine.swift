import AVFoundation
import Foundation
import RaummodeDSP

/// Zustand, den der Audio-Thread beschreibt. Bewusst NICHT auf dem MainActor,
/// Zugriff ausschliesslich unter `lock`.
final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var liveBuffer: [Double] = []
    private var recordBuffer: [Float] = []
    private var recordTarget = 0
    private var recordContinuation: CheckedContinuation<[Double], Never>?
    private var handler: ((_ block: [Double]) -> Void)?
    private var converter: AVAudioConverter?

    let liveBlockSize = 16384
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SweepSpec.sampleRate,
                                     channels: 1, interleaved: false)!

    struct Update {
        var peakDb: Double
        var progress: Double?
        var finished: Bool
    }

    func setConverter(_ c: AVAudioConverter?) {
        lock.lock(); converter = c; lock.unlock()
    }

    func setLiveBlockHandler(_ h: ((_ block: [Double]) -> Void)?) {
        lock.lock(); handler = h; lock.unlock()
    }

    func beginRecording(samples: Int, continuation: CheckedContinuation<[Double], Never>) {
        lock.lock()
        recordBuffer = []
        recordBuffer.reserveCapacity(samples)
        recordTarget = samples
        recordContinuation = continuation
        lock.unlock()
    }

    /// Wird vom Audio-Tap gerufen. Konvertiert auf 48 kHz mono, fuellt Live- und
    /// Aufnahmepuffer, liefert Pegel/Fortschritt fuer die Oberflaeche.
    func process(_ buffer: AVAudioPCMBuffer) -> Update? {
        lock.lock()
        let conv = converter
        lock.unlock()

        let samples: [Float]
        if let conv {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return nil }
            var consumed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData else { return nil }
            samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        } else {
            guard let ch = buffer.floatChannelData else { return nil }
            samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        guard !samples.isEmpty else { return nil }

        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }

        var block: [Double]?
        var blockHandler: ((_ block: [Double]) -> Void)?
        var finished: (CheckedContinuation<[Double], Never>, [Double])?
        var progress: Double?

        lock.lock()
        liveBuffer.append(contentsOf: samples.map { Double($0) })
        if liveBuffer.count >= liveBlockSize {
            block = Array(liveBuffer.suffix(liveBlockSize))
            blockHandler = handler
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

        if let b = block, let h = blockHandler { h(b) }
        if let (c, rec) = finished { c.resume(returning: rec) }
        return Update(peakDb: 20 * log10(Double(peak) + 1e-9), progress: progress, finished: finished != nil)
    }
}

/// Mikrofon-Aufnahme im Messmodus: AVAudioSession .measurement (keine AGC, kein
/// Rauschfilter), unteres Mikro, Kugelcharakteristik, 48 kHz Float32 mono.
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
    var liveBlockHandler: ((_ block: [Double]) -> Void)? {
        didSet { state.setLiveBlockHandler(liveBlockHandler) }
    }

    private let engine = AVAudioEngine()
    private let state = CaptureState()

    func requestPermissionAndStart() async {
        let granted = await AVAudioApplication.requestRecordPermission()
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
            if hwFormat.sampleRate != state.targetFormat.sampleRate || hwFormat.channelCount != 1 {
                state.setConverter(AVAudioConverter(from: hwFormat, to: state.targetFormat))
            } else {
                state.setConverter(nil)
            }
            input.removeTap(onBus: 0)
            let st = state
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                guard let update = st.process(buffer) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.levelDbfs = update.peakDb
                    if let p = update.progress { self.recordingProgress = p }
                    if update.finished { self.isRecording = false; self.recordingProgress = 1 }
                }
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

    /// Nimmt `seconds` Sekunden (48 kHz) auf und liefert die Samples.
    func record(seconds: Double) async -> [Double] {
        if !isRunning { start() }
        isRecording = true
        recordingProgress = 0
        let n = Int(seconds * SweepSpec.sampleRate)
        return await withCheckedContinuation { c in
            state.beginRecording(samples: n, continuation: c)
        }
    }
}

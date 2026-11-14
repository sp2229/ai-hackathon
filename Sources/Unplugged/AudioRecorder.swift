import AVFoundation
import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone, system, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "Computer audio"
        case .both: return "Both"
        }
    }
    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .both: return "person.2.wave.2.fill"
        }
    }
    var hint: String {
        switch self {
        case .microphone: return "In-person lectures, meetings, and site visits."
        case .system: return "Anything playing on this Mac — e.g. a Zoom recording in your browser."
        case .both: return "Live Zoom / Teams / Meet calls: their audio + your voice."
        }
    }
}

/// Records straight to 16 kHz mono PCM — the exact format Whisper consumes —
/// so no resampling work is needed later and files stay small (~1.9 MB/min).
/// Sources: microphone (AVAudioRecorder), computer audio (ScreenCaptureKit), or both (mixed on stop).
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 48)
    @Published var source: AudioSource = .microphone

    private var mic: AVAudioRecorder?
    private var system: SystemAudioCapture?
    private var timer: Timer?
    private var outputURL: URL?
    private var micURL: URL?
    private var systemURL: URL?
    private var startedAt = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    var onError: ((String) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    func start(to url: URL, source: AudioSource) async throws {
        self.source = source
        outputURL = url
        let dir = url.deletingLastPathComponent()
        micURL = source == .both ? dir.appendingPathComponent("mic.wav") : url
        systemURL = source == .both ? dir.appendingPathComponent("system.wav") : url

        if source != .microphone {
            let cap = SystemAudioCapture()
            cap.onError = { [weak self] msg in Task { @MainActor in self?.onError?(msg) } }
            try await cap.start(to: systemURL!)
            system = cap
        }
        if source != .system {
            let rec = try AVAudioRecorder(url: micURL!, settings: Self.wavSettings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                await system?.stop(); system = nil
                throw NSError(domain: "Unplugged", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Could not start recording. Check microphone permission in System Settings › Privacy & Security."])
            }
            mic = rec
        }

        isRecording = true
        isPaused = false
        elapsed = 0
        startedAt = Date()
        pausedTotal = 0
        pausedAt = nil
        levels = Array(repeating: 0, count: levels.count)
        // 10 Hz UI refresh is plenty for a level meter and keeps CPU wakeups low.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func togglePause() {
        if isPaused {
            mic?.record()
            if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p) }
            pausedAt = nil
        } else {
            mic?.pause()
            pausedAt = Date()
        }
        isPaused.toggle()
        system?.setPaused(isPaused)
    }

    /// Stops all sources, mixes if needed, and returns the duration in seconds.
    @discardableResult
    func stop() async -> TimeInterval {
        timer?.invalidate()
        timer = nil
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        isRecording = false
        isPaused = false

        if source == .both, let a = micURL, let b = systemURL, let out = outputURL {
            do {
                try AudioMixer.mix(a, b, into: out)
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            } catch {
                // Fall back to whichever track exists
                try? FileManager.default.moveItem(at: b, to: out)
            }
        }
        if let out = outputURL {
            let d = await Self.duration(of: out)
            if d > 0 { return d }
        }
        return elapsed
    }

    private func tick() {
        let paused = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = Date().timeIntervalSince(startedAt) - pausedTotal - paused

        var level: Float = 0
        if let m = mic {
            m.updateMeters()
            let db = m.averagePower(forChannel: 0)            // -160...0
            level = max(0, min(1, (db + 50) / 50))
        }
        if let s = system { level = max(level, s.level) }
        levels.removeFirst()
        levels.append(isPaused ? 0 : level)
    }

    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        return d.seconds.isFinite ? d.seconds : 0
    }
}

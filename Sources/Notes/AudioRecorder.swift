import AVFoundation
import Foundation

/// Records straight to 16 kHz mono PCM — the exact format Whisper consumes —
/// so no resampling work is needed later and files stay small (~1.9 MB/min).
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 48)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw NSError(domain: "Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start recording. Check microphone permission in System Settings › Privacy."]) }
        recorder = rec
        isRecording = true
        isPaused = false
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        // 10 Hz UI refresh is plenty for a level meter and keeps CPU wakeups low.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func togglePause() {
        guard let rec = recorder else { return }
        if isPaused { rec.record() } else { rec.pause() }
        isPaused.toggle()
    }

    @discardableResult
    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        return max(duration, elapsed)
    }

    private func tick() {
        guard let rec = recorder else { return }
        elapsed = rec.currentTime
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)            // -160...0
        let norm = isPaused ? 0 : max(0, min(1, (db + 50) / 50))
        levels.removeFirst()
        levels.append(norm)
    }

    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        return d.seconds.isFinite ? d.seconds : 0
    }
}

import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures the Mac's system audio (Zoom, Teams, Meet, a browser tab playing a recording…)
/// with ScreenCaptureKit, written straight to 16 kHz mono WAV — Whisper's native format.
///
/// Efficiency: ScreenCaptureKit always runs a video stream, so we ask for a 2×2-pixel frame
/// once per second and ignore it. Only the audio is kept.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "notes.system-audio")
    private let lock = NSLock()
    private var paused = false
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Latest RMS level 0…1, polled by the UI.
    private(set) var level: Float = 0
    var onError: ((String) -> Void)?

    static let sampleRate = 16_000

    func start(to url: URL) async throws {
        // Throws (and triggers the system permission prompt) if Screen & System Audio Recording isn't allowed.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "Unplugged", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "Unplugged needs permission to record computer audio. Open System Settings › Privacy & Security › Screen & System Audio Recording, turn on Unplugged, then quit and reopen Unplugged."])
        }
        guard let display = content.displays.first else {
            throw NSError(domain: "Unplugged", code: 21, userInfo: [NSLocalizedDescriptionKey: "No display found for audio capture."])
        }

        // Don't record our own app's sounds.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 1
        // Minimal video work — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        framesWritten = 0

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)   // required; frames are dropped
        try await s.startCapture()
        stream = s
    }

    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; lock.unlock()
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        queue.sync { file = nil }   // flush & close
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let file else { return }
        lock.lock(); let isPaused = paused; lock.unlock()

        guard let desc = sampleBuffer.formatDescription,
              let asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: AVAudioChannelCount(asbd.mChannelsPerFrame)) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr, let ch = pcm.floatChannelData else { return }

        // Level meter (RMS of channel 0)
        var sum: Float = 0
        for i in 0..<Int(frames) { sum += ch[0][i] * ch[0][i] }
        let rms = sqrt(sum / Float(frames))
        level = isPaused ? 0 : min(1, rms * 6)

        guard !isPaused else { return }
        do {
            if format.channelCount == 1 && format.sampleRate == file.processingFormat.sampleRate {
                try file.write(from: pcm)
            } else if let conv = AVAudioConverter(from: format, to: file.processingFormat) {
                let ratio = file.processingFormat.sampleRate / format.sampleRate
                let cap = AVAudioFrameCount(Double(frames) * ratio) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else { return }
                var fed = false
                _ = conv.convert(to: out, error: nil) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return pcm
                }
                try file.write(from: out)
            }
            framesWritten = file.length
        } catch {
            onError?("Couldn't write system audio: \(error.localizedDescription)")
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Computer-audio capture stopped: \(error.localizedDescription)")
    }
}

/// Mixes two 16 kHz mono WAVs (microphone + computer audio) into one file for transcription.
enum AudioMixer {
    static func mix(_ a: URL, _ b: URL, into out: URL) throws {
        let fa = try AVAudioFile(forReading: a)
        let fb = try AVAudioFile(forReading: b)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(SystemAudioCapture.sampleRate), channels: 1)!
        let sa = try read(fa, as: format)
        let sb = try read(fb, as: format)
        let n = max(sa.count, sb.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(n, 1))) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        for i in 0..<n {
            let v = (i < sa.count ? sa[i] : 0) + (i < sb.count ? sb[i] : 0)
            dst[i] = max(-1, min(1, v))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: SystemAudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let w = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try w.write(from: buf)
    }

    private static func read(_ f: AVAudioFile, as format: AVAudioFormat) throws -> [Float] {
        guard f.length > 0, let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try f.read(into: src)
        if f.processingFormat.sampleRate == format.sampleRate, f.processingFormat.channelCount == 1, let ch = src.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(src.frameLength)))
        }
        guard let conv = AVAudioConverter(from: f.processingFormat, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * format.sampleRate / f.processingFormat.sampleRate) + 32)
        else { return [] }
        var fed = false
        _ = conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return src
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

import Foundation
import WhisperKit
import SpeakerKit

/// On-device speech pipeline powered by Argmax:
///   • WhisperKit  → speech-to-text on the Apple Neural Engine
///   • SpeakerKit  → speaker diarization ("who spoke when")
///
/// Models are loaded only while a recording is being processed and unloaded right
/// after, so no AI runs in the background while you're idle.
enum WhisperChoice: String, CaseIterable, Identifiable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"
    case turbo = "large-v3-v20240930_626MB"

    var id: String { rawValue }
    var folderName: String { "openai_whisper-\(rawValue)" }
    var label: String {
        switch self {
        case .tiny: return "Tiny · fastest, lowest energy"
        case .base: return "Base · balanced"
        case .small: return "Small · more accurate"
        case .turbo: return "Large v3 Turbo · best, multilingual"
        }
    }
}

struct TranscriptionOutput {
    var lines: [TranscriptLine]
    var transcribeSeconds: Double
    var diarizeSeconds: Double
}

actor Transcriber {
    static let shared = Transcriber()

    private var hubBase: URL { Paths.argmaxModels }
    private var whisperRepoDir: URL {
        hubBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }
    private var speakerRepoDir: URL {
        hubBase.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    nonisolated func whisperFolder(_ m: WhisperChoice) -> URL {
        Paths.argmaxModels.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(m.folderName)", isDirectory: true)
    }

    nonisolated func isWhisperReady(_ m: WhisperChoice) -> Bool {
        FileManager.default.fileExists(atPath: whisperFolder(m).appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    nonisolated func isSpeakerKitReady() -> Bool {
        let dir = Paths.argmaxModels.appendingPathComponent("models/argmaxinc/speakerkit-coreml")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !items.filter { !$0.hasPrefix(".") }.isEmpty
    }

    /// One-time download (needs internet). Afterwards everything loads from disk.
    func downloadModels(whisper: WhisperChoice, progress: @escaping @Sendable (String) -> Void) async throws {
        if !isWhisperReady(whisper) {
            progress("Downloading Whisper \(whisper.rawValue)…")
            _ = try await WhisperKit.download(variant: whisper.rawValue, downloadBase: hubBase) { p in
                progress("Downloading Whisper \(whisper.rawValue)… \(Int(p.fractionCompleted * 100))%")
            }
            // Load once so the tokenizer is cached next to the model, then release.
            let kit = try await makeWhisper(whisper)
            await kit.unloadModels()
        }
        if !isSpeakerKitReady() {
            progress("Downloading SpeakerKit diarization models…")
            let sk = try await SpeakerKit(PyannoteConfig(downloadBase: hubBase.path, download: true, load: true, verbose: false))
            await sk.unloadModels()
        }
        progress("Models ready")
    }

    private func makeWhisper(_ m: WhisperChoice) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: m.rawValue,
            downloadBase: hubBase,
            modelFolder: whisperFolder(m).path,
            tokenizerFolder: hubBase,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false   // offline: never touch the network at runtime
        )
        return try await WhisperKit(config)
    }

    func transcribe(audio url: URL,
                    model: WhisperChoice,
                    diarize: Bool,
                    status: @escaping @Sendable (String) -> Void) async throws -> TranscriptionOutput {
        guard isWhisperReady(model) else {
            throw NSError(domain: "Unplugged", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Whisper model \(model.rawValue) isn't downloaded yet. Open Settings › Models and download it once (requires internet)."])
        }

        status("Loading Argmax WhisperKit…")
        let whisper = try await makeWhisper(model)
        defer { Task { await whisper.unloadModels() } }

        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)

        status("Transcribing on the Neural Engine…")
        let t0 = Date()
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: model == .turbo ? nil : "en",
            skipSpecialTokens: true,
            wordTimestamps: diarize,               // only pay for word timings when we need them
            chunkingStrategy: .vad                 // skip silence → less compute on long recordings
        )
        let results = await whisper.transcribe(audioArrays: [audio], decodeOptions: options)
        guard let result = results.first ?? nil else {
            throw NSError(domain: "Unplugged", code: 3, userInfo: [NSLocalizedDescriptionKey: "Transcription failed."])
        }
        let transcribeSeconds = Date().timeIntervalSince(t0)
        var diarizeSeconds = 0.0
        var lines: [TranscriptLine] = []

        if diarize && isSpeakerKitReady() {
            status("Identifying speakers with SpeakerKit…")
            let t1 = Date()
            do {
                let sk = try await SpeakerKit(PyannoteConfig(downloadBase: hubBase.path, download: false, verbose: false))
                let diar = try await sk.diarize(audioArray: audio)
                let grouped = diar.addSpeakerInfo(to: result)
                await sk.unloadModels()
                for group in grouped {
                    for seg in group {
                        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let name = seg.speaker.speakerId.map { "Speaker \($0 + 1)" }
                        // Merge consecutive lines from the same speaker for readability
                        if var last = lines.last, last.speaker == name, Double(seg.startTime) - last.end < 1.5 {
                            last.text += " " + text
                            last.end = Double(seg.endTime)
                            lines[lines.count - 1] = last
                        } else {
                            lines.append(TranscriptLine(start: Double(seg.startTime), end: Double(seg.endTime), speaker: name, text: text))
                        }
                    }
                }
            } catch {
                lines = []   // fall back to plain transcript below
            }
            diarizeSeconds = Date().timeIntervalSince(t1)
        }

        if lines.isEmpty {
            lines = result.flatMap { $0.segments }.compactMap { seg in
                let text = Self.clean(seg.text)
                return text.isEmpty ? nil : TranscriptLine(start: Double(seg.start), end: Double(seg.end), speaker: nil, text: text)
            }
        }
        return TranscriptionOutput(lines: lines, transcribeSeconds: transcribeSeconds, diarizeSeconds: diarizeSeconds)
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

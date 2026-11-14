import Foundation
import SwiftUI

/// `Unplugged --selftest <audio> [template] [--context file]... [--render out.png]`
/// Runs the whole on-device pipeline without UI, prints the result, and optionally
/// renders the notes view to a PNG. Handy for verifying an offline setup.
enum SelfTest {
    static func run(args: [String]) async {
        @Sendable func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { exit(2) }
        let audio = URL(fileURLWithPath: args[i + 1])
        let template = NoteTemplate.find(i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : "meeting")
        var contextFiles: [URL] = []
        var renderPath: String?
        var j = 0
        while j < args.count {
            if args[j] == "--context", j + 1 < args.count { contextFiles.append(URL(fileURLWithPath: args[j + 1])) }
            if args[j] == "--render", j + 1 < args.count { renderPath = args[j + 1] }
            j += 1
        }

        let whisper = WhisperChoice(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .base
        do {
            if !Transcriber.shared.isWhisperReady(whisper) || !Transcriber.shared.isSpeakerKitReady() {
                try await Transcriber.shared.downloadModels(whisper: whisper) { log($0) }
            }
            var docs: [ContextDoc] = []
            for f in contextFiles {
                let d = try await DocumentImporter.extract(f)
                log("Context: \(d.name) [\(d.kind)] \(d.text.count) chars")
                docs.append(d)
            }

            let out = try await Transcriber.shared.transcribe(audio: audio, model: whisper, diarize: template.diarize) { log("· " + $0) }
            log(String(format: "Transcribed in %.2fs, diarized in %.2fs", out.transcribeSeconds, out.diarizeSeconds))
            var s = Session(title: "selftest", templateID: template.id)
            s.transcript = out.lines
            print("=== TRANSCRIPT ===\n" + s.plainTranscript)

            let size = BonsaiEngine.installed().first ?? .b4
            let reference = await AppModel.referenceBlock(docs)
            let (notes, u) = try await BonsaiEngine.shared.generate(
                size: size, system: template.systemPrompt,
                user: reference + "Transcript:\n\(s.plainTranscript)", maxTokens: template.maxTokens) { _ in }
            print("=== NOTES (\(template.name), Bonsai \(size.rawValue)) ===\n" + notes)
            log(String(format: "LLM: %d prompt + %d completion tokens in %.2fs", u.promptTokens, u.completionTokens, u.seconds))

            if let renderPath {
                await render(notes: notes, template: template, to: renderPath)
                log("Rendered → \(renderPath)")
            }
        } catch {
            log("SELFTEST FAILED: \(error.localizedDescription)")
        }
        await BonsaiEngine.shared.stop()
        exit(0)
    }

    /// `Unplugged --render-md <file.md> <template> <out.png>` — render existing Markdown (no models needed).
    static func renderMarkdown(args: [String]) async {
        guard let i = args.firstIndex(of: "--render-md"), i + 3 < args.count,
              let md = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { exit(2) }
        await render(notes: md, template: NoteTemplate.find(args[i + 2]), to: args[i + 3])
        exit(0)
    }

    @MainActor
    static func render(notes: String, template: NoteTemplate, to path: String) {
        let view = NotesRenderer(markdown: notes, template: template)
            .padding(32)
            .frame(width: 860)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .tint(.brand)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = SessionStore.loadAll()
    @Published var selection: UUID?
    @Published var stage: [UUID: String] = [:]          // live status text per session
    @Published var liveNotes: [UUID: String] = [:]      // streaming tokens
    @Published var alert: String?
    @Published var modelStatus: String = ""
    @Published var isDownloading = false
    @Published var recordingTemplate: NoteTemplate = NoteTemplate.find("lecture")
    @Published var templateCategory: TemplateCategory = .classType
    /// Slides/notes attached before recording; moved onto the next session.
    @Published var pendingContext: [ContextDoc] = []
    @Published var importingContext = false

    let recorder = AudioRecorder()
    private var recordingSession: Session?

    // Settings (persisted)
    @AppStorage("whisperModel") var whisperModelRaw: String = WhisperChoice.base.rawValue
    @AppStorage("bonsaiModel") var bonsaiModelRaw: String = BonsaiSize.b4.rawValue
    @AppStorage("diarizationEnabled") var diarizationEnabled: Bool = true

    var whisperModel: WhisperChoice { WhisperChoice(rawValue: whisperModelRaw) ?? .base }
    var bonsaiModel: BonsaiSize {
        let wanted = BonsaiSize(rawValue: bonsaiModelRaw) ?? .b4
        let installed = BonsaiEngine.installed()
        return installed.contains(wanted) ? wanted : (installed.first ?? wanted)
    }

    var argmaxReady: Bool { Transcriber.shared.isWhisperReady(whisperModel) }
    var bonsaiReady: Bool { BonsaiEngine.serverInstalled && !BonsaiEngine.installed().isEmpty }

    var selected: Session? {
        get { sessions.first { $0.id == selection } }
    }

    func binding(for id: UUID) -> Binding<Session>? {
        guard sessions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.sessions.first { $0.id == id } ?? Session(title: "", templateID: "general") },
            set: { new in self.update(new) }
        )
    }

    private func update(_ s: Session) {
        guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions[i] = s
        SessionStore.save(s)
    }

    private func mutate(_ id: UUID, _ f: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        f(&sessions[i])
        SessionStore.save(sessions[i])
    }

    // MARK: - Recording

    func startRecording() async {
        guard await AudioRecorder.requestPermission() else {
            alert = "Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone."
            return
        }
        let t = recordingTemplate
        var session = Session(title: Self.defaultTitle(for: t), templateID: t.id)
        session.context = pendingContext.isEmpty ? nil : pendingContext
        do {
            try recorder.start(to: Paths.audio(for: session))
            recordingSession = session
            pendingContext = []
        } catch {
            alert = error.localizedDescription
        }
    }

    func stopRecording() {
        guard var session = recordingSession else { return }
        session.duration = recorder.stop()
        recordingSession = nil
        sessions.insert(session, at: 0)
        SessionStore.save(session)
        selection = session.id
        Task { await process(session.id) }
    }

    func cancelRecording() {
        guard let session = recordingSession else { return }
        recorder.stop()
        recordingSession = nil
        SessionStore.delete(session)
    }

    func importAudio(_ url: URL) {
        let t = recordingTemplate
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        var session = Session(title: url.deletingPathExtension().lastPathComponent, templateID: t.id)
        session.audioFile = "audio.\(ext)"
        session.context = pendingContext.isEmpty ? nil : pendingContext
        pendingContext = []
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: Paths.audio(for: session))
        } catch {
            alert = "Couldn't import file: \(error.localizedDescription)"
            return
        }
        sessions.insert(session, at: 0)
        SessionStore.save(session)
        selection = session.id
        Task {
            let d = await AudioRecorder.duration(of: Paths.audio(for: session))
            mutate(session.id) { $0.duration = d }
            await process(session.id)
        }
    }

    static func defaultTitle(for t: NoteTemplate) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return "\(t.name) · \(f.string(from: Date()))"
    }

    // MARK: - Pipeline

    /// Full pipeline: Argmax transcription (+ diarization) → Bonsai notes.
    func process(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let template = session.template
        let diarize = template.diarize && diarizationEnabled
        let model = whisperModel

        mutate(id) { $0.status = .transcribing; $0.error = nil }
        stage[id] = "Preparing…"
        do {
            let out = try await Transcriber.shared.transcribe(
                audio: Paths.audio(for: session), model: model, diarize: diarize
            ) { msg in
                Task { @MainActor in self.stage[id] = msg }
            }
            mutate(id) {
                $0.transcript = out.lines
                $0.stats.whisperModel = model.rawValue
                $0.stats.transcribeSeconds = out.transcribeSeconds
                $0.stats.diarizeSeconds = out.diarizeSeconds
            }
        } catch {
            fail(id, error)
            return
        }
        await summarize(id)
    }

    /// Re-generates notes only. Switching templates never re-runs transcription,
    /// so changing your mind costs a few seconds of LLM time, not minutes of audio work.
    func summarize(_ id: UUID, template newTemplate: NoteTemplate? = nil) async {
        if let t = newTemplate { mutate(id) { $0.templateID = t.id } }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let transcript = session.plainTranscript
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            mutate(id) { $0.status = .done; $0.notes = "_No speech was detected in this recording._" }
            stage[id] = nil
            return
        }

        let size = bonsaiModel
        mutate(id) { $0.status = .summarizing; $0.error = nil }
        liveNotes[id] = ""
        stage[id] = "Starting Bonsai \(size.rawValue)…"

        do {
            var usage = LLMUsage()
            let reference = Self.referenceBlock(session.context ?? [])
            let source = try await condenseIfNeeded(transcript, budget: 44_000 - reference.count, id: id, size: size, usage: &usage)
            stage[id] = "Writing \(session.template.name) notes with Bonsai \(size.rawValue)…"
            liveNotes[id] = ""
            let (notes, u) = try await BonsaiEngine.shared.generate(
                size: size,
                system: session.template.systemPrompt,
                user: reference + "Transcript:\n\(source)",
                maxTokens: session.template.maxTokens
            ) { piece in
                Task { @MainActor in self.liveNotes[id, default: ""] += piece }
            }
            usage.promptTokens += u.promptTokens
            usage.completionTokens += u.completionTokens
            usage.seconds += u.seconds
            mutate(id) {
                $0.notes = notes
                $0.status = .done
                $0.stats.llmModel = "Bonsai-2 \(size.rawValue)"
                $0.stats.llmSeconds += usage.seconds
                $0.stats.promptTokens += usage.promptTokens
                $0.stats.completionTokens += usage.completionTokens
                $0.stats.summaryRuns += 1
            }
            liveNotes[id] = nil
            stage[id] = nil
        } catch {
            liveNotes[id] = nil
            fail(id, error)
        }
    }

    /// Long recordings (> ~10k tokens) are condensed chunk-by-chunk first so they fit
    /// a small, efficient context window instead of loading a huge one.
    /// Attached slides/notes go in front of the transcript, capped at ~6k tokens total.
    static func referenceBlock(_ docs: [ContextDoc]) -> String {
        guard !docs.isEmpty else { return "" }
        let budget = 24_000
        let per = max(2_000, budget / docs.count)
        let body = docs.map { d in
            "### \(d.name) (\(d.kind))\n" + String(d.text.prefix(per))
        }.joined(separator: "\n\n")
        return """
        Reference material the user attached (slides, handouts, notes). Use it to spell terms and names \
        correctly, fill in equations or derivation steps the speaker referred to, and add precise definitions. \
        The transcript is the primary source — focus on what was actually discussed.
        <reference>
        \(String(body.prefix(budget)))
        </reference>


        """
    }

    private func condenseIfNeeded(_ text: String, budget: Int, id: UUID, size: BonsaiSize, usage: inout LLMUsage) async throws -> String {
        let limit = max(16_000, budget)   // characters ≈ tokens × 4
        guard text.count > limit else { return text }
        let chunks = Self.chunk(text, size: 28_000)
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            stage[id] = "Condensing part \(i + 1) of \(chunks.count)…"
            let (out, u) = try await BonsaiEngine.shared.generate(
                size: size,
                system: "Extract every important fact, decision, name, number, date, task and question from this transcript excerpt as terse bullet points. No commentary.",
                user: chunk, maxTokens: 900
            ) { _ in }
            usage.promptTokens += u.promptTokens
            usage.completionTokens += u.completionTokens
            usage.seconds += u.seconds
            parts.append("Part \(i + 1):\n\(out)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func chunk(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func fail(_ id: UUID, _ error: Error) {
        mutate(id) { $0.status = .failed; $0.error = error.localizedDescription }
        stage[id] = nil
    }

    // MARK: - Context documents

    /// Extracts text from files and attaches them to a session (or to the next recording if `id` is nil).
    func addContext(_ urls: [URL], to id: UUID?) async {
        importingContext = true
        defer { importingContext = false }
        var docs: [ContextDoc] = []
        for url in urls {
            do {
                let doc = try await Task.detached(priority: .userInitiated) { try await DocumentImporter.extract(url) }.value
                docs.append(doc)
            } catch {
                alert = error.localizedDescription
            }
        }
        guard !docs.isEmpty else { return }
        if let id {
            mutate(id) { $0.context = ($0.context ?? []) + docs }
        } else {
            pendingContext += docs
        }
    }

    func removeContext(_ docID: UUID, from id: UUID?) {
        if let id {
            mutate(id) { s in
                s.context?.removeAll { $0.id == docID }
                if s.context?.isEmpty == true { s.context = nil }
            }
        } else {
            pendingContext.removeAll { $0.id == docID }
        }
    }

    // MARK: - Library

    func delete(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        SessionStore.delete(s)
        sessions.removeAll { $0.id == id }
        if selection == id { selection = sessions.first?.id }
    }

    func downloadModels() async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            try await Transcriber.shared.downloadModels(whisper: whisperModel) { msg in
                Task { @MainActor in self.modelStatus = msg }
            }
            objectWillChange.send()
        } catch {
            modelStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    func markdown(for s: Session) -> String {
        var md = "# \(s.title)\n\n"
        md += "_\(s.template.name) · \(s.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.format(s.duration)) · processed 100% on-device_\n\n"
        md += s.notes + "\n\n---\n\n## Transcript\n\n"
        for l in s.transcript {
            md += "**[\(Self.format(l.start))]** " + (l.speaker.map { "**\($0):** " } ?? "") + l.text + "\n\n"
        }
        return md
    }

    func copyNotes(_ s: Session) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(for: s), forType: .string)
    }

    func exportMarkdown(_ s: Session) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = s.title.replacingOccurrences(of: "/", with: "-") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? markdown(for: s).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

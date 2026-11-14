import SwiftUI

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    @State private var tab: Tab = .notes
    @State private var attaching = false

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript", impact = "Impact" }

    var body: some View {
        if let binding = model.binding(for: id) {
            let s = binding.wrappedValue
            VStack(spacing: 0) {
                header(binding)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .notes: notes(s)
                        case .transcript: TranscriptView(lines: s.transcript)
                        case .impact: ImpactView(session: s)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .fileImporter(isPresented: $attaching, allowedContentTypes: DocumentImporter.allowedTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await model.addContext(urls, to: id) } }
            }
            .toolbar {
                ToolbarItemGroup {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    Button { attaching = true } label: { Label("Attach", systemImage: "paperclip") }
                        .help("Attach slides, notes, or handouts as extra context")
                    Button { model.copyNotes(s) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .help("Copy notes + transcript as Markdown")
                    Button { model.exportMarkdown(s) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .help("Export as Markdown")
                }
            }
        }
    }

    private func header(_ s: Binding<Session>) -> some View {
        let busy = [.transcribing, .diarizing, .summarizing].contains(s.wrappedValue.status)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: s.title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            HStack(spacing: 8) {
                Menu {
                    ForEach(TemplateCategory.allCases) { c in
                        Section(c.rawValue) {
                            ForEach(NoteTemplate.inCategory(c)) { t in
                                Button {
                                    Task { await model.summarize(id, template: t) }
                                } label: {
                                    Label(t.name, systemImage: t.icon)
                                }
                            }
                        }
                    }
                } label: {
                    Label(s.wrappedValue.template.name, systemImage: s.wrappedValue.template.icon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy || s.wrappedValue.transcript.isEmpty)
                .help("Switch template — regenerates notes from the existing transcript (no re-transcription)")

                Chip(text: s.wrappedValue.createdAt.formatted(date: .abbreviated, time: .shortened), icon: "calendar")
                Chip(text: AppModel.format(s.wrappedValue.duration), icon: "waveform")
                let speakers = Set(s.wrappedValue.transcript.compactMap(\.speaker)).count
                if speakers > 0 { Chip(text: "\(speakers) speaker\(speakers == 1 ? "" : "s")", icon: "person.2") }
                Spacer()
                if !busy && !s.wrappedValue.transcript.isEmpty {
                    Button {
                        Task { await model.summarize(id) }
                    } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder private func notes(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let docs = s.context, !docs.isEmpty {
                ContextTray(docs: docs, busy: model.importingContext,
                            onAdd: { attaching = true },
                            onRemove: { model.removeContext($0, from: id) },
                            sessionID: id)
            }
            notesBody(s)
        }
    }

    @ViewBuilder private func notesBody(_ s: Session) -> some View {
        if let live = model.liveNotes[id] {
            VStack(alignment: .leading, spacing: 16) {
                StageBanner(text: model.stage[id] ?? "Working…")
                if !live.isEmpty { NotesRenderer(markdown: live, template: s.template, streaming: true) }
            }
        } else if s.status == .failed {
            VStack(alignment: .leading, spacing: 12) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(s.error ?? "Unknown error").textSelection(.enabled)
                Button("Try again") { Task { await model.process(id) } }
            }
        } else if s.status != .done {
            StageBanner(text: model.stage[id] ?? "Queued…")
        } else {
            NotesRenderer(markdown: s.notes, template: s.template)
        }
    }
}

struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

struct StageBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let lines: [TranscriptLine]
    private let palette: [Color] = [.brand, .blue, .orange, .purple, .pink, .teal]

    var body: some View {
        if lines.isEmpty {
            Text("No transcript yet.").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(lines) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(AppModel.format(l.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            if let sp = l.speaker {
                                Text(sp).font(.caption.weight(.semibold)).foregroundStyle(color(sp))
                            }
                            Text(l.text).textSelection(.enabled).lineSpacing(3)
                        }
                    }
                }
            }
        }
    }

    private func color(_ speaker: String) -> Color {
        let n = Int(speaker.filter(\.isNumber)) ?? 0
        return palette[n % palette.count]
    }
}

// MARK: - Impact

struct ImpactView: View {
    let session: Session

    var body: some View {
        let st = session.stats
        let onDevice = st.transcribeSeconds + st.diarizeSeconds + st.llmSeconds
        VStack(alignment: .leading, spacing: 20) {
            Text("Compute footprint").font(.title3.weight(.semibold))
            Text("Every step ran locally on this Mac. Nothing was uploaded.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                Stat(value: "0 bytes", label: "Sent to the cloud", icon: "icloud.slash")
                Stat(value: String(format: "%.1fs", onDevice), label: "Total on-device compute", icon: "cpu")
                Stat(value: speed(st), label: "Faster than real time", icon: "hare")
                Stat(value: String(format: "%.3f Wh", st.estimatedWh), label: "Est. energy (~15 W draw)", icon: "bolt")
                Stat(value: "\(st.promptTokens + st.completionTokens)", label: "LLM tokens processed", icon: "text.word.spacing")
                Stat(value: "1× / \(st.summaryRuns)×", label: "Transcribed / summarized", icon: "arrow.triangle.2.circlepath")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pipeline").font(.headline)
                row("Speech-to-text", "Argmax WhisperKit · \(st.whisperModel)", st.transcribeSeconds)
                if st.diarizeSeconds > 0 { row("Speaker diarization", "Argmax SpeakerKit · Pyannote", st.diarizeSeconds) }
                row("Notes", "\(st.llmModel) · 1.58-bit ternary · thinking off", st.llmSeconds)
            }
            .padding(14)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))

            Text("Efficiency choices: audio is recorded at Whisper's native 16 kHz, silence is skipped with VAD, speaker diarization only runs for multi-speaker templates, Bonsai runs with reasoning off and shuts down after 90 s idle, and switching templates reuses the transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func speed(_ st: ComputeStats) -> String {
        let compute = st.transcribeSeconds + st.diarizeSeconds
        guard compute > 0, session.duration > 0 else { return "—" }
        return String(format: "%.0f×", session.duration / compute)
    }

    private func row(_ title: String, _ detail: String, _ secs: Double) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1fs", secs)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let value: String
    let label: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.brand)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

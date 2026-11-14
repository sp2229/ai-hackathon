import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: AudioRecorder

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            Group {
                if recorder.isRecording {
                    RecordingView()
                } else if let id = model.selection, model.sessions.contains(where: { $0.id == id }) {
                    SessionView(id: id)
                        .id(id)
                } else {
                    HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .alert("Notes", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 0) {
            Button {
                model.selection = nil
            } label: {
                Label("New Recording", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(12)
            .disabled(recorder.isRecording)

            List(selection: $model.selection) {
                if model.sessions.isEmpty {
                    Text("Your recordings will appear here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.sessions) { s in
                    SessionRow(session: s)
                        .tag(s.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(s.id) }
                        }
                }
            }
            .listStyle(.sidebar)

            OfflineBadge()
                .padding(12)
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.template.icon)
                .foregroundStyle(Color.brand)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.createdAt, style: .date)
                    Text("·")
                    Text(AppModel.format(session.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder var statusIcon: some View {
        switch session.status {
        case .transcribing, .diarizing, .summarizing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

struct OfflineBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill").foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("100% on-device").font(.caption.weight(.semibold))
                Text("Works offline · nothing leaves your Mac").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Home (template picker + record)

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var importingAudio = false
    @State private var attaching = false
    @Environment(\.openSettings) private var openSettings

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("What are you recording?")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Pick a note style. Notes are written to fit it, and you can switch styles afterwards.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                Picker("Category", selection: $model.templateCategory) {
                    ForEach(TemplateCategory.allCases) { c in
                        Label(c.rawValue, systemImage: c.icon).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 640)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(NoteTemplate.inCategory(model.templateCategory)) { t in
                        TemplateCard(template: t, selected: model.recordingTemplate.id == t.id)
                            .onTapGesture { model.recordingTemplate = t }
                    }
                }
                .frame(maxWidth: 760)

                ContextTray(docs: model.pendingContext,
                            busy: model.importingContext,
                            onAdd: { attaching = true },
                            onRemove: { model.removeContext($0, from: nil) })
                    .frame(maxWidth: 760)

                VStack(spacing: 6) {
                    Picker("Record from", selection: $model.audioSource) {
                        ForEach(AudioSource.allCases) { src in
                            Label(src.label, systemImage: src.icon).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Text(model.audioSource.hint).font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.startRecording() }
                } label: {
                    ZStack {
                        Circle().fill(Color.red.gradient).frame(width: 84, height: 84)
                            .shadow(color: .red.opacity(0.35), radius: 12, y: 4)
                        Image(systemName: model.audioSource.icon).font(.system(size: 32)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help("Start recording (⌘R)")

                HStack(spacing: 16) {
                    Text("Recording as **\(model.recordingTemplate.name)** · ⌘R").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Button("Import audio file…") { importingAudio = true }
                        .buttonStyle(.link)
                }
                .font(.callout)

                if !model.argmaxReady || !model.bonsaiReady {
                    SetupCallout(argmaxReady: model.argmaxReady, bonsaiReady: model.bonsaiReady) {
                        openSettings()
                    }
                    .frame(maxWidth: 560)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { model.importAudio(url) }
        }
        .fileImporter(isPresented: $attaching, allowedContentTypes: DocumentImporter.allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.addContext(urls, to: nil) } }
        }
    }
}

/// Attached slides / handouts / notes shown as chips, with an add button. Also accepts drag & drop.
struct ContextTray: View {
    let docs: [ContextDoc]
    let busy: Bool
    let onAdd: () -> Void
    let onRemove: (UUID) -> Void
    @EnvironmentObject var model: AppModel
    var sessionID: UUID? = nil
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lecture slides, notes & handouts", systemImage: "paperclip")
                    .font(.callout.weight(.semibold))
                Text("optional").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Attach…", action: onAdd).controlSize(.small)
            }
            if docs.isEmpty {
                Text("Add PDFs, PowerPoint, Word docs, or photos of a whiteboard or handwritten notes. They're used to get terms, names, equations and derivations right. Everything is read on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(docs) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.icon).foregroundStyle(Color.brand)
                            Text(d.name).lineLimit(1)
                            Text("\(d.text.count / 1000)k chars").foregroundStyle(.tertiary)
                            Button { onRemove(d.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.brand.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(dropTargeted ? Color.brand : Color.primary.opacity(0.18))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addContext(urls, to: sessionID) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

struct TemplateCard: View {
    let template: NoteTemplate
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: template.icon)
                .font(.title2)
                .foregroundStyle(selected ? .white : Color.brand)
            Text(template.name).font(.headline)
                .foregroundStyle(selected ? .white : .primary)
            Text(template.blurb).font(.caption)
                .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                .lineLimit(2, reservesSpace: true)
            Text(template.source).font(.caption2).italic()
                .foregroundStyle(selected ? .white.opacity(0.7) : Color.secondary.opacity(0.7))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(selected ? AnyShapeStyle(Color.brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .help(template.source)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct SetupCallout: View {
    let argmaxReady: Bool
    let bonsaiReady: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("One-time setup needed", systemImage: "arrow.down.circle")
                .font(.headline)
            if !argmaxReady {
                Text("• Download the Argmax speech models (Settings › Models).")
            }
            if !bonsaiReady {
                Text("• Install the Bonsai LLM: run `scripts/setup.sh` in the repo.")
            }
            Text("After that, Notes works with Wi-Fi off.").foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Recording

struct RecordingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Label(model.recordingTemplate.name, systemImage: model.recordingTemplate.icon)
                .font(.headline)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.brand.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.brand)

            Text(AppModel.format(recorder.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()

            Waveform(levels: recorder.levels)
                .frame(height: 80)
                .frame(maxWidth: 520)

            HStack(spacing: 28) {
                Button {
                    model.cancelRecording()
                } label: {
                    Image(systemName: "xmark").font(.title2)
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Discard")

                Button {
                    model.stopRecording()
                } label: {
                    ZStack {
                        Circle().fill(Color.red.gradient).frame(width: 84, height: 84)
                        RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Stop and make notes (⌘↩)")

                Button {
                    recorder.togglePause()
                } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").font(.title2)
                        .frame(width: 56, height: 56)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(recorder.isPaused ? "Resume" : "Pause")
            }

            Label(recorder.isPaused ? "Paused" : "Recording \(recorder.source.label.lowercased()) · audio stays on this Mac",
                  systemImage: recorder.source.icon)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

struct Waveform: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule()
                    .fill(Color.brand.opacity(0.35 + Double(l) * 0.65))
                    .frame(height: max(4, CGFloat(l) * 80))
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

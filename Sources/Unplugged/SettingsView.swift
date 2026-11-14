import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("whisperModel") private var whisperModel: String = WhisperChoice.base.rawValue
    @AppStorage("bonsaiModel") private var bonsaiModel: String = BonsaiSize.b4.rawValue
    @AppStorage("diarizationEnabled") private var diarizationEnabled: Bool = true
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                Picker("Whisper model", selection: $whisperModel) {
                    ForEach(WhisperChoice.allCases) { m in
                        Text(m.label + (Transcriber.shared.isWhisperReady(m) ? "" : "  (not downloaded)")).tag(m.rawValue)
                    }
                }
                Toggle("Identify speakers (Meeting, Site Visit, Interview)", isOn: $diarizationEnabled)
                HStack {
                    status(Transcriber.shared.isWhisperReady(WhisperChoice(rawValue: whisperModel) ?? .base), "Whisper")
                    status(Transcriber.shared.isSpeakerKitReady(), "SpeakerKit")
                    Spacer()
                    if model.isDownloading { ProgressView().controlSize(.small) }
                    Button("Download models") {
                        Task { await model.downloadModels(); refresh += 1 }
                    }
                    .disabled(model.isDownloading)
                }
                if !model.modelStatus.isEmpty {
                    Text(model.modelStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Speech · Argmax")
            } footer: {
                Text("Downloaded once (needs internet), then runs offline on the Neural Engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                let installed = BonsaiEngine.installed()
                Picker("Notes model", selection: $bonsaiModel) {
                    ForEach(BonsaiSize.allCases) { s in
                        Text(s.label + (installed.contains(s) ? "" : "  (not installed)")).tag(s.rawValue)
                    }
                }
                HStack {
                    status(BonsaiEngine.serverInstalled, "llama-server")
                    status(!installed.isEmpty, installed.isEmpty ? "No Bonsai model" : installed.map(\.rawValue).joined(separator: ", "))
                }
            } header: {
                Text("Notes · PrismML Bonsai")
            } footer: {
                Text("Install with `scripts/setup.sh` (add BONSAI_MODEL=2B or 9B for other sizes). Smaller models use less energy.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Location", value: Paths.support.path)
                Button("Show in Finder") { NSWorkspace.shared.open(Paths.support) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .id(refresh)
    }

    private func status(_ ok: Bool, _ name: String) -> some View {
        Label(name, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? Color.brand : .secondary)
            .font(.caption)
    }
}

import SwiftUI
import AppKit

@main
struct NotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Notes") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .frame(minWidth: 860, minHeight: 560)
                .tint(.brand)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { model.selection = nil }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .tint(.brand)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless checks: --selftest <audio> [template] [--context f] [--render out.png]
        //                  --render-md <file.md> <template> <out.png>
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            Task { await SelfTest.run(args: args) }
            return
        }
        if let i = args.firstIndex(of: "--extract"), i + 1 < args.count {
            // Print what Notes extracts from an attachment (PDF, pptx, docx, image, text)
            Task {
                do {
                    let d = try await DocumentImporter.extract(URL(fileURLWithPath: args[i + 1]))
                    print("[\(d.kind)] \(d.name) — \(d.text.count) chars\n\(d.text)")
                } catch { print("EXTRACT FAILED: \(error.localizedDescription)") }
                exit(0)
            }
            return
        }
        if args.contains("--render-md") {
            Task { await SelfTest.renderMarkdown(args: args) }
            return
        }
        // Needed when launched as a bare SwiftPM executable (e.g. `swift run`)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the LLM running after we quit.
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await BonsaiEngine.shared.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }
}

extension Color {
    static let brand = Color(red: 0.16, green: 0.52, blue: 0.38)
}

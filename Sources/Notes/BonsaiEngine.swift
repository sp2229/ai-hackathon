import Foundation

/// Runs PrismML's Ternary Bonsai 2 (1.58-bit) LLM fully on-device through a private
/// `llama-server` process bound to 127.0.0.1.
///
/// Sustainability choices:
///  • The server is started only when notes are generated and shut down after
///    `idleTimeout` seconds, so the model isn't sitting in memory or burning cycles.
///  • Thinking/reasoning mode is OFF — summarizing doesn't need chain-of-thought and it
///    cuts generated tokens (and energy) by several times.
///  • The smallest model that does the job is the default (4B; 2B available).
enum BonsaiSize: String, CaseIterable, Identifiable {
    case b2 = "2B", b4 = "4B", b9 = "9B"
    var id: String { rawValue }
    var fileName: String { "Ternary-Bonsai-2-\(rawValue)-PQ2_0.gguf" }
    var label: String {
        switch self {
        case .b2: return "Bonsai 2B · 0.5 GB, lowest energy"
        case .b4: return "Bonsai 4B · 1.2 GB, balanced"
        case .b9: return "Bonsai 9B · 2.4 GB, highest quality"
        }
    }
}

struct LLMUsage {
    var promptTokens = 0
    var completionTokens = 0
    var seconds = 0.0
}

enum BonsaiError: LocalizedError {
    case serverMissing, modelMissing(String), startFailed(String), http(String)
    var errorDescription: String? {
        switch self {
        case .serverMissing: return "llama-server not found. Run scripts/setup.sh once (needs internet)."
        case .modelMissing(let f): return "Bonsai model \(f) not found. Run: BONSAI_MODEL=<2B|4B|9B> scripts/setup.sh"
        case .startFailed(let s): return "Bonsai failed to start: \(s)"
        case .http(let s): return "Bonsai error: \(s)"
        }
    }
}

actor BonsaiEngine {
    static let shared = BonsaiEngine()

    private var process: Process?
    private var loadedModel: BonsaiSize?
    private var port: Int = 0
    private var idleTask: Task<Void, Never>?
    private let idleTimeout: UInt64 = 90   // seconds

    nonisolated static func installed() -> [BonsaiSize] {
        BonsaiSize.allCases.filter {
            FileManager.default.fileExists(atPath: Paths.llmModels.appendingPathComponent($0.fileName).path)
        }
    }

    nonisolated static var serverInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.llamaServer.path)
    }

    var isRunning: Bool { process?.isRunning == true }

    // MARK: lifecycle

    private func ensureRunning(_ size: BonsaiSize) async throws {
        idleTask?.cancel()
        if let p = process, p.isRunning, loadedModel == size { return }
        stop()

        guard Self.serverInstalled else { throw BonsaiError.serverMissing }
        let model = Paths.llmModels.appendingPathComponent(size.fileName)
        guard FileManager.default.fileExists(atPath: model.path) else { throw BonsaiError.modelMissing(size.fileName) }

        port = Int.random(in: 18_000...18_999)
        let p = Process()
        p.executableURL = Paths.llamaServer
        p.currentDirectoryURL = Paths.llamaServer.deletingLastPathComponent()
        p.arguments = [
            "-m", model.path,
            "-ngl", "99",          // all layers on the Apple GPU (Metal)
            "-fa", "on",           // flash attention: less memory traffic
            "-c", "16384",         // right-sized context window (model supports 262K)
            "--host", "127.0.0.1", // local only — never exposed on the network
            "--port", String(port),
            "--no-webui",
            "--parallel", "1",
        ]
        let log = Paths.support.appendingPathComponent("llama-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) {
            p.standardOutput = h
            p.standardError = h
        }
        try p.run()
        process = p
        loadedModel = size

        // Wait for /health
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning { throw BonsaiError.startFailed("process exited — see \(log.path)") }
            if await healthy() { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        throw BonsaiError.startFailed("timed out loading model")
    }

    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func stop() {
        idleTask?.cancel()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        loadedModel = nil
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    // MARK: generation

    /// Streams a chat completion. `onToken` receives each text delta.
    func generate(size: BonsaiSize,
                  system: String,
                  user: String,
                  maxTokens: Int = 1500,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> (String, LLMUsage) {
        try await ensureRunning(size)
        defer { scheduleIdleShutdown() }

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": maxTokens,
            // PrismML's recommended non-thinking sampling profile for Bonsai 2B/4B/9B
            "temperature": 0.7, "top_p": 0.8, "top_k": 20, "min_p": 0,
            "presence_penalty": 1.5,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600

        let start = Date()
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw BonsaiError.http("HTTP \(http.statusCode)")
        }

        var text = ""
        var usage = LLMUsage()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                onToken(piece)
            }
            if let u = obj["usage"] as? [String: Any] {
                usage.promptTokens = u["prompt_tokens"] as? Int ?? usage.promptTokens
                usage.completionTokens = u["completion_tokens"] as? Int ?? usage.completionTokens
            }
        }
        usage.seconds = Date().timeIntervalSince(start)
        return (Self.stripThinking(text), usage)
    }

    static func stripThinking(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            // Small models sometimes echo template placeholders like "<owner>" — unwrap them
            .replacingOccurrences(of: #"<([^<>/\n][^<>\n]{0,200})>"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

/// All on-disk locations. Everything lives under ~/Library/Application Support/Unplugged —
/// nothing is ever uploaded anywhere.
enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unplugged", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var sessions: URL { dir("sessions") }
    static var argmaxModels: URL { dir("models/argmax") }
    static var llmModels: URL { dir("models/llm") }
    static var llamaServer: URL { support.appendingPathComponent("bin/llama-server") }

    private static func dir(_ sub: String) -> URL {
        let url = support.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sessionDir(_ id: UUID) -> URL {
        let url = sessions.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audio(for session: Session) -> URL {
        sessionDir(session.id).appendingPathComponent(session.audioFile)
    }
}

enum SessionStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadAll() -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return try? decoder.decode(Session.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ session: Session) {
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: Paths.sessionDir(session.id).appendingPathComponent("session.json"), options: .atomic)
    }

    static func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: Paths.sessionDir(session.id))
    }
}

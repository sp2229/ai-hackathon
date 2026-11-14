import Foundation

// MARK: - Session

struct TranscriptLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: String?
    var text: String
}

struct ComputeStats: Codable, Hashable {
    var whisperModel: String = ""
    var llmModel: String = ""
    var transcribeSeconds: Double = 0
    var diarizeSeconds: Double = 0
    var llmSeconds: Double = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// How many times the summary was (re)generated. Transcription only ever runs once.
    var summaryRuns: Int = 0

    /// Rough on-device energy estimate in watt-hours.
    /// Assumes ~15 W package power for Apple-silicon ANE/GPU inference.
    var estimatedWh: Double {
        (transcribeSeconds + diarizeSeconds + llmSeconds) * 15.0 / 3600.0
    }
}

enum SessionStatus: String, Codable {
    case recorded, transcribing, diarizing, summarizing, done, failed
}

struct Session: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var templateID: String
    var duration: Double = 0
    var audioFile: String = "audio.wav"
    var transcript: [TranscriptLine] = []
    var notes: String = ""
    var status: SessionStatus = .recorded
    var error: String?
    var stats = ComputeStats()
    /// Slides, handouts, or notes the user attached as extra context (optional for back-compat).
    var context: [ContextDoc]?

    var template: NoteTemplate { NoteTemplate.find(templateID) }

    var plainTranscript: String {
        transcript.map { line in
            if let s = line.speaker { return "\(s): \(line.text)" }
            return line.text
        }.joined(separator: "\n")
    }
}

// MARK: - Context documents

struct ContextDoc: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: String        // "PDF", "Slides", "Image (OCR)", "Text", ...
    var text: String
    var icon: String {
        switch kind {
        case "PDF": return "doc.richtext.fill"
        case "Slides": return "rectangle.on.rectangle.fill"
        case "Image (OCR)": return "photo.fill"
        case "Word": return "doc.fill"
        default: return "doc.text.fill"
        }
    }
}

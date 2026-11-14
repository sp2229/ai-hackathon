import Foundation

/// How a template's notes are drawn on screen.
enum NoteStyle: String, Codable {
    case standard     // Markdown (headings, bullets, tables, LaTeX math, sketches)
    case cornell      // two-column cue / notes + summary strip
    case notebook     // handwritten look on lined paper, Euler math font
    case flashcards   // flip cards for retrieval practice
    case sketchnote   // big idea, diagram, icon cards, sticky notes
}

struct NoteTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let blurb: String
    /// Where the method comes from — shown on the card.
    let source: String
    let style: NoteStyle
    /// Speaker labels only matter when several people talk; skipping diarization
    /// for single-speaker recordings avoids work we don't need.
    let diarize: Bool
    /// Ask the model to write equations in LaTeX.
    let math: Bool
    /// Ask the model to draw diagrams of physical/spatial things it hears about.
    let sketches: Bool
    let maxTokens: Int
    let format: String

    init(_ id: String, _ name: String, icon: String, blurb: String, source: String,
         style: NoteStyle = .standard, diarize: Bool = false, math: Bool = false, sketches: Bool = false,
         maxTokens: Int = 1500, format: String) {
        self.id = id; self.name = name; self.icon = icon; self.blurb = blurb; self.source = source
        self.style = style; self.diarize = diarize; self.math = math; self.sketches = sketches
        self.maxTokens = maxTokens; self.format = format
    }

    static func find(_ id: String) -> NoteTemplate {
        let legacy = ["notebook": "lecture", "problem": "lecture", "outline": "lecture", "lab": "lecture",
                      "sketchnote": "visual", "mindmap": "visual", "timeline": "visual"]
        let key = legacy[id] ?? id
        return all.first { $0.id == key } ?? all[0]
    }

    var systemPrompt: String {
        var rules = """
        - Only use information from the transcript and the reference material. Never invent names, numbers, or dates.
        - Text in <angle brackets> is a placeholder: replace it with real content and never output the angle brackets.
        - Don't guess people's job titles or roles; use names only if spoken, otherwise "Speaker 1", "Speaker 2".
        - If a section has nothing relevant, write "_None mentioned._"
        - Be concise. Output only the notes in Markdown — no preamble, no closing remarks.
        """
        if math {
            rules += """

            - Write every equation in LaTeX: inline as $...$ and important equations on their own line as $$...$$.
            - When reference material contains a derivation the speaker referred to, include its key steps.
            - Never make up new examples, problems, or numbers. Worked examples must come from the transcript or reference.
            """
        }
        var prompt = """
        You are an expert note-taker. Turn the transcript into "\(name)" notes. Follow this format exactly:

        \(format)

        Rules:
        \(rules)
        """
        if sketches { prompt += "\n\n" + Sketch.promptGuide }
        return prompt
    }

    // MARK: - The six templates

    static let all: [NoteTemplate] = [
        NoteTemplate("meeting", "Meeting", icon: "person.3.fill",
            blurb: "Decisions, action items, owners",
            source: "Standard minutes format",
            diarize: true,
            format: """
            ## Summary
            <2–4 sentences on purpose and outcome>
            ## Decisions
            - <decision>
            ## Action Items
            - [ ] <task> — **<owner>** (<due date if mentioned>)
            ## Open Questions
            - <unresolved issues>
            """),

        NoteTemplate("lecture", "Lecture", icon: "function",
            blurb: "Handwritten-style notes, equations & drawings",
            source: "Worked-example effect, Sweller & Cooper (1985)",
            style: .notebook, math: true, sketches: true, maxTokens: 2200,
            format: """
            # <Topic>
            ## Key Ideas
            - <idea, with inline math like $F = ma$>
            ## Diagram
            <a ```sketch block drawing what was described — or "_None mentioned._">
            ## Equations
            $$<important equation>$$
            - <what each symbol means>
            ## Worked Example
            <the example the speaker actually worked, step by step with $$...$$ — or "_None mentioned._">
            ## Review Questions
            - <3 questions to test yourself>
            """),

        NoteTemplate("cornell", "Cornell", icon: "rectangle.split.2x1.fill",
            blurb: "Cue questions, notes, and a summary",
            source: "Pauk, How to Study in College (1962)",
            style: .cornell, math: true, sketches: true,
            format: """
            # <Lecture title>
            ### <Cue: a short question or keyword>
            - <note answering the cue>
            - <note>
            (Repeat for 4–8 cues, in the order covered. Put a ```sketch block under a cue if something physical was described.)
            ## Summary
            <2–3 sentences in your own words>
            """),

        NoteTemplate("flashcards", "Study Cards", icon: "rectangle.on.rectangle.angled",
            blurb: "Flip cards to quiz yourself",
            source: "Roediger & Karpicke (2006), testing effect",
            style: .flashcards, math: true,
            format: """
            ## Summary
            <2–3 sentences>
            ## Flashcards
            Q: <question testing one idea>
            A: <short answer>
            (8–12 cards, mixing definitions, why/how questions, and applications.)
            """),

        NoteTemplate("visual", "Visual", icon: "scribble.variable",
            blurb: "Drawings, icons, and sticky notes",
            source: "Sketchnoting, Rohde (2012); dual coding, Paivio (1971)",
            style: .sketchnote, math: true, sketches: true,
            format: """
            ## Big Idea
            <one memorable sentence>
            ## Diagram
            <a ```sketch block of the main thing described: a structure, setup, process, or how ideas connect>
            ## Key Concepts
            - <one emoji> **<Concept>** — <max 12 words>
            (4–8 concepts. Start EVERY concept line with a relevant emoji, e.g. "- ⚡ **Energy** — ...".)
            ## Remember
            - <short takeaway, max 10 words>
            (3–4 takeaways.)
            """),

        NoteTemplate("site", "Site Visit", icon: "hammer.fill",
            blurb: "Observations, hazards, sketches, follow-ups",
            source: "Field inspection report",
            diarize: true, sketches: true, maxTokens: 2000,
            format: """
            ## Site Overview
            <location, purpose, who was present>
            ## Sketch
            <a ```sketch block of the element or area discussed, with dimensions — or "_None mentioned._">
            ## Observations
            - <factual observations>
            ## Issues & Hazards
            - **[High/Medium/Low]** <issue> — <location> — <recommended action>
            ## Measurements & Specs
            - <dimensions, quantities, materials, spec references>
            ## Follow-up Actions
            - [ ] <action> — **<responsible party>** (<deadline>)
            """),
    ]
}

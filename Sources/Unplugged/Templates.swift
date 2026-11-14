import Foundation

/// How a template's notes are drawn on screen.
enum NoteStyle: String, Codable {
    case standard     // Markdown (headings, bullets, tables, LaTeX math)
    case cornell      // two-column cue / notes + summary strip
    case notebook     // handwritten look on lined paper, Euler math font
    case mindmap      // central topic + colored branches
    case flashcards   // flip cards for retrieval practice
    case sketchnote   // big idea, icon cards, connections, sticky notes
    case timeline     // vertical timeline
}

enum TemplateCategory: String, CaseIterable, Identifiable {
    case study = "Study Methods"
    case visual = "Visual"
    case classType = "Class Types"
    case work = "Work"
    case accessible = "Accessible"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .study: return "book.fill"
        case .visual: return "paintpalette.fill"
        case .classType: return "graduationcap.fill"
        case .work: return "briefcase.fill"
        case .accessible: return "accessibility"
        }
    }
}

struct NoteTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let category: TemplateCategory
    let blurb: String
    /// Where the method comes from — shown on the card.
    let source: String
    let style: NoteStyle
    /// Speaker labels only matter when several people talk; skipping diarization
    /// for single-speaker recordings avoids work we don't need.
    let diarize: Bool
    /// Ask the model to write equations in LaTeX.
    let math: Bool
    let maxTokens: Int
    let format: String

    init(_ id: String, _ name: String, icon: String, _ category: TemplateCategory, blurb: String,
         source: String, style: NoteStyle = .standard, diarize: Bool = false, math: Bool = false,
         maxTokens: Int = 1500, format: String) {
        self.id = id; self.name = name; self.icon = icon; self.category = category
        self.blurb = blurb; self.source = source; self.style = style; self.diarize = diarize
        self.math = math; self.maxTokens = maxTokens; self.format = format
    }

    static func find(_ id: String) -> NoteTemplate { all.first { $0.id == id } ?? all[0] }
    static func inCategory(_ c: TemplateCategory) -> [NoteTemplate] { all.filter { $0.category == c } }

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
        return """
        You are an expert note-taker. Turn the lecture or conversation transcript into \
        "\(name)" notes. Follow this format exactly:

        \(format)

        Rules:
        \(rules)
        """
    }

    // MARK: - Library

    static let all: [NoteTemplate] = study + visual + classTypes + work + accessible

    // Evidence-based study methods
    static let study: [NoteTemplate] = [
        NoteTemplate("cornell", "Cornell Notes", icon: "rectangle.split.2x1.fill", .study,
            blurb: "Cue questions, notes, and a summary for self-testing",
            source: "Pauk, How to Study in College (1962)",
            style: .cornell, math: true,
            format: """
            # <Lecture title>
            ### <Cue: a short question or keyword>
            - <note answering the cue>
            - <note>
            (Repeat for 4–8 cues, in the order covered.)
            ## Summary
            <2–3 sentences in your own words>
            """),
        NoteTemplate("outline", "Outline", icon: "list.bullet.indent", .study,
            blurb: "Hierarchical main ideas → supporting details",
            source: "Classic outline method",
            math: true,
            format: """
            # <Topic>
            ## <Main idea 1>
            - <supporting point>
              - <detail or example>
            ## <Main idea 2>
            ...
            (3–7 main ideas.)
            """),
        NoteTemplate("flashcards", "Flashcards", icon: "rectangle.on.rectangle.angled", .study,
            blurb: "Self-quiz cards for retrieval practice",
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
        NoteTemplate("feynman", "Feynman Explainer", icon: "lightbulb.fill", .study,
            blurb: "Explain it simply, with an analogy, and find the gaps",
            source: "The Feynman Technique",
            math: true,
            format: """
            ## The Concept
            <name it in one line>
            ## Explain It Like I'm 12
            <a short plain-language explanation, no jargon>
            ## Analogy
            <one everyday analogy>
            ## Where It Gets Tricky
            - <subtle points or common misconceptions>
            ## Gaps to Review
            - <things the transcript left unclear that the student should look up>
            """),
        NoteTemplate("sq3r", "SQ3R Reading Guide", icon: "book.pages.fill", .study,
            blurb: "Survey, Question, Read, Recite, Review",
            source: "Robinson, Effective Study (1946)",
            format: """
            ## Survey
            <what this material is about and how it is structured>
            ## Questions
            - <questions the material answers>
            ## Read — Key Answers
            - **<question>** — <answer>
            ## Recite
            <3–5 sentence recap in plain words>
            ## Review
            - <what to revisit before the exam>
            """),
        NoteTemplate("charting", "Comparison Chart", icon: "tablecells.fill", .study,
            blurb: "Compare concepts side by side in a table",
            source: "Charting method",
            math: true,
            format: """
            ## Overview
            <one sentence on what is being compared>
            ## Comparison
            | Item | Definition | Key Features | Example |
            |---|---|---|---|
            | <item> | <...> | <...> | <...> |
            (One row per concept/option discussed; adapt column names if better ones fit.)
            ## Key Differences
            - <the most important contrasts>
            """),
    ]

    // Visual learners
    static let visual: [NoteTemplate] = [
        NoteTemplate("mindmap", "Mind Map", icon: "point.3.connected.trianglepath.dotted", .visual,
            blurb: "Central topic with branching ideas",
            source: "Buzan, Use Your Head (1974)",
            style: .mindmap,
            format: """
            # <Central topic, 1–4 words>
            ## <Branch, 1–3 words>
            - <sub-idea, max 6 words>
              - <detail, max 6 words>
            (4–7 branches, 2–5 sub-ideas each. Keep every node short.)
            """),
        NoteTemplate("sketchnote", "Sketchnote", icon: "scribble.variable", .visual,
            blurb: "Icons, big idea, connections, sticky notes",
            source: "Rohde (2012); dual coding, Paivio (1971)",
            style: .sketchnote,
            format: """
            ## Big Idea
            <one memorable sentence>
            ## Key Concepts
            - <one emoji> **<Concept>** — <max 12 words>
            (4–8 concepts. Start EVERY concept line with a relevant emoji, e.g. "- ⚡ **Energy** — ...".)
            ## How It Connects
            - <Concept A> → <Concept B>: <relationship in a few words>
            (2–5 connections.)
            ## Remember
            - <short takeaway, max 10 words>
            (3–4 takeaways.)
            """),
        NoteTemplate("timeline", "Timeline", icon: "calendar.day.timeline.left", .visual,
            blurb: "Events, steps, or processes in order",
            source: "Sequencing / process notes",
            style: .timeline,
            format: """
            # <Topic>
            ## Timeline
            - **<date, era, or step>** — <what happened, max 20 words>
            (In chronological or process order.)
            ## Big Picture
            <2 sentences on the overall arc>
            """),
    ]

    // Class archetypes
    static let classTypes: [NoteTemplate] = [
        NoteTemplate("lecture", "Lecture", icon: "graduationcap.fill", .classType,
            blurb: "Concepts, definitions, examples, review questions",
            source: "General lecture notes",
            math: true,
            format: """
            ## Topic
            <one line>
            ## Key Concepts
            - <main ideas in the order taught>
            ## Definitions & Formulas
            - **<Term>** — <definition>
            ## Examples
            - <worked examples or illustrations>
            ## Review Questions
            - <3–5 questions>
            ## Summary
            <short paragraph>
            """),
        NoteTemplate("notebook", "STEM Notebook", icon: "function", .classType,
            blurb: "Handwritten-style notes with equations & worked examples",
            source: "Worked-example effect, Sweller & Cooper (1985)",
            style: .notebook, math: true, maxTokens: 2000,
            format: """
            # <Topic>
            ## Key Ideas
            - <idea, with inline math like $F = ma$>
            ## Equations
            $$<important equation>$$
            - <what each symbol means and when to use it>
            ## Derivation
            <numbered steps; each step's math on its own $$...$$ line with a short reason>
            ## Worked Example
            <the example the speaker actually worked, step by step with $$...$$ — or "_None mentioned._">
            ## Watch Out
            - <common mistakes, units, sign conventions>
            """),
        NoteTemplate("problem", "Engineering Problem", icon: "ruler.fill", .classType,
            blurb: "Given · Find · Assumptions · Solution · Check",
            source: "Engineering problem-solving format (GFSSA)",
            style: .notebook, math: true, maxTokens: 2000,
            format: """
            ## Problem
            <restate the problem>
            ## Given
            - <known quantities with units, e.g. $L = 3\\,\\text{m}$>
            ## Find
            - <unknowns>
            ## Assumptions
            - <simplifying assumptions>
            ## Solution
            <numbered steps; math on its own $$...$$ lines>
            ## Answer & Check
            - <final answer with units, plus a sanity check>
            """),
        NoteTemplate("irac", "Case Brief (IRAC)", icon: "building.columns.fill", .classType,
            blurb: "Issue, Rule, Application, Conclusion — law & humanities",
            source: "IRAC legal analysis method",
            format: """
            ## Case / Topic
            <name and one-line context>
            ## Facts
            - <key facts>
            ## Issue
            <the central question>
            ## Rule
            <the governing rule, principle, or theory>
            ## Application
            <how the rule applies to the facts; arguments on each side>
            ## Conclusion
            <the outcome and why>
            ## Discussion Points
            - <questions raised in class>
            """),
        NoteTemplate("seminar", "Research Talk", icon: "doc.text.magnifyingglass", .classType,
            blurb: "Claims, methods, evidence, limitations",
            source: "Critical reading of research (claims–evidence)",
            math: true,
            format: """
            ## Research Question
            <one or two sentences>
            ## Main Claims
            - <claim>
            ## Methods
            - <data, approach, experimental setup>
            ## Evidence & Results
            - <key findings with numbers if given>
            ## Limitations
            - <weaknesses, caveats, open problems>
            ## My Questions
            - <questions to ask or follow up on>
            """),
        NoteTemplate("language", "Language Class", icon: "character.bubble.fill", .classType,
            blurb: "Vocabulary table, grammar, useful phrases",
            source: "Vocabulary & grammar notebook",
            format: """
            ## Vocabulary
            | Word / Phrase | Meaning | Example sentence |
            |---|---|---|
            | <...> | <...> | <...> |
            ## Grammar Points
            - **<rule>** — <explanation + example>
            ## Useful Phrases
            - <phrase> — <meaning>
            ## Practice
            - <3 short exercises or prompts>
            """),
        NoteTemplate("lab", "Lab Session", icon: "flask.fill", .classType,
            blurb: "Objective, procedure, observations, data, safety",
            source: "Laboratory notebook practice",
            math: true,
            format: """
            ## Objective
            <one line>
            ## Materials & Setup
            - <equipment, reagents, settings>
            ## Procedure
            1. <step>
            ## Observations & Data
            - <measurements with units>
            ## Safety Notes
            - <hazards mentioned>
            ## Analysis & Next Steps
            - <interpretation, what to do next>
            """),
    ]

    // Professional
    static let work: [NoteTemplate] = [
        NoteTemplate("meeting", "Meeting", icon: "person.3.fill", .work,
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
            ## Next Steps
            - <what happens next>
            """),
        NoteTemplate("standup", "Standup", icon: "figure.stand", .work,
            blurb: "Yesterday · Today · Blockers per person",
            source: "Scrum daily scrum",
            diarize: true,
            format: """
            ## <Person or Speaker>
            - **Yesterday:** <...>
            - **Today:** <...>
            - **Blockers:** <... or none>
            (One section per person.)
            ## Team Blockers & Follow-ups
            - [ ] <follow-up> — **<owner>**
            """),
        NoteTemplate("retro", "Retrospective", icon: "arrow.uturn.backward.circle.fill", .work,
            blurb: "What went well, what to improve, actions",
            source: "Agile retrospective (Derby & Larsen, 2006)",
            diarize: true,
            format: """
            ## What Went Well
            - <...>
            ## What Could Be Better
            - <...>
            ## Ideas
            - <...>
            ## Action Items
            - [ ] <action> — **<owner>**
            """),
        NoteTemplate("client", "Client Call", icon: "phone.fill", .work,
            blurb: "Needs, pain points, requirements, next steps",
            source: "Discovery call notes",
            diarize: true,
            format: """
            ## Client & Context
            <who, company, situation>
            ## Goals & Needs
            - <...>
            ## Pain Points
            - <...>
            ## Requirements & Constraints
            - <budget, timeline, technical constraints>
            ## Commitments
            - [ ] <what we promised> — **<owner>** (<date>)
            """),
        NoteTemplate("site", "Site Visit", icon: "hammer.fill", .work,
            blurb: "Observations, hazards, measurements, RFIs",
            source: "Field inspection report",
            diarize: true,
            format: """
            ## Site Overview
            <location, purpose, who was present>
            ## Observations
            - <factual observations>
            ## Issues & Hazards
            - **[High/Medium/Low]** <issue> — <location> — <recommended action>
            ## Measurements & Specs
            - <dimensions, quantities, materials, spec references>
            ## Follow-up Actions
            - [ ] <action> — **<responsible party>** (<deadline>)
            ## Items to Verify / RFIs
            - <questions for design team, contractor, or owner>
            """),
        NoteTemplate("interview", "Interview", icon: "person.wave.2.fill", .work,
            blurb: "Highlights, quotes, takeaways",
            source: "Qualitative interview notes",
            diarize: true,
            format: """
            ## Overview
            <who and context>
            ## Highlights
            - <...>
            ## Notable Quotes
            - "<exact quote>" — <speaker>
            ## Concerns / Follow-ups
            - <...>
            ## Takeaways
            - <...>
            """),
        NoteTemplate("brainstorm", "Brainstorm", icon: "sparkles", .work,
            blurb: "Ideas grouped into themes, top picks",
            source: "Affinity diagramming (Kawakita, KJ method)",
            diarize: true,
            format: """
            ## Goal
            <what the brainstorm was for>
            ## Themes
            ### <Theme>
            - <idea>
            (Group every idea under a theme.)
            ## Top Picks
            - <most promising ideas and why>
            ## Next Steps
            - [ ] <action> — **<owner>**
            """),
    ]

    // Accessibility
    static let accessible: [NoteTemplate] = [
        NoteTemplate("plain", "Plain Language", icon: "text.bubble.fill", .accessible,
            blurb: "Short sentences, simple words, key terms explained",
            source: "Plain Language & Easy Read guidelines",
            format: """
            ## What This Was About
            <2 short sentences, everyday words>
            ## The Main Points
            - <one idea per bullet, under 15 words>
            ## Words to Know
            - **<term>** — <simple explanation>
            ## What To Do Next
            - <clear action>
            Use short sentences. Avoid jargon. Explain any hard word.
            """),
        NoteTemplate("tldr", "TL;DR Focus", icon: "bolt.fill", .accessible,
            blurb: "Bite-sized, scannable — ADHD-friendly",
            source: "Chunking (Miller, 1956) & cognitive load",
            format: """
            ## TL;DR
            <one sentence>
            ## 3 Things to Know
            - **<bold keyword>** <short point>
            - **<bold keyword>** <short point>
            - **<bold keyword>** <short point>
            ## Your One Next Step
            - [ ] <single most important action>
            ## Details (if you want them)
            - <a few more short bullets>
            """),
        NoteTemplate("general", "Quick Note", icon: "note.text", .accessible,
            blurb: "Summary, key points, to-dos",
            source: "Simple summary",
            format: """
            ## Summary
            <concise paragraph>
            ## Key Points
            - <...>
            ## To-Do
            - [ ] <tasks mentioned>
            """),
    ]
}

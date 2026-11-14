import SwiftUI

/// Picks the right visual layout for a template's notes.
/// Every layout falls back to plain Markdown if the model's output doesn't match the expected shape.
struct NotesRenderer: View {
    let markdown: String
    let template: NoteTemplate
    var streaming = false

    var body: some View {
        switch template.style {
        case .standard: MarkdownView(markdown: markdown, math: template.math)
        case .notebook: NotebookPaper { MarkdownView(markdown: markdown, theme: .notebook, math: true) }
        case .cornell: CornellView(markdown: markdown, math: template.math)
        case .mindmap: streaming ? AnyView(MarkdownView(markdown: markdown)) : AnyView(MindMapView(markdown: markdown))
        case .flashcards: FlashcardsView(markdown: markdown)
        case .sketchnote: SketchnoteView(markdown: markdown)
        case .timeline: TimelineView(markdown: markdown)
        }
    }
}

// MARK: - Section parsing

struct MDSection {
    var level: Int
    var title: String
    var lines: [String]
    var body: String { lines.joined(separator: "\n") }
}

enum Sections {
    static func parse(_ md: String) -> [MDSection] {
        var out: [MDSection] = []
        var current = MDSection(level: 0, title: "", lines: [])
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            var level = 0
            if t.hasPrefix("### ") { level = 3 } else if t.hasPrefix("## ") { level = 2 } else if t.hasPrefix("# ") { level = 1 }
            if level > 0 {
                if !current.title.isEmpty || !current.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    out.append(current)
                }
                current = MDSection(level: level, title: String(t.dropFirst(level + 1)), lines: [])
            } else {
                current.lines.append(line)
            }
        }
        out.append(current)
        return out.filter { !$0.title.isEmpty || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func bullets(_ lines: [String]) -> [(text: String, indent: Int)] {
        lines.compactMap { raw in
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let t = raw.trimmingCharacters(in: .whitespaces)
            for p in ["- [ ] ", "- ", "* ", "• "] where t.hasPrefix(p) { return (String(t.dropFirst(p.count)), indent) }
            if let r = t.range(of: #"^\d+[.)] "#, options: .regularExpression) { return (String(t[r.upperBound...]), indent) }
            return nil
        }
    }

    static func find(_ sections: [MDSection], _ keywords: [String]) -> MDSection? {
        sections.first { s in keywords.contains { s.title.lowercased().contains($0) } }
    }
}

// MARK: - Notebook paper (handwritten look)

struct NotebookPaper<Content: View>: View {
    @ViewBuilder let content: Content
    private let lineGap: CGFloat = 30

    var body: some View {
        content
            .padding(.leading, 64)
            .padding(.trailing, 28)
            .padding(.vertical, 32)
            .background(
                Canvas { ctx, size in
                    var y: CGFloat = 52
                    while y < size.height {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(Color(red: 0.55, green: 0.70, blue: 0.90).opacity(0.45)), lineWidth: 0.7)
                        y += lineGap
                    }
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 48, y: 0)); $0.addLine(to: CGPoint(x: 48, y: size.height)) },
                               with: .color(Color.red.opacity(0.45)), lineWidth: 1.2)
                }
            )
            .background(Color(red: 0.995, green: 0.985, blue: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .environment(\.colorScheme, .light)   // paper stays paper in dark mode
    }
}

// MARK: - Cornell

struct CornellView: View {
    let markdown: String
    let math: Bool

    var body: some View {
        let sections = Sections.parse(markdown)
        let title = sections.first { $0.level == 1 }?.title
        let cues = sections.filter { $0.level == 3 }
        let summary = Sections.find(sections, ["summary"])

        if cues.isEmpty {
            MarkdownView(markdown: markdown, math: math)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).font(.system(.title2, design: .serif).weight(.semibold))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                HStack(spacing: 0) {
                    Text("CUES").frame(width: 200, alignment: .leading).padding(.leading, 16)
                    Text("NOTES").padding(.leading, 16)
                    Spacer()
                }
                .font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.vertical, 6)
                .background(Color.primary.opacity(0.03))
                Divider()
                ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                    HStack(alignment: .top, spacing: 0) {
                        RichText(cue.title, theme: .standard, math: math, font: .callout.weight(.semibold), color: .brand)
                            .frame(width: 184, alignment: .topLeading)
                            .padding(16)
                        Rectangle().fill(Color.red.opacity(0.35)).frame(width: 1.5).frame(maxHeight: .infinity)
                        MarkdownView(markdown: cue.body, math: math)
                            .padding(16)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("SUMMARY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    MarkdownView(markdown: summary?.body ?? "_No summary._", math: math)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.brand.opacity(0.06))
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Mind map

struct MindMapView: View {
    let markdown: String
    static let palette: [Color] = [.brand, .blue, .orange, .purple, .pink, .teal, .indigo, .mint]

    var body: some View {
        let sections = Sections.parse(markdown)
        let center = sections.first { $0.level == 1 }?.title ?? "Topic"
        let branches = sections.filter { $0.level == 2 }

        if branches.isEmpty {
            MarkdownView(markdown: markdown)
        } else {
            VStack(spacing: 0) {
                Text(center)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 16)
                    .background(Capsule().fill(Color.brand.gradient))
                    .shadow(color: Color.brand.opacity(0.3), radius: 8, y: 3)
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2, height: 22)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(Array(branches.enumerated()), id: \.offset) { i, b in
                        branch(b, color: Self.palette[i % Self.palette.count])
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func branch(_ b: MDSection, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(b.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(color))
            ForEach(Array(Sections.bullets(b.lines).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(color.opacity(item.indent == 0 ? 0.8 : 0.35))
                        .frame(width: item.indent == 0 ? 3 : 2)
                    RichText(item.text, theme: .standard, math: true,
                             font: item.indent == 0 ? .callout.weight(.medium) : .caption,
                             color: item.indent == 0 ? Color.primary : Color.secondary)
                }
                .padding(.leading, CGFloat(item.indent) * 14 + 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.25)))
    }
}

// MARK: - Flashcards

struct Flashcard: Hashable { let q: String; let a: String }

struct FlashcardsView: View {
    let markdown: String
    @State private var flipped: Set<Int> = []

    var cards: [Flashcard] {
        var out: [Flashcard] = []
        var q: String?
        for raw in markdown.components(separatedBy: "\n") {
            var t = raw.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "**"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
            t = t.replacingOccurrences(of: "**", with: "")
            if t.lowercased().hasPrefix("q:") { q = t.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            else if t.lowercased().hasPrefix("a:"), let question = q {
                out.append(Flashcard(q: question, a: t.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                q = nil
            }
        }
        return out
    }

    var body: some View {
        let cards = self.cards
        let summary = Sections.find(Sections.parse(markdown), ["summary"])
        VStack(alignment: .leading, spacing: 16) {
            if let summary { MarkdownView(markdown: "## Summary\n" + summary.body) }
            if cards.isEmpty {
                MarkdownView(markdown: markdown)
            } else {
                HStack {
                    Text("Flashcards").font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(Color.brand)
                    Text("\(cards.count) cards · click to flip").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(flipped.count == cards.count ? "Hide all" : "Reveal all") {
                        flipped = flipped.count == cards.count ? [] : Set(cards.indices)
                    }
                    .controlSize(.small)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { i, card in
                        FlipCard(card: card, index: i + 1, flipped: flipped.contains(i))
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.4)) {
                                    if flipped.contains(i) { flipped.remove(i) } else { flipped.insert(i) }
                                }
                            }
                    }
                }
            }
        }
    }
}

struct FlipCard: View {
    let card: Flashcard
    let index: Int
    let flipped: Bool

    var body: some View {
        ZStack {
            face(label: "Q\(index)", text: card.q, fill: Color.brand.opacity(0.08), accent: .brand)
                .opacity(flipped ? 0 : 1)
            face(label: "A\(index)", text: card.a, fill: Color.orange.opacity(0.10), accent: .orange)
                .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                .opacity(flipped ? 1 : 0)
        }
        .frame(minHeight: 130)
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0))
        .contentShape(Rectangle())
    }

    private func face(label: String, text: String, fill: Color, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(accent)
            RichText(text, theme: .standard, math: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.25)))
    }
}

// MARK: - Sketchnote

struct SketchnoteView: View {
    let markdown: String
    private let pastel: [Color] = [.blue, .orange, .purple, .pink, .teal, .green, .indigo, .yellow]

    var body: some View {
        let s = Sections.parse(markdown)
        let big = Sections.find(s, ["big idea"])
        let concepts = Sections.find(s, ["concept"]).map { Sections.bullets($0.lines) } ?? []
        let links = Sections.find(s, ["connect"]).map { Sections.bullets($0.lines) } ?? []
        let remember = Sections.find(s, ["remember", "takeaway"]).map { Sections.bullets($0.lines) } ?? []

        if concepts.isEmpty {
            MarkdownView(markdown: markdown)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if let big {
                    HStack(spacing: 14) {
                        Text("💡").font(.system(size: 40))
                        RichText(big.body.trimmingCharacters(in: .whitespacesAndNewlines), theme: .standard, math: true,
                                 font: .custom("Noteworthy-Bold", size: 22))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                            .foregroundStyle(Color.brand)
                    )
                }

                label("Key Concepts")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(Array(concepts.enumerated()), id: \.offset) { i, c in
                        conceptCard(c.text, color: pastel[i % pastel.count], fallbackIcon: fallbackIcons[i % fallbackIcons.count])
                    }
                }

                if !links.isEmpty {
                    label("How It Connects")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(links.enumerated()), id: \.offset) { _, l in connection(l.text) }
                    }
                }

                if !remember.isEmpty {
                    label("Remember")
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(remember.enumerated()), id: \.offset) { i, r in
                            RichText(r.text.replacingOccurrences(of: "**", with: ""), theme: .notebook, math: true,
                                     font: .custom("Noteworthy-Bold", size: 15), color: .black.opacity(0.8))
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                                .background(Color(red: 1, green: 0.93, blue: 0.55))
                                .shadow(color: .black.opacity(0.12), radius: 3, x: 1, y: 3)
                                .rotationEffect(.degrees(i % 2 == 0 ? -1.5 : 1.5))
                        }
                    }
                }
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption.weight(.heavy)).tracking(1.2).foregroundStyle(.secondary)
    }

    private let fallbackIcons = ["lightbulb.fill", "bolt.fill", "atom", "function", "leaf.fill", "star.fill", "flag.fill", "puzzlepiece.fill"]

    private func conceptCard(_ raw: String, color: Color, fallbackIcon: String) -> some View {
        // "<emoji> **Concept** — description"
        var text = raw.trimmingCharacters(in: .whitespaces)
        var emoji: String? = nil
        if let first = text.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true
            || (first.unicodeScalars.count > 1 && first.unicodeScalars.first?.properties.isEmoji == true) {
            emoji = String(first)
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var title = text
        var desc = ""
        for sep in [" — ", " – ", " - "] {
            if let r = text.range(of: sep) {
                title = String(text[..<r.lowerBound]); desc = String(text[r.upperBound...]); break
            }
        }
        title = title.replacingOccurrences(of: "**", with: "")
        return VStack(alignment: .leading, spacing: 6) {
            if let emoji { Text(emoji).font(.system(size: 30)) }
            else { Image(systemName: fallbackIcon).font(.system(size: 24)).foregroundStyle(color).frame(height: 36) }
            Text(title).font(.system(.headline, design: .rounded))
            if !desc.isEmpty { RichText(desc, theme: .standard, math: true, font: .callout, color: .secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.35), lineWidth: 1.5))
    }

    private func connection(_ raw: String) -> some View {
        let text = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "->", with: "→")
        let parts = text.components(separatedBy: "→")
        let a = parts.first?.trimmingCharacters(in: .whitespaces) ?? text
        var b = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        var rel = ""
        if let r = b.range(of: ":") { rel = String(b[r.upperBound...]).trimmingCharacters(in: .whitespaces); b = String(b[..<r.lowerBound]) }
        return HStack(spacing: 10) {
            pill(a)
            VStack(spacing: 0) {
                if !rel.isEmpty { RichText(rel, theme: .standard, math: true, font: .caption, color: .secondary).frame(maxWidth: 320) }
                Image(systemName: "arrow.right").foregroundStyle(Color.brand)
            }
            if !b.isEmpty { pill(b) }
        }
    }

    private func pill(_ s: String) -> some View {
        Text(s).font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
    }
}

// MARK: - Timeline

struct TimelineView: View {
    let markdown: String

    var body: some View {
        let s = Sections.parse(markdown)
        let title = s.first { $0.level == 1 }?.title
        let events = Sections.find(s, ["timeline"]).map { Sections.bullets($0.lines) } ?? []
        let rest = s.filter { $0.level == 2 && !$0.title.lowercased().contains("timeline") }

        if events.isEmpty {
            MarkdownView(markdown: markdown)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if let title { Text(title).font(.system(.title2, design: .rounded).weight(.bold)) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                        let (when, what) = split(e.text)
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle().fill(Color.brand).frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                if i < events.count - 1 {
                                    Rectangle().fill(Color.brand.opacity(0.3)).frame(width: 2).frame(minHeight: 40)
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(when).font(.callout.weight(.bold)).foregroundStyle(Color.brand)
                                RichText(what, theme: .standard, math: false)
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
                ForEach(Array(rest.enumerated()), id: \.offset) { _, sec in
                    MarkdownView(markdown: "## \(sec.title)\n\(sec.body)")
                }
            }
        }
    }

    private func split(_ s: String) -> (String, String) {
        if s.hasPrefix("**"), let end = s.dropFirst(2).range(of: "**") {
            let when = String(s[s.index(s.startIndex, offsetBy: 2)..<end.lowerBound])
            var what = String(s[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            for p in ["— ", "– ", "- ", ": "] where what.hasPrefix(p) { what = String(what.dropFirst(p.count)) }
            return (when, what)
        }
        for sep in [" — ", " – ", ": "] { if let r = s.range(of: sep) { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) } }
        return ("", s)
    }
}

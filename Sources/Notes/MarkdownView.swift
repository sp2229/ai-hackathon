import SwiftUI
import AppKit

/// Visual theme for rendered notes. `.notebook` mimics handwriting on lined paper.
struct NoteTheme {
    var body: Font
    var bodySize: CGFloat
    var h1: Font
    var h2: Font
    var h3: Font
    var text: Color
    var heading: Color
    var mathFont: String
    var mathColor: NSColor
    var lineSpacing: CGFloat

    static let standard = NoteTheme(
        body: .body, bodySize: NSFont.systemFontSize + 1,
        h1: .title2.weight(.bold),
        h2: .system(.title3, design: .rounded).weight(.semibold),
        h3: .headline,
        text: .primary, heading: .brand,
        mathFont: "latinmodern-math", mathColor: .labelColor, lineSpacing: 3)

    static let ink = Color(red: 0.10, green: 0.20, blue: 0.52)
    static let notebook = NoteTheme(
        body: .custom("Noteworthy-Light", size: 17), bodySize: 17,
        h1: .custom("Noteworthy-Bold", size: 28),
        h2: .custom("Noteworthy-Bold", size: 21),
        h3: .custom("Noteworthy-Bold", size: 18),
        text: ink, heading: Color(red: 0.72, green: 0.15, blue: 0.18),
        // Euler was designed by Hermann Zapf to look like a mathematician's handwriting
        mathFont: "Euler-Math",
        mathColor: NSColor(red: 0.10, green: 0.20, blue: 0.52, alpha: 1), lineSpacing: 6)
}

/// Block-level Markdown renderer: headings, bullets, checkboxes, numbered lists,
/// tables, rules, and LaTeX math ($inline$ and $$display$$).
struct MarkdownView: View {
    let markdown: String
    var theme: NoteTheme = .standard
    var math: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.blocks(markdown, math: math).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, theme: theme, math: math)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MDBlock {
    case h1(String), h2(String), h3(String)
    case bullet(String, Int)
    case numbered(String, String, Int)
    case task(String, Bool)
    case para(String)
    case math(String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func blocks(_ md: String, math: Bool) -> [MDBlock] {
        var out: [MDBlock] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }

            // Display math: $$...$$ on one line, or spanning lines; also \[ ... \]
            if math, line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let close = line.hasPrefix("$$") ? "$$" : "\\]"
                var body = String(line.dropFirst(2))
                if let r = body.range(of: close) {
                    let after = body[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    body = String(body[..<r.lowerBound])
                    out.append(.math(body.trimmingCharacters(in: .whitespaces)))
                    if !after.isEmpty { out.append(.para(after)) }
                    continue
                }
                var closed = false
                while i < lines.count {
                    let l = lines[i]; i += 1
                    if let r = l.range(of: close) {
                        body += "\n" + l[..<r.lowerBound]
                        closed = true
                        break
                    }
                    body += "\n" + l
                }
                // Unclosed (still streaming) → show as text until it completes
                out.append(closed ? .math(body.trimmingCharacters(in: .whitespacesAndNewlines)) : .para(line))
                continue
            }

            // Tables
            if line.hasPrefix("|") {
                var rows: [[String]] = [cells(line)]
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let l = lines[i].trimmingCharacters(in: .whitespaces); i += 1
                    if l.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil { continue } // separator
                    rows.append(cells(l))
                }
                out.append(.table(rows))
                continue
            }

            if line == "---" || line == "***" { out.append(.rule); continue }
            if line.hasPrefix("### ") { out.append(.h3(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { out.append(.h2(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { out.append(.h1(String(line.dropFirst(2)))); continue }
            if let t = strip(line, ["- [ ] ", "* [ ] "]) { out.append(.task(t, false)); continue }
            if let t = strip(line, ["- [x] ", "- [X] ", "* [x] "]) { out.append(.task(t, true)); continue }
            if let t = strip(line, ["- ", "* ", "• "]) {
                // A bullet that is only display math
                if math, let m = displayMathOnly(t) { out.append(.math(m)); continue }
                out.append(.bullet(t, indent)); continue
            }
            if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let num = line[r].trimmingCharacters(in: .whitespaces)
                let rest = String(line[r.upperBound...])
                out.append(.numbered(num, rest, indent)); continue
            }
            out.append(.para(line))
        }
        return out
    }

    private static func strip(_ s: String, _ prefixes: [String]) -> String? {
        for p in prefixes where s.hasPrefix(p) { return String(s.dropFirst(p.count)) }
        return nil
    }

    private static func displayMathOnly(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("$$"), t.hasSuffix("$$"), t.count > 4 else { return nil }
        return String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func cells(_ line: String) -> [String] {
        var l = line
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct BlockView: View {
    let block: MDBlock
    let theme: NoteTheme
    let math: Bool

    var body: some View {
        switch block {
        case .h1(let t):
            RichText(t, theme: theme, math: math, font: theme.h1, mathScale: 1.4).padding(.top, 6)
        case .h2(let t):
            RichText(t, theme: theme, math: math, font: theme.h2, color: theme.heading, mathScale: 1.2).padding(.top, 12)
        case .h3(let t):
            RichText(t, theme: theme, math: math, font: theme.h3).padding(.top, 4)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(theme.text.opacity(0.6))
                RichText(t, theme: theme, math: math)
            }
            .padding(.leading, CGFloat(indent) * 18 + 2)
        case .numbered(let n, let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).foregroundStyle(theme.heading).monospacedDigit()
                RichText(t, theme: theme, math: math)
            }
            .padding(.leading, CGFloat(indent) * 18 + 2)
        case .task(let t, let done):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.brand : theme.text.opacity(0.6))
                RichText(t, theme: theme, math: math)
            }
        case .para(let t):
            RichText(t, theme: theme, math: math)
        case .math(let latex):
            MathBlock(latex: latex, theme: theme)
        case .table(let rows):
            TableBlock(rows: rows, theme: theme, math: math)
        case .rule:
            Divider().padding(.vertical, 6)
        }
    }
}

/// Text with inline Markdown (bold/italic/code) and inline LaTeX ($...$ or \(...\)).
struct RichText: View {
    let source: String
    let theme: NoteTheme
    let math: Bool
    var font: Font?
    var color: Color?
    var mathScale: CGFloat = 1

    init(_ source: String, theme: NoteTheme, math: Bool, font: Font? = nil, color: Color? = nil, mathScale: CGFloat = 1) {
        // Bold/italic markers hugging math would otherwise show as literal asterisks
        self.source = source
            .replacingOccurrences(of: "**$", with: "$").replacingOccurrences(of: "$**", with: "$")
        self.theme = theme; self.math = math; self.font = font; self.color = color; self.mathScale = mathScale
    }

    var body: some View {
        build()
            .font(font ?? theme.body)
            .foregroundStyle(color ?? theme.text)
            .lineSpacing(theme.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func build() -> Text {
        guard math else { return Text(inline(source)) }
        // $...$ (not $$), opening $ not followed by space, closing $ not preceded by space or followed by a digit
        // $$...$$ inline, then $...$ (opening $ not followed by space, closing not preceded by space or followed by a digit), then \(...\)
        let pattern = #"\$\$(.+?)\$\$|(?<![\\$])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\d)|\\\((.+?)\\\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return Text(inline(source)) }
        let ns = source as NSString
        var result = Text("")
        var cursor = 0
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                result = result + Text(inline(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            let r = [1, 2, 3].map { m.range(at: $0) }.first { $0.location != NSNotFound } ?? m.range
            let latex = ns.substring(with: r)
            if let img = MathRenderer.render(latex, fontName: theme.mathFont, size: theme.bodySize * mathScale,
                                              color: theme.mathColor, display: false) {
                result = result + Text(Image(nsImage: img.image)).baselineOffset(-img.descent)
            } else {
                result = result + Text(latex).font(.system(.body, design: .monospaced))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result = result + Text(inline(ns.substring(from: cursor))) }
        return result
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct MathBlock: View {
    let latex: String
    let theme: NoteTheme

    var body: some View {
        Group {
            if let r = MathRenderer.render(latex, fontName: theme.mathFont, size: theme.bodySize * 1.25,
                                           color: theme.mathColor, display: true) {
                Image(nsImage: r.image)
                    .renderingMode(.template)
                    .foregroundStyle(theme.text)
                    .help(latex)
            } else {
                Text(latex).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy LaTeX") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latex, forType: .string)
            }
        }
    }
}

struct TableBlock: View {
    let rows: [[String]]
    let theme: NoteTheme
    let math: Bool

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            let cell = c < row.count ? row[c] : ""
                            RichText(cell, theme: theme, math: math, font: r == 0 ? theme.body.weight(.semibold) : theme.body)
                                .frame(minWidth: 90, maxWidth: 260, alignment: .leading)
                                .padding(8)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(r == 0 ? Color.brand.opacity(0.12) : (r % 2 == 0 ? Color.primary.opacity(0.03) : .clear))
                        }
                    }
                    if r < rows.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 4)
    }
}

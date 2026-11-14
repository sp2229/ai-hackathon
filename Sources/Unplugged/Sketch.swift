import SwiftUI

/// A tiny drawing language the LLM writes inside ```sketch blocks, rendered natively
/// with SwiftUI Canvas — real diagrams (members, springs, supports, loads, dimensions)
/// from a 1.58-bit text model, with no image model and no network.
///
/// Grid: 0–100, x to the right, y downward. One shape per line.
enum Sketch {
    static let promptGuide = """
    DRAWINGS: When the speaker describes something physical or a process, draw it in a fenced ```sketch block. \
    The app does the layout — just describe the parts, one per line, using the real labels and numbers that were spoken.

    Structural members:
    column "<cross-section, e.g. 12x12 in>" height "<e.g. 10 ft>"
    beam "<span, e.g. 20 ft>"
    support <bottom|top|left|right|mid> <pin|roller|fixed|spring> "<label, e.g. k = 50 kip/in>"
    load <top|left|right|mid> "<point load, e.g. P = 10 kip>"
    udl "<distributed load, e.g. w = 2 kip/ft>"

    Processes / how things connect:
    flow "<step 1>" -> "<step 2>" -> "<step 3>"

    Example (a beam):
    ```sketch
    beam "24 ft"
    support left pin
    support right roller
    load mid "P = 8 kip"
    ```
    Example (a column):
    ```sketch
    column "W12x50" height "14 ft"
    support bottom fixed
    load top "P = 75 kip"
    ```
    For anything else you may use raw shapes on a 100×100 grid (x right, y down): \
    box x y w h "label" · circle x y r "label" · line x1 y1 x2 y2 · arrow x1 y1 x2 y2 "label" · \
    spring x1 y1 x2 y2 "label" · dim x1 y1 x2 y2 "label" · text x y "label"
    """

    enum Shape {
        case box(CGFloat, CGFloat, CGFloat, CGFloat, String?)
        case circle(CGFloat, CGFloat, CGFloat, String?)
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint, String?)
        case spring(CGPoint, CGPoint, String?)
        case support(CGPoint, String)
        case ground(CGFloat, CGFloat, CGFloat)
        case dim(CGPoint, CGPoint, String?)
        case text(CGPoint, String)
    }

    static func parse(_ src: String) -> [Shape] {
        let lines = src.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let semantic = lines.contains { l in ["column", "beam", "flow", "udl"].contains { l.lowercased().hasPrefix($0) } }
        if semantic { return Layout.build(lines) }
        return lines.compactMap { parseLine($0) }
    }

    static func quoted(_ line: String) -> [String] {
        var out: [String] = []
        var rest = Substring(line)
        while let q1 = rest.firstIndex(of: "\""), let q2 = rest[rest.index(after: q1)...].firstIndex(of: "\"") {
            out.append(String(rest[rest.index(after: q1)..<q2]))
            rest = rest[rest.index(after: q2)...]
        }
        return out
    }

    /// Auto-layout for semantic structural sketches: the model names parts, we place them.
    enum Layout {
        static func build(_ lines: [String]) -> [Shape] {
            var shapes: [Shape] = []
            let lower = lines.map { $0.lowercased() }
            func words(_ l: String) -> [String] {
                l.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
                    .split(separator: " ").map { String($0).lowercased() }
            }

            // Process flow: boxes connected by arrows
            if let f = lines.first(where: { $0.lowercased().hasPrefix("flow") }) {
                let steps = quoted(f)
                guard !steps.isEmpty else { return [] }
                let n = CGFloat(steps.count)
                let gap: CGFloat = 8
                let w = min(28, (100 - gap * (n - 1)) / n)
                for (i, step) in steps.enumerated() {
                    let x = CGFloat(i) * (w + gap)
                    shapes.append(.box(x, 40, w, 16, step))
                    if i > 0 { shapes.append(.arrow(CGPoint(x: x - gap + 1, y: 48), CGPoint(x: x - 1, y: 48), nil)) }
                }
                return shapes
            }

            if let c = lines.first(where: { $0.lowercased().hasPrefix("column") }) {
                // Section & height — accepts `column "18x18 in" height "12 ft"` or `column "18" x "18" height "12 ft"`
                var section: String?
                var height: String?
                if let hr = c.range(of: "height", options: .caseInsensitive) {
                    height = quoted(String(c[hr.upperBound...])).first ?? unquotedLabel(String(c[hr.upperBound...]))
                    let before = quoted(String(c[..<hr.lowerBound]))
                    section = before.isEmpty ? nil : before.joined(separator: "x")
                } else {
                    let q = quoted(c)
                    section = q.first
                    height = q.count > 1 ? q[1] : nil
                }
                let x: CGFloat = 40, top: CGFloat = 20, bottom: CGFloat = 75, w: CGFloat = 9
                shapes.append(.box(x - w / 2, top, w, bottom - top, nil))
                if let height { shapes.append(.dim(CGPoint(x: x - 14, y: top), CGPoint(x: x - 14, y: bottom), height)) }
                if let section { shapes += crossSection(section, at: CGPoint(x: 72, y: 34)) }

                // A label given on its own "spring …" line belongs to the spring support
                let springLabel = lines.first { $0.lowercased().hasPrefix("spring") }.flatMap { labelOf($0) }
                var notes: [String] = []
                for (i, l) in lower.enumerated() where i != lines.firstIndex(of: c) {
                    let ws = words(l)
                    let label = labelOf(lines[i])
                    if l.hasPrefix("support") || (l.hasPrefix("spring") && !lower.contains { $0.hasPrefix("support") }) {
                        let atTop = ws.contains("top")
                        let kind = l.hasPrefix("spring") ? ["spring"] : ws
                        shapes += support(kind: kind, at: CGPoint(x: x, y: atTop ? top : bottom),
                                          label: label ?? (kind.contains("spring") ? springLabel : nil), upward: atTop)
                    } else if l.hasPrefix("load") || l.hasPrefix("force") {
                        if ws.contains("left") || ws.contains("right") || ws.contains("mid") {
                            let dir: CGFloat = ws.contains("right") ? 1 : -1
                            let y = (top + bottom) / 2
                            shapes.append(.arrow(CGPoint(x: x - dir * 22, y: y), CGPoint(x: x - dir * w / 2, y: y), label))
                        } else {
                            shapes.append(.arrow(CGPoint(x: x, y: top - 16), CGPoint(x: x, y: top), label))
                        }
                    } else if !l.hasPrefix("spring"), let label {
                        notes.append(label)   // e.g. `settlement base "δ = 0.4 in"` → annotation
                    }
                }
                for (j, n) in notes.enumerated() {
                    shapes.append(.text(CGPoint(x: 64, y: 66 + CGFloat(j) * 6), n))
                }
                return shapes
            }

            // Beam (default for udl/beam)
            let bl = lines.first(where: { $0.lowercased().hasPrefix("beam") })
            let span = bl.flatMap { quoted($0).first }
            let left: CGFloat = 10, right: CGFloat = 90, y: CGFloat = 40, h: CGFloat = 5
            shapes.append(.box(left, y, right - left, h, nil))
            var hasSupportBelow = false
            for (i, l) in lower.enumerated() {
                let ws = words(l)
                let label = l.hasPrefix("beam") ? nil : labelOf(lines[i])
                func xpos() -> CGFloat {
                    if ws.contains("left") { return left }
                    if ws.contains("right") { return right }
                    if let pct = ws.compactMap({ Double($0.replacingOccurrences(of: "%", with: "")) }).first {
                        return left + (right - left) * CGFloat(min(max(pct, 0), 100)) / 100
                    }
                    return (left + right) / 2
                }
                if l.hasPrefix("support") {
                    shapes += support(kind: ws, at: CGPoint(x: xpos(), y: y + h), label: label, upward: false)
                    hasSupportBelow = true
                } else if l.hasPrefix("load") {
                    // Point loads start higher when a distributed load is also drawn, so labels don't collide
                    let px = xpos()
                    let hasUDL = lower.contains { $0.hasPrefix("udl") }
                    shapes.append(.arrow(CGPoint(x: px, y: y - (hasUDL ? 26 : 18)), CGPoint(x: px, y: y - (hasUDL ? 9 : 0)), label))
                } else if l.hasPrefix("udl") {
                    var px = left + 4
                    while px <= right - 3 {
                        shapes.append(.arrow(CGPoint(x: px, y: y - 9), CGPoint(x: px, y: y), nil))
                        px += 8
                    }
                    shapes.append(.line(CGPoint(x: left + 4, y: y - 9), CGPoint(x: px - 8, y: y - 9)))
                    shapes.append(.text(CGPoint(x: left + 4, y: y - 14), label ?? "w"))
                }
            }
            if let span {
                let dy: CGFloat = hasSupportBelow ? 66 : 55
                shapes.append(.dim(CGPoint(x: left, y: dy), CGPoint(x: right, y: dy), span))
            }
            return shapes
        }

        static let keywords: Set<String> = ["support", "load", "force", "spring", "bottom", "top", "left", "right", "mid",
                                            "base", "pin", "roller", "fixed", "axial", "point", "stiffness", "udl"]

        /// Quoted label if present, otherwise the leftover words after keywords (e.g. `k=500 kips/in`).
        static func labelOf(_ line: String) -> String? {
            if let q = quoted(line).first, !q.isEmpty { return q }
            return unquotedLabel(line)
        }

        static func unquotedLabel(_ line: String) -> String? {
            let parts = line.split(separator: " ").map(String.init)
            let rest = parts.drop { keywords.contains($0.lowercased()) || parts.first == $0 }
                .filter { !keywords.contains($0.lowercased()) }
            let t = rest.joined(separator: " ").replacingOccurrences(of: "=", with: " = ")
                .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }

        /// Support symbol at a point. `upward` draws it above (e.g. the top of a column).
        static func support(kind ws: [String], at p: CGPoint, label: String?, upward: Bool) -> [Shape] {
            let dir: CGFloat = upward ? -1 : 1
            if ws.contains("spring") {
                let end = CGPoint(x: p.x, y: p.y + dir * 14)
                return [.spring(p, end, label ?? "k"), .ground(p.x, end.y + (upward ? -1 : 1), 16)]
            }
            if upward {
                return [.ground(p.x, p.y - 1, 16)] + (label.map { [.text(CGPoint(x: p.x + 10, y: p.y - 6), $0)] } ?? [])
            }
            let kind = ws.contains("fixed") ? "fixed" : ws.contains("roller") ? "roller" : "pin"
            return [.support(p, kind)] + (label.map { [.text(CGPoint(x: p.x + 8, y: p.y + 6), $0)] } ?? [])
        }

        /// "18x18 in" → a small square section with both dimensions.
        static func crossSection(_ label: String, at o: CGPoint) -> [Shape] {
            let nums = label.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap { Double($0) }.filter { $0 > 0 }
            let unit = label.range(of: #"[a-zA-Z"']+\s*$"#, options: .regularExpression).map { String(label[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            guard nums.count >= 2 else { return [.text(CGPoint(x: o.x - 6, y: o.y - 8), "Section: \(label)")] }
            let (bw, bh) = (nums[0], nums[1])
            let size: CGFloat = 16
            let w = size * CGFloat(min(1, bw / max(bh, 1))), h = size * CGFloat(min(1, bh / max(bw, 1)))
            func fmt(_ v: Double) -> String { (v == v.rounded() ? String(Int(v)) : String(v)) + (unit.isEmpty ? "" : " \(unit)") }
            return [
                .text(CGPoint(x: o.x, y: o.y - 8), "Section"),
                .box(o.x, o.y, w, h, nil),
                .dim(CGPoint(x: o.x, y: o.y + h + 6), CGPoint(x: o.x + w, y: o.y + h + 6), fmt(bw)),
                .dim(CGPoint(x: o.x + w + 6, y: o.y), CGPoint(x: o.x + w + 6, y: o.y + h), fmt(bh)),
            ]
        }
    }

    private static func parseLine(_ raw: String) -> Shape? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return nil }
        // Pull out the quoted label (if any)
        var label: String?
        if let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
            label = String(line[line.index(after: q1)..<q2])
            line = String(line[..<q1]) + String(line[line.index(after: q2)...])
        }
        // Accept "x=10" style too
        let tokens = line.replacingOccurrences(of: #"[a-z0-9]+="#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard let kind = tokens.first?.lowercased() else { return nil }
        let n = tokens.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        let words = tokens.dropFirst().filter { Double($0) == nil }
        func p(_ i: Int) -> CGPoint { CGPoint(x: n[i], y: n[i + 1]) }

        switch kind {
        case "box", "rect", "rectangle":
            return n.count >= 4 ? .box(n[0], n[1], n[2], n[3], label) : nil
        case "circle":
            return n.count >= 3 ? .circle(n[0], n[1], n[2], label) : nil
        case "line":
            return n.count >= 4 ? .line(p(0), p(2)) : nil
        case "arrow", "force", "load":
            return n.count >= 4 ? .arrow(p(0), p(2), label) : nil
        case "spring":
            return n.count >= 4 ? .spring(p(0), p(2), label) : nil
        case "support":
            return n.count >= 2 ? .support(p(0), (words.first ?? label ?? "pin").lowercased()) : nil
        case "ground":
            return n.count >= 2 ? .ground(n[0], n[1], n.count >= 3 ? n[2] : 30) : nil
        case "dim", "dimension":
            return n.count >= 4 ? .dim(p(0), p(2), label) : nil
        case "text", "label":
            return n.count >= 2 ? .text(p(0), label ?? words.joined(separator: " ")) : nil
        default:
            return nil
        }
    }

    /// Bounding box of all shapes in grid units (with room for labels).
    static func bounds(_ shapes: [Shape]) -> CGRect {
        var pts: [CGPoint] = []
        for s in shapes {
            switch s {
            case .box(let x, let y, let w, let h, _): pts += [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + h)]
            case .circle(let x, let y, let r, _): pts += [CGPoint(x: x - r, y: y - r), CGPoint(x: x + r, y: y + r)]
            case .line(let a, let b), .arrow(let a, let b, _), .spring(let a, let b, _), .dim(let a, let b, _): pts += [a, b]
            case .support(let a, _): pts += [a, CGPoint(x: a.x - 5, y: a.y + 9), CGPoint(x: a.x + 5, y: a.y + 9)]
            case .ground(let x, let y, let w): pts += [CGPoint(x: x - w / 2, y: y), CGPoint(x: x + w / 2, y: y + 4)]
            case .text(let a, _): pts += [a]
            }
        }
        guard let first = pts.first else { return CGRect(x: 0, y: 0, width: 100, height: 100) }
        var r = CGRect(origin: first, size: .zero)
        for q in pts { r = r.union(CGRect(origin: q, size: .zero)) }
        return r.insetBy(dx: -12, dy: -10)
    }
}

/// Renders a ```sketch block like an ink drawing in a notebook.
struct SketchView: View {
    let source: String
    var ink: Color = NoteTheme.ink
    var labelFont: Font = .custom("Noteworthy-Bold", size: 14)

    var body: some View {
        let shapes = Sketch.parse(source)
        if shapes.isEmpty {
            Text(source).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            let b = Sketch.bounds(shapes)
            let maxW: CGFloat = 560
            let scale = min(maxW / max(b.width, 1), 7)
            let size = CGSize(width: b.width * scale, height: min(b.height * scale, 520))
            let s = min(scale, 520 / max(b.height, 1))
            Canvas { ctx, _ in
                func P(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - b.minX) * s, y: (p.y - b.minY) * s) }
                func L(_ v: CGFloat) -> CGFloat { v * s }
                let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                let thin = StrokeStyle(lineWidth: 1.2, lineCap: .round)
                func label(_ t: String?, at p: CGPoint, anchor: UnitPoint = .center) {
                    guard let t, !t.isEmpty else { return }
                    ctx.draw(Text(t).font(labelFont).foregroundColor(ink), at: p, anchor: anchor)
                }

                for shape in shapes {
                    switch shape {
                    case .box(let x, let y, let w, let h, let t):
                        let r = CGRect(origin: P(CGPoint(x: x, y: y)), size: CGSize(width: L(w), height: L(h)))
                        ctx.fill(Path(r), with: .color(ink.opacity(0.06)))
                        ctx.stroke(Path(r), with: .color(ink), style: stroke)
                        // Label inside if it fits, otherwise beside it
                        if r.width > 70 && r.height > 22 { label(t, at: CGPoint(x: r.midX, y: r.midY)) }
                        else if r.height > r.width { label(t, at: CGPoint(x: r.maxX + 8, y: r.midY), anchor: .leading) }
                        else { label(t, at: CGPoint(x: r.midX, y: r.minY - 10)) }

                    case .circle(let x, let y, let rad, let t):
                        let c = P(CGPoint(x: x, y: y)); let r = L(rad)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(ink), style: stroke)
                        label(t, at: CGPoint(x: c.x, y: c.y + r + 12))

                    case .line(let a, let bb):
                        ctx.stroke(Path { $0.move(to: P(a)); $0.addLine(to: P(bb)) }, with: .color(ink), style: stroke)

                    case .arrow(let a, let bb, let t):
                        let pa = P(a), pb = P(bb)
                        ctx.stroke(Path { $0.move(to: pa); $0.addLine(to: pb) }, with: .color(.red.opacity(0.85)), style: stroke)
                        ctx.fill(arrowHead(at: pb, from: pa, size: 11), with: .color(.red.opacity(0.85)))
                        let horizontal = abs(pb.x - pa.x) > abs(pb.y - pa.y)
                        label(t, at: horizontal ? CGPoint(x: pa.x, y: pa.y - 12) : CGPoint(x: pa.x + 8, y: pa.y + 4),
                              anchor: horizontal ? .center : .leading)

                    case .spring(let a, let bb, let t):
                        let pa = P(a), pb = P(bb)
                        ctx.stroke(springPath(pa, pb, coils: 7, amp: max(6, L(2.5))), with: .color(ink), style: stroke)
                        let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                        label(t, at: CGPoint(x: mid.x + max(10, L(3.5)), y: mid.y), anchor: .leading)

                    case .support(let a, let kind):
                        let p = P(a); let w: CGFloat = max(14, L(5)), h: CGFloat = max(12, L(6))
                        if kind.contains("fix") {
                            ctx.stroke(Path { $0.move(to: CGPoint(x: p.x - w, y: p.y)); $0.addLine(to: CGPoint(x: p.x + w, y: p.y)) }, with: .color(ink), style: stroke)
                            hatch(ctx, from: CGPoint(x: p.x - w, y: p.y), width: 2 * w, color: ink)
                        } else {
                            let tri = Path { $0.move(to: p); $0.addLine(to: CGPoint(x: p.x - w * 0.7, y: p.y + h)); $0.addLine(to: CGPoint(x: p.x + w * 0.7, y: p.y + h)); $0.closeSubpath() }
                            ctx.stroke(tri, with: .color(ink), style: stroke)
                            var baseY = p.y + h
                            if kind.contains("roll") {
                                for dx in [-w * 0.4, 0, w * 0.4] {
                                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x + dx - 3, y: baseY + 1, width: 6, height: 6)), with: .color(ink), style: thin)
                                }
                                baseY += 8
                            }
                            hatch(ctx, from: CGPoint(x: p.x - w, y: baseY), width: 2 * w, color: ink)
                        }

                    case .ground(let x, let y, let w):
                        let a = P(CGPoint(x: x - w / 2, y: y)); let width = L(w)
                        hatch(ctx, from: a, width: width, color: ink)

                    case .dim(let a, let bb, let t):
                        let pa = P(a), pb = P(bb)
                        let c = Color.secondary
                        ctx.stroke(Path { $0.move(to: pa); $0.addLine(to: pb) }, with: .color(c), style: thin)
                        ctx.fill(arrowHead(at: pb, from: pa, size: 7), with: .color(c))
                        ctx.fill(arrowHead(at: pa, from: pb, size: 7), with: .color(c))
                        // extension ticks
                        let dx = pb.x - pa.x, dy = pb.y - pa.y, len = max(hypot(dx, dy), 1)
                        let nx = -dy / len * 6, ny = dx / len * 6
                        for q in [pa, pb] {
                            ctx.stroke(Path { $0.move(to: CGPoint(x: q.x - nx, y: q.y - ny)); $0.addLine(to: CGPoint(x: q.x + nx, y: q.y + ny)) }, with: .color(c), style: thin)
                        }
                        let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                        let vertical = abs(dy) > abs(dx)
                        label(t, at: vertical ? CGPoint(x: mid.x + 8, y: mid.y) : CGPoint(x: mid.x, y: mid.y + 12),
                              anchor: vertical ? .leading : .center)

                    case .text(let a, let t):
                        label(t, at: P(a), anchor: .leading)
                    }
                }
            }
            .frame(width: size.width, height: b.height * s)
            .padding(12)
            .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)
            .contextMenu {
                Button("Copy sketch source") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                }
            }
        }
    }

    private func arrowHead(at tip: CGPoint, from tail: CGPoint, size: CGFloat) -> Path {
        let ang = atan2(tip.y - tail.y, tip.x - tail.x)
        return Path { p in
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x - size * cos(ang - .pi / 7), y: tip.y - size * sin(ang - .pi / 7)))
            p.addLine(to: CGPoint(x: tip.x - size * cos(ang + .pi / 7), y: tip.y - size * sin(ang + .pi / 7)))
            p.closeSubpath()
        }
    }

    private func springPath(_ a: CGPoint, _ b: CGPoint, coils: Int, amp: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1)
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let lead = len * 0.15
        return Path { p in
            p.move(to: a)
            p.addLine(to: CGPoint(x: a.x + ux * lead, y: a.y + uy * lead))
            let body = len - 2 * lead
            let steps = coils * 2
            for i in 1...steps {
                let t = lead + body * CGFloat(i) / CGFloat(steps + 1)
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                p.addLine(to: CGPoint(x: a.x + ux * t + nx * amp * side, y: a.y + uy * t + ny * amp * side))
            }
            p.addLine(to: CGPoint(x: b.x - ux * lead, y: b.y - uy * lead))
            p.addLine(to: b)
        }
    }

    private func hatch(_ ctx: GraphicsContext, from a: CGPoint, width: CGFloat, color: Color) {
        ctx.stroke(Path { $0.move(to: a); $0.addLine(to: CGPoint(x: a.x + width, y: a.y)) }, with: .color(color), style: StrokeStyle(lineWidth: 2))
        var x = a.x + 4
        while x < a.x + width {
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: a.y)); $0.addLine(to: CGPoint(x: x - 6, y: a.y + 7)) }, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1))
            x += 7
        }
    }
}

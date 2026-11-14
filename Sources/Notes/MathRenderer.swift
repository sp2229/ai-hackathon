import AppKit
import SwiftMath

/// Renders LaTeX to images natively with SwiftMath (CoreText, no web view, no network).
/// Results are cached so streaming tokens don't re-typeset the same equation.
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        let descent: CGFloat
    }

    private static let fonts = MTFontManager()
    private static var cache: [String: Rendered?] = [:]

    static func render(_ latex: String, fontName: String, size: CGFloat, color: NSColor, display: Bool) -> Rendered? {
        let key = "\(fontName)|\(size)|\(color.description)|\(display)|\(latex)"
        if let hit = cache[key] { return hit }
        let result = typeset(latex, fontName: fontName, size: size, color: color, display: display)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static func typeset(_ latex: String, fontName: String, size: CGFloat, color: NSColor, display: Bool) -> Rendered? {
        guard let font = fonts.font(withName: fontName, size: size) ?? fonts.font(withName: "latinmodern-math", size: size)
        else { return nil }

        // Measure with the label (gives us the baseline/descent for inline alignment)…
        let label = MTMathUILabel()
        label.font = font
        label.labelMode = display ? .display : .text
        label.latex = latex
        guard label.error == nil else { return nil }
        let fit = label.fittingSize
        label.frame = CGRect(origin: .zero, size: fit)
        label.layout()
        guard let list = label.displayList, fit.width > 1 else { return nil }

        // …and draw with MTMathImage, which places the baseline at `descent` from the bottom.
        let img = MTMathImage(latex: latex, fontSize: size, textColor: color,
                              labelMode: display ? .display : .text, textAlignment: .left)
        img.font = font
        let (err, image) = img.asImage()
        guard err == nil, let image else { return nil }
        // Template image: SwiftUI tints it with the surrounding text color (works in light & dark mode)
        image.isTemplate = true
        return Rendered(image: image, descent: list.descent)
    }
}

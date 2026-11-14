import Foundation
import PDFKit
import Vision
import AppKit
import UniformTypeIdentifiers

/// Extracts text from slides, handouts, and notes — 100% on-device.
///  • PDF → PDFKit text layer; scanned pages fall back to Apple Vision OCR
///  • PowerPoint (.pptx) / Word (.docx) → unzip + XML text runs
///  • Images (photos of whiteboards, handwritten notes) → Vision OCR
///  • Text / Markdown / LaTeX / RTF → read directly
enum DocumentImporter {
    static let allowedTypes: [UTType] = [
        .pdf, .image, .plainText, .rtf, .text,
        UTType(filenameExtension: "md"), UTType(filenameExtension: "tex"),
        UTType(filenameExtension: "pptx"), UTType(filenameExtension: "docx"),
    ].compactMap { $0 }

    /// Hard cap per document so a 300-page PDF can't blow up the LLM context.
    static let maxChars = 20_000

    static func extract(_ url: URL) async throws -> ContextDoc {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        var kind = "Text"
        var text: String

        switch ext {
        case "pdf":
            kind = "PDF"
            text = try pdfText(url)
        case "pptx":
            kind = "Slides"
            text = try officeText(url, entryPrefix: "ppt/slides/slide", tag: "a:t", label: "Slide")
        case "docx":
            kind = "Word"
            text = try officeText(url, entryPrefix: "word/document", tag: "w:t", label: nil)
        case "rtf":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string) ?? ""
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp":
            kind = "Image (OCR)"
            guard let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw err("Couldn't read image \(name)")
            }
            text = try ocr(cg)
        case "key":
            throw err("Keynote files can't be read directly — in Keynote choose File › Export To › PDF, then attach the PDF.")
        default:
            text = try String(contentsOf: url, encoding: .utf8)
        }

        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw err("No readable text found in \(name).") }
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n[…truncated]" }
        return ContextDoc(name: name, kind: kind, text: text)
    }

    // MARK: PDF

    private static func pdfText(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw err("Couldn't open PDF.") }
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 120) {
            guard let page = doc.page(at: i) else { continue }
            var t = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Scanned page (no text layer) → OCR, but only for the first 40 to bound compute
            if t.count < 20, i < 40, let cg = render(page) {
                t = (try? ocr(cg)) ?? t
            }
            if !t.isEmpty { pages.append("[Page \(i + 1)]\n\(t)") }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: OCR (Apple Vision, on-device)

    static func ocr(_ image: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Office (pptx / docx are zip files of XML)

    private static func officeText(_ url: URL, entryPrefix: String, tag: String, label: String?) throws -> String {
        let entries = try unzip(["-Z1", url.path])
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(entryPrefix) && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        var parts: [String] = []
        for (i, entry) in entries.enumerated() {
            let xml = try unzip(["-p", url.path, entry])
            let pattern = "<\(tag)(?: [^>]*)?>([^<]*)</\(tag)>"
            let regex = try NSRegularExpression(pattern: pattern)
            // Paragraph boundaries become newlines
            let paragraphs = xml.components(separatedBy: tag == "a:t" ? "</a:p>" : "</w:p>")
            let text = paragraphs.map { para -> String in
                let ns = para as NSString
                return regex.matches(in: para, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range(at: 1)) }
                    .joined()
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
            let decoded = decodeEntities(text)
            guard !decoded.isEmpty else { continue }
            parts.append(label.map { "[\($0) \(i + 1)]\n\(decoded)" } ?? decoded)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func unzip(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func number(in s: String) -> Int {
        Int(s.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Unplugged", code: 10, userInfo: [NSLocalizedDescriptionKey: msg])
    }

}

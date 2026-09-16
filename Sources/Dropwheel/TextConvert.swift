import AppKit

/// Text-like documents (TXT, Markdown, HTML, CSV, JSON, source code, DOCX) rendered to PDF/images
/// or converted between each other, plus subtitle conversions.
enum TextConvert {
    static func readText(_ url: URL) throws -> String {
        if Formats.kind(of: url) == "docx" { return try Docx.readAttributed(url).string }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        throw ConvError.failed("Could not read \(url.lastPathComponent) as text")
    }

    static func plainAttributed(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black, .paragraphStyle: style])
    }

    /// A styled, render-ready representation of any supported text document.
    static func attributed(_ url: URL) throws -> NSAttributedString {
        switch Formats.kind(of: url) {
        case "docx": return try Docx.readAttributed(url)
        case "md": return Markdown.render(try readText(url), baseURL: url.deletingLastPathComponent())
        case "html": return try SmartText.htmlAttributed(try Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
        case "csv": return SmartText.table(rows: SmartText.parseCSV(try readText(url), url: url), title: Naming.baseName(of: url))
        case "json": return SmartText.code(SmartText.prettyJSON(try readText(url)), language: "json", fileName: url.lastPathComponent)
        case "code": return SmartText.code(try readText(url), language: url.pathExtension.lowercased(), fileName: url.lastPathComponent)
        default: return plainAttributed(try readText(url))
        }
    }

    static func convert(_ url: URL, to target: String, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, ext: target)
        switch target {
        case "pdf":
            try renderPDF(try attributed(url), to: out)
        case "jpg", "png":
            try ImageConvert.write(try renderImage(try attributed(url)), to: out, kind: target, quality: 0.92)
        case "docx":
            let attr = try attributed(url)
            let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: out)
        case "html":
            try SmartText.html(for: url).write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try SmartText.markdown(from: try attributed(url)).write(to: out, atomically: true, encoding: .utf8)
        case "json":
            try SmartText.json(fromCSV: SmartText.parseCSV(try readText(url), url: url)).write(to: out, atomically: true, encoding: .utf8)
        case "csv":
            try SmartText.csv(fromJSON: try readText(url)).write(to: out, atomically: true, encoding: .utf8)
        case "txt":
            if kind == "srt" || kind == "vtt" {
                let cues = Subtitles.parse(try readText(url))
                try cues.map { $0.text }.joined(separator: "\n\n").write(to: out, atomically: true, encoding: .utf8)
            } else if kind == "html" || kind == "docx" {
                try (try attributed(url)).string.write(to: out, atomically: true, encoding: .utf8)
            } else {
                try readText(url).write(to: out, atomically: true, encoding: .utf8)
            }
        case "srt", "vtt":
            let text = try readText(url)
            let cues = text.contains("-->") ? Subtitles.parse(text) : Subtitles.cuesFromPlainText(text)
            try (target == "srt" ? Subtitles.srt(cues) : Subtitles.vtt(cues)).write(to: out, atomically: true, encoding: .utf8)
        default:
            throw ConvError.unsupported("Cannot convert \(kind) to \(target)")
        }
        return out
    }

    // MARK: rendering (AppKit text system, so tables and attachments work)

    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 60

    private static func makeLayout(_ text: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        return (storage, manager)
    }

    /// US Letter pages with margins.
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        var page = CGRect(origin: .zero, size: pageSize)
        let textSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        guard let ctx = CGContext(url as CFURL, mediaBox: &page, nil) else { throw ConvError.failed("Cannot create PDF") }
        let (storage, manager) = makeLayout(text, width: textSize.width)
        _ = storage
        var containers: [NSTextContainer] = []
        var glyphsLaidOut = 0
        var pageCount = 0
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            let range = manager.glyphRange(for: container)
            guard range.length > 0 || pageCount == 0 else { break }
            pageCount += 1
            ctx.beginPage(mediaBox: &page)
            ctx.saveGState()
            ctx.translateBy(x: margin, y: pageSize.height - margin)
            ctx.scaleBy(x: 1, y: -1)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            manager.drawBackground(forGlyphRange: range, at: .zero)
            manager.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPage()
            glyphsLaidOut = NSMaxRange(range)
            if range.length == 0 { break }
        } while glyphsLaidOut < manager.numberOfGlyphs && pageCount < 2000
        ctx.closePDF()
    }

    /// One tall image containing the whole document (2x resolution, 8.5in wide).
    static func renderImage(_ text: NSAttributedString) throws -> CGImage {
        let width = pageSize.width + 40
        let (storage, manager) = makeLayout(text, width: width)
        _ = storage
        let container = NSTextContainer(size: CGSize(width: width - margin * 2 + 20, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let used = manager.usedRect(for: container)
        let height = min(30_000, max(200, ceil(used.height) + 80))
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConvError.failed("Cannot render text") }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 40, y: height - 40)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: .zero)
        manager.drawGlyphs(forGlyphRange: range, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { throw ConvError.failed("Cannot render text") }
        return cg
    }
}

enum Subtitles {
    struct Cue { var start: Double; var end: Double; var text: String }

    static func parse(_ raw: String) -> [Cue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let s = time(parts[0]), let e = time(parts[1]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(Cue(start: s, end: e, text: body))
        }
        return cues
    }

    static func cuesFromPlainText(_ text: String, seconds: Double = 3) -> [Cue] {
        var t = 0.0
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            defer { t += seconds }
            return Cue(start: t, end: t + seconds, text: line)
        }
    }

    private static func time(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }

    private static func stamp(_ t: Double, separator: String) -> String {
        let h = Int(t / 3600), m = Int(t.truncatingRemainder(dividingBy: 3600) / 60), s = Int(t.truncatingRemainder(dividingBy: 60))
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(c.text)\n" }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { c in "\(stamp(c.start, separator: ".")) --> \(stamp(c.end, separator: "."))\n\(c.text)\n" }.joined(separator: "\n")
    }
}

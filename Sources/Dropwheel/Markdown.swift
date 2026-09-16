import AppKit

/// Renders Markdown into a styled NSAttributedString for PDF/image/DOCX export.
/// Supports headings, paragraphs, bullet and numbered lists, fenced code, blockquotes,
/// horizontal rules, tables, images, and inline bold/italic/code/links/strikethrough.
enum Markdown {
    static func isMarkdown(_ url: URL) -> Bool { Formats.kind(of: url) == "md" }

    static let body = NSFont.systemFont(ofSize: 12)
    static let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    static func render(_ text: String, baseURL: URL? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(inline(paragraph.joined(separator: " "), font: body))
            out.append(newline)
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                out.append(codeBlock(code.joined(separator: "\n")))
                continue
            }
            if line.isEmpty { flushParagraph(); i += 1; continue }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                let style = NSMutableParagraphStyle(); style.paragraphSpacing = 10; style.alignment = .center
                out.append(NSAttributedString(string: "────────────────────────\n", attributes: [.font: body, .foregroundColor: NSColor.lightGray, .paragraphStyle: style]))
                i += 1; continue
            }
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                let level = line[m].filter { $0 == "#" }.count
                let sizes: [CGFloat] = [24, 19, 16, 14, 12.5, 12]
                let font = NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold)
                let style = NSMutableParagraphStyle(); style.paragraphSpacingBefore = level == 1 ? 6 : 10; style.paragraphSpacing = 6
                let s = NSMutableAttributedString(attributedString: inline(String(line[m.upperBound...]), font: font))
                s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
                out.append(s); out.append(newline)
                i += 1; continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                let style = NSMutableParagraphStyle(); style.headIndent = 16; style.firstLineHeadIndent = 16; style.paragraphSpacing = 8; style.paragraphSpacingBefore = 6
                let s = NSMutableAttributedString(attributedString: inline(quote.joined(separator: " "), font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)))
                s.addAttributes([.paragraphStyle: style, .foregroundColor: NSColor.darkGray], range: NSRange(location: 0, length: s.length))
                out.append(s); out.append(newline)
                continue
            }
            if line.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil {
                flushParagraph()
                var rows: [[String]] = [tableCells(line)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(tableCells(lines[i].trimmingCharacters(in: .whitespaces))); i += 1 }
                out.append(SmartText.table(rows: rows, title: nil, inlineMarkdown: true))
                continue
            }
            if let m = line.range(of: #"^!\[[^\]]*\]\(([^)\s]+)[^)]*\)$"#, options: .regularExpression) {
                flushParagraph()
                let inner = String(line[m])
                if let open = inner.range(of: "]("), let close = inner.lastIndex(of: ")") {
                    let ref = String(inner[open.upperBound..<close]).split(separator: " ").first.map(String.init) ?? ""
                    if let img = loadImage(ref, baseURL: baseURL) {
                        out.append(SmartText.attachment(img, maxWidth: TextConvert.pageSize.width - TextConvert.margin * 2))
                        out.append(newline)
                        i += 1; continue
                    }
                }
            }
            if let m = raw.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flushParagraph()
                let indentLevel = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
                let marker = raw[m].trimmingCharacters(in: .whitespaces)
                var content = String(raw[m.upperBound...])
                var prefix = marker.first!.isNumber ? marker : "•"
                if content.hasPrefix("[ ] ") { prefix = "☐"; content = String(content.dropFirst(4)) }
                else if content.lowercased().hasPrefix("[x] ") { prefix = "☑"; content = String(content.dropFirst(4)) }
                let style = NSMutableParagraphStyle()
                let indent = CGFloat(18 + indentLevel * 18)
                style.firstLineHeadIndent = indent - 14; style.headIndent = indent; style.paragraphSpacing = 3
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let s = NSMutableAttributedString(string: prefix + "\t", attributes: [.font: body])
                s.append(inline(content, font: body))
                s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
                out.append(s); out.append(newline)
                i += 1; continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    static var newline: NSAttributedString { NSAttributedString(string: "\n", attributes: [.font: body]) }

    static func codeBlock(_ code: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10; style.paragraphSpacingBefore = 4
        style.headIndent = 12; style.firstLineHeadIndent = 12; style.tailIndent = -12
        return NSAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: [.font: mono, .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1), .backgroundColor: NSColor(calibratedWhite: 0.94, alpha: 1), .paragraphStyle: style])
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func loadImage(_ ref: String, baseURL: URL?) -> CGImage? {
        let url: URL
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") { return nil }   // stay offline
        if ref.hasPrefix("/") { url = URL(fileURLWithPath: ref) }
        else { url = (baseURL ?? URL(fileURLWithPath: ".")).appendingPathComponent(ref.removingPercentEncoding ?? ref) }
        return try? ImageConvert.load(url)
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) via Foundation's parser, styled with AppKit fonts.
    static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let style = NSMutableParagraphStyle(); style.paragraphSpacing = 8; style.lineSpacing = 2
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
        guard let parsed = try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs = baseAttrs
            var f = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { f = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular); attrs[.backgroundColor] = NSColor(calibratedWhite: 0.94, alpha: 1) }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link; attrs[.foregroundColor] = NSColor.systemBlue; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = f
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return result
    }
}

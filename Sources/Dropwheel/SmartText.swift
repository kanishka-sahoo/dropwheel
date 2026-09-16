import AppKit
import Vision
import Speech
import AVFoundation

/// Content-aware conversions: tables, code, HTML, JSON/CSV, OCR and on-device transcription.
enum SmartText {
    // MARK: CSV / tables

    static func parseCSV(_ text: String, url: URL? = nil) -> [[String]] {
        let delimiter: Character = (url?.pathExtension.lowercased() == "tsv" || (!text.contains(",") && text.contains("\t"))) ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy { $0.isEmpty } }
    }

    /// A bordered table with a bold header row.
    static func table(rows: [[String]], title: String?, inlineMarkdown: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let title {
            out.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.black]))
        }
        guard let columns = rows.map({ $0.count }).max(), columns > 0 else { return out }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let font = NSFont.systemFont(ofSize: rows.count > 40 || columns > 8 ? 9 : 11)
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(calibratedWhite: 0.7, alpha: 1))
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                block.backgroundColor = r == 0 ? NSColor(calibratedWhite: 0.92, alpha: 1) : (r % 2 == 0 ? NSColor(calibratedWhite: 0.98, alpha: 1) : .white)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let text = c < row.count ? row[c] : ""
                let cell: NSMutableAttributedString
                if inlineMarkdown { cell = NSMutableAttributedString(attributedString: Markdown.inline(text, font: r == 0 ? bold : font)) }
                else { cell = NSMutableAttributedString(string: text, attributes: [.font: r == 0 ? bold : font, .foregroundColor: NSColor.black]) }
                cell.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return out
    }

    static func attachment(_ cg: CGImage, maxWidth: CGFloat) -> NSAttributedString {
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let att = NSTextAttachment()
        let scale = min(1, maxWidth / CGFloat(cg.width))
        att.image = image
        att.bounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let s = NSMutableAttributedString(attachment: att)
        let style = NSMutableParagraphStyle(); style.paragraphSpacing = 10
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: JSON <-> CSV

    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func json(fromCSV rows: [[String]]) throws -> String {
        guard let header = rows.first else { throw ConvError.failed("The CSV file is empty") }
        let records: [[String: Any]] = rows.dropFirst().map { row in
            var obj: [String: Any] = [:]
            for (i, key) in header.enumerated() {
                let v = i < row.count ? row[i] : ""
                if let n = Int(v) { obj[key] = n } else if let d = Double(v) { obj[key] = d }
                else if v.lowercased() == "true" || v.lowercased() == "false" { obj[key] = v.lowercased() == "true" } else { obj[key] = v }
            }
            return obj
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func csv(fromJSON text: String) throws -> String {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { throw ConvError.failed("Not valid JSON") }
        var records: [[String: Any]] = []
        if let arr = obj as? [[String: Any]] { records = arr }
        else if let dict = obj as? [String: Any], let arr = dict.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] { records = arr }
        else if let arr = obj as? [Any] { records = arr.map { ["value": $0] } }
        else if let dict = obj as? [String: Any] { records = [dict] }
        guard !records.isEmpty else { throw ConvError.unsupported("JSON must contain an array of objects to become CSV") }
        var keys: [String] = []
        for r in records { for k in r.keys where !keys.contains(k) { keys.append(k) } }
        func cell(_ v: Any?) -> String {
            let s: String
            switch v {
            case nil, is NSNull: s = ""
            case let str as String: s = str
            case let n as NSNumber: s = n.stringValue
            default: s = (try? JSONSerialization.data(withJSONObject: v!, options: [])).map { String(decoding: $0, as: UTF8.self) } ?? "\(v!)"
            }
            return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [keys.map { cell($0) }.joined(separator: ",")]
        for r in records { lines.append(keys.map { cell(r[$0]) }.joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: source code

    private static let keywords: Set<String> = ["func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "protocol", "extension", "guard", "switch", "case", "default", "break", "continue", "in", "do", "try", "catch", "throw", "throws", "static", "private", "public", "internal", "final", "override", "init", "self", "super", "nil", "true", "false", "def", "elif", "lambda", "pass", "with", "as", "from", "not", "and", "or", "None", "True", "False", "function", "const", "new", "this", "null", "undefined", "export", "async", "await", "typeof", "instanceof", "interface", "type", "implements", "package", "fn", "pub", "mut", "impl", "trait", "use", "match", "loop", "int", "float", "double", "char", "void", "bool", "string", "select", "where", "insert", "update", "delete", "create", "table", "end", "then", "begin", "local", "require", "module"]

    static func code(_ text: String, language: String, fileName: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: fileName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.darkGray]))
        let mono = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let digits = String(lines.count).count
        let style = NSMutableParagraphStyle()
        style.headIndent = CGFloat(digits + 2) * 6.2
        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        style.defaultTabInterval = 24
        let commentPrefix = ["py", "rb", "sh", "zsh", "bash", "yaml", "yml", "toml", "r", "pl", "conf", "ini"].contains(language) ? "#" : "//"
        for (i, line) in lines.enumerated() {
            let ln = NSMutableAttributedString(string: String(format: "%\(digits)d\t", i + 1), attributes: [.font: mono, .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1), .paragraphStyle: style])
            let body = NSMutableAttributedString(string: line + "\n", attributes: [.font: mono, .foregroundColor: NSColor.black, .paragraphStyle: style])
            highlight(body, line: line, commentPrefix: commentPrefix)
            ln.append(body)
            out.append(ln)
        }
        return out
    }

    private static func highlight(_ s: NSMutableAttributedString, line: String, commentPrefix: String) {
        let ns = line as NSString
        if let r = line.range(of: commentPrefix) {
            let loc = ns.range(of: commentPrefix).location
            _ = r
            s.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.35, alpha: 1), range: NSRange(location: loc, length: ns.length - loc))
            return
        }
        for m in (try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#))?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] {
            s.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0.75, green: 0.2, blue: 0.2, alpha: 1), range: m.range)
        }
        for m in (try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#))?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] where keywords.contains(ns.substring(with: m.range)) {
            s.addAttributes([.foregroundColor: NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.65, alpha: 1), .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)], range: m.range)
        }
    }

    // MARK: HTML

    static func htmlAttributed(_ data: Data, baseURL: URL?) throws -> NSAttributedString {
        var result: NSAttributedString?
        let work = {
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]
            if let baseURL { opts[.baseURL] = baseURL }
            result = try? NSAttributedString(data: data, options: opts, documentAttributes: nil)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        guard let r = result else { throw ConvError.failed("Could not read the HTML document") }
        return r
    }

    /// Standalone HTML for any text document. Markdown is converted structurally; others via AppKit's HTML writer.
    static func html(for url: URL) throws -> String {
        let kind = Formats.kind(of: url)
        let attr = try TextConvert.attributed(url)
        if kind == "html" { return try TextConvert.readText(url) }
        var body: String
        if kind == "code" || kind == "json" {
            let text = kind == "json" ? prettyJSON(try TextConvert.readText(url)) : try TextConvert.readText(url)
            body = "<pre><code>" + escape(text) + "</code></pre>"
        } else if kind == "csv" {
            let rows = parseCSV(try TextConvert.readText(url), url: url)
            var table = "<table>"
            for (i, row) in rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                table += "<tr>"
                for cell in row {
                    table += "<\(tag)>" + escape(cell) + "</\(tag)>"
                }
                table += "</tr>"
            }
            table += "</table>"
            body = table
        } else {
            let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .excludedElements: ["doctype", "html", "head", "body", "meta", "title", "xml"]])
            body = String(decoding: data, as: UTF8.self)
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(Naming.baseName(of: url)))</title>
        <style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:52em;margin:2em auto;padding:0 1em;line-height:1.5;color:#111}pre{background:#f3f3f3;padding:1em;overflow:auto;border-radius:6px}code{font-family:Menlo,monospace;font-size:.92em}table{border-collapse:collapse}th,td{border:1px solid #bbb;padding:4px 8px}th{background:#eee}img{max-width:100%}</style>
        </head><body>
        \(body)
        </body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Approximates Markdown from a styled document (headings by font size, bold/italic, lists, links).
    static func markdown(from attr: NSAttributedString) -> String {
        var out = ""
        let text = attr.string as NSString
        var paraStart = 0
        while paraStart < text.length {
            let paraRange = text.paragraphRange(for: NSRange(location: paraStart, length: 0))
            var line = ""
            var maxSize: CGFloat = 0
            attr.enumerateAttributes(in: paraRange, options: []) { attrs, range, _ in
                var piece = text.substring(with: range).trimmingCharacters(in: .newlines)
                guard !piece.isEmpty else { return }
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
                maxSize = max(maxSize, font.pointSize)
                let traits = font.fontDescriptor.symbolicTraits
                if font.isFixedPitch { piece = "`\(piece)`" }
                if traits.contains(.bold), font.pointSize < 14 { piece = "**\(piece)**" }
                if traits.contains(.italic) { piece = "*\(piece)*" }
                if let link = attrs[.link] { piece = "[\(piece)](\((link as? URL)?.absoluteString ?? "\(link)"))" }
                line += piece
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let level = maxSize >= 22 ? 1 : maxSize >= 17 ? 2 : maxSize >= 14.5 ? 3 : 0
                if level > 0 { out += String(repeating: "#", count: level) + " " + trimmed.replacingOccurrences(of: "**", with: "") + "\n\n" }
                else if trimmed.hasPrefix("•") { out += "- " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces) + "\n" }
                else { out += trimmed + "\n\n" }
            }
            paraStart = NSMaxRange(paraRange)
            if paraRange.length == 0 { break }
        }
        return out
    }

    // MARK: OCR

    /// Recognized text lines from an image, top to bottom.
    static func recognizeText(_ cg: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let obs = (request.results ?? []).sorted { a, b in
            let dy = a.boundingBox.midY - b.boundingBox.midY
            return abs(dy) > 0.01 ? dy > 0 : a.boundingBox.minX < b.boundingBox.minX
        }
        var lines: [String] = []
        var lastY: CGFloat = 2
        for o in obs {
            guard let s = o.topCandidates(1).first?.string else { continue }
            if lastY - o.boundingBox.midY > o.boundingBox.height * 1.8 { lines.append("") }  // paragraph gap
            lines.append(s)
            lastY = o.boundingBox.midY
        }
        return lines.joined(separator: "\n")
    }

    static func ocr(_ url: URL, job: Job?) throws -> URL {
        let text = try recognizeText(try ImageConvert.load(url))
        let out = Naming.output(beside: url, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: transcription (on-device)

    static func transcribe(_ url: URL, to target: String, job: Job?) throws -> URL {
        let sem = DispatchSemaphore(value: 0)
        var auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { s in auth = s; sem.signal() }
            sem.wait()
        }
        guard auth == .authorized else { throw ConvError.failed("Speech recognition is not allowed. Enable Dropwheel in System Settings → Privacy & Security → Speech Recognition.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw ConvError.failed("Speech recognition is not available for this language on this Mac.")
        }
        let info = try Shell.probe(url)
        guard info.hasAudio else { throw ConvError.failed("\(url.lastPathComponent) has no audio track") }
        job?.progress = 0.05
        // Decode to WAV so any container/codec works.
        let wav = Naming.tempFile(ext: "wav")
        try Shell.ffmpeg(["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path])
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = SFSpeechURLRecognitionRequest(url: wav)
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        var segments: [SFTranscriptionSegment] = []
        var finalError: Error?
        let done = DispatchSemaphore(value: 0)
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                segments = result.bestTranscription.segments
                if let last = segments.last, info.duration > 0 { job?.progress = min(0.95, (last.timestamp + last.duration) / info.duration) }
                if result.isFinal { done.signal() }
            }
            if let error { finalError = error; done.signal() }
        }
        job?.process = nil
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if job?.isCancelled == true { task.cancel(); throw ConvError.cancelled }
        }
        if let finalError, segments.isEmpty { throw ConvError.failed("Transcription failed: \(finalError.localizedDescription)") }
        guard !segments.isEmpty else { throw ConvError.failed("No speech was recognized in \(url.lastPathComponent)") }

        let out = Naming.output(beside: url, ext: target)
        if target == "txt" {
            try segments.map { $0.substring }.joined(separator: " ").write(to: out, atomically: true, encoding: .utf8)
        } else {
            let cues = cues(from: segments)
            try (target == "srt" ? Subtitles.srt(cues) : Subtitles.vtt(cues)).write(to: out, atomically: true, encoding: .utf8)
        }
        return out
    }

    /// Groups word segments into subtitle cues of a few seconds each.
    private static func cues(from segments: [SFTranscriptionSegment]) -> [Subtitles.Cue] {
        var cues: [Subtitles.Cue] = []
        var words: [String] = []
        var start = segments.first?.timestamp ?? 0
        var end = start
        for s in segments {
            if !words.isEmpty, (s.timestamp - start > 5 || words.count >= 12 || s.timestamp - end > 1.2) {
                cues.append(.init(start: start, end: max(end, start + 0.5), text: words.joined(separator: " ")))
                words = []
                start = s.timestamp
            }
            words.append(s.substring)
            end = s.timestamp + s.duration
        }
        if !words.isEmpty { cues.append(.init(start: start, end: max(end, start + 0.5), text: words.joined(separator: " "))) }
        return cues
    }
}

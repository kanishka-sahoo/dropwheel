import AppKit
import PDFKit
import Quartz

enum PDFConvert {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConvError.failed("Could not open \(url.lastPathComponent)") }
        if doc.isLocked { throw ConvError.failed("\(url.lastPathComponent) is password protected") }
        return doc
    }

    /// Renders a page to a bitmap at the given DPI.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // Apply the page rotation the same way PDFKit's thumbnails do.
        let rotation = page.rotation
        ctx.translateBy(x: bounds.width / 2, y: bounds.height / 2)
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        if rotation % 180 == 0 {
            ctx.translateBy(x: -bounds.width / 2, y: -bounds.height / 2)
        } else {
            ctx.translateBy(x: -bounds.height / 2, y: -bounds.width / 2)
        }
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Rotated size of a page, as displayed.
    static func displayBounds(_ page: PDFPage) -> CGRect {
        let b = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? b : CGRect(x: 0, y: 0, width: b.height, height: b.width)
    }

    static func convert(_ url: URL, to target: String, job: Job?) throws -> [URL] {
        let doc = try open(url)
        switch target {
        case "txt":
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                try job?.checkCancelled()
                job?.progress = Double(i) / Double(doc.pageCount)
                pages.append(try textOrOCR(page))
            }
            let text = pages.joined(separator: "\n\n")
            let out = Naming.output(beside: url, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case "jpg", "png":
            return try pagesToImages(doc, source: url, kind: target, job: job)
        case "docx":
            var blocks: [Docx.Block] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                try job?.checkCancelled()
                job?.progress = Double(i) / Double(doc.pageCount)
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    if let cg = render(page, dpi: 150) {
                        blocks.append(.image(cg, kind: "jpg"))
                        // Scanned page: add the recognized text below the image so it is searchable and editable.
                        if let ocr = try? SmartText.recognizeText(cg), !ocr.isEmpty {
                            for para in ocr.components(separatedBy: "\n") { blocks.append(.paragraph(para)) }
                        }
                    }
                } else {
                    for para in text.components(separatedBy: "\n") { blocks.append(.paragraph(para)) }
                }
                if i < doc.pageCount - 1 { blocks.append(.pageBreak) }
            }
            let out = Naming.output(beside: url, ext: "docx")
            try Docx.write(blocks, to: out)
            return [out]
        default:
            throw ConvError.unsupported("PDF cannot be converted to \(target)")
        }
    }

    /// The page's text layer, or OCR of the rendered page when there is none.
    static func textOrOCR(_ page: PDFPage) throws -> String {
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        guard let cg = render(page, dpi: 200) else { return "" }
        return try SmartText.recognizeText(cg)
    }

    static func pagesToImages(_ doc: PDFDocument, source: URL, kind: String, job: Job?, dpi: CGFloat = 300) throws -> [URL] {
        let ext = Formats.fileExtension(for: kind)
        if doc.pageCount == 1 {
            guard let page = doc.page(at: 0), let cg = render(page, dpi: dpi) else { throw ConvError.failed("Could not render page") }
            let out = Naming.output(beside: source, ext: ext)
            try ImageConvert.write(cg, to: out, kind: kind, quality: 0.92)
            return [out]
        }
        let folder = try Naming.folder(beside: source, suffix: "Pages")
        let base = Naming.baseName(of: source)
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            try job?.checkCancelled()
            job?.progress = Double(i) / Double(doc.pageCount)
            guard let page = doc.page(at: i), let cg = render(page, dpi: dpi) else { continue }
            let out = folder.appendingPathComponent(String(format: "%@-%0*d.%@", base, digits(doc.pageCount), i + 1, ext))
            try ImageConvert.write(cg, to: out, kind: kind, quality: 0.92)
            outputs.append(out)
        }
        return [folder]
    }

    private static func digits(_ n: Int) -> Int { max(1, String(n).count) }

    static func imagesToPDF(_ urls: [URL], output: URL) throws {
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else { throw ConvError.failed("Cannot create PDF") }
        for url in urls {
            let cg = try ImageConvert.load(url)
            var box = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
            // Scale huge images down to a sensible page size (points) while keeping full pixels.
            let scale = min(1, 1600 / max(box.width, box.height))
            box.size = CGSize(width: box.width * scale, height: box.height * scale)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(cg, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    static func split(_ url: URL, job: Job?) throws -> URL {
        let doc = try open(url)
        let folder = try Naming.folder(beside: url, suffix: "Pages")
        let base = Naming.baseName(of: url)
        for i in 0..<doc.pageCount {
            try job?.checkCancelled()
            job?.progress = Double(i) / Double(doc.pageCount)
            guard let page = doc.page(at: i) else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent(String(format: "%@-%0*d.pdf", base, digits(doc.pageCount), i + 1)))
        }
        return folder
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { merged.insert(p, at: merged.pageCount) } }
        }
        let out = Naming.output(beside: urls[0], suffix: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConvError.failed("Could not write merged PDF") }
        return out
    }

    /// Applies the system "Reduce File Size" Quartz filter. Falls back to re-rendering pages as JPEG.
    static func compress(_ url: URL, job: Job?) throws -> URL {
        let doc = try open(url)
        let out = Naming.output(beside: url, suffix: "Compressed", ext: "pdf")
        let strong = Settings.compression == .strong
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        if !strong, let filter = QuartzFilter(url: filterURL), let ctx = CGContext(out as CFURL, mediaBox: nil, nil) {
            filter.apply(to: ctx)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var box = page.bounds(for: .mediaBox)
                ctx.beginPage(mediaBox: &box)
                page.draw(with: .mediaBox, to: ctx)
                ctx.endPage()
            }
            ctx.closePDF()
            let inSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let outSize = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if outSize > 0, outSize < inSize { return out }
            try? FileManager.default.removeItem(at: out)
        }
        // Strong: rasterize every page to JPEG at 110 DPI.
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ConvError.failed("Cannot create PDF") }
        for i in 0..<doc.pageCount {
            try job?.checkCancelled()
            job?.progress = Double(i) / Double(doc.pageCount)
            guard let page = doc.page(at: i), let cg = render(page, dpi: strong ? 100 : 144) else { continue }
            let tmp = Naming.tempFile(ext: "jpg")
            try ImageConvert.writeImageIO(cg, to: tmp, type: .jpeg, quality: strong ? 0.5 : 0.7, metadata: nil)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let jpg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            var box = displayBounds(page)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(jpg, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = Naming.output(beside: url, suffix: "No Metadata", ext: "pdf")
        guard doc.write(to: out) else { throw ConvError.failed("Could not write PDF") }
        return out
    }
}

import AppKit

/// Minimal Office Open XML writer: paragraphs of text and full-width images.
enum Docx {
    enum Block {
        case paragraph(String)
        case image(CGImage, kind: String)   // kind: jpg | png
        case pageBreak
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .filter { $0.asciiValue.map { $0 >= 32 || $0 == 9 } ?? true }
    }

    static func write(_ blocks: [Block], to url: URL) throws {
        let dir = try Naming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        var body = ""
        var rels = ""
        var mediaTypes = Set<String>()
        var imageIndex = 0
        let usableWidthEMU = 6.5 * 914400.0

        for block in blocks {
            switch block {
            case .paragraph(let text):
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case .image(let cg, let kind):
                imageIndex += 1
                let ext = kind == "jpg" ? "jpeg" : "png"
                mediaTypes.insert(ext)
                let name = "image\(imageIndex).\(ext)"
                try ImageConvert.writeImageIO(cg, to: dir.appendingPathComponent("word/media/\(name)"), type: kind == "jpg" ? .jpeg : .png, quality: 0.9, metadata: nil)
                let rid = "rId\(imageIndex + 10)"
                rels += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                var cx = Double(cg.width) * 9525, cy = Double(cg.height) * 9525
                if cx > usableWidthEMU { cy *= usableWidthEMU / cx; cx = usableWidthEMU }
                let maxH = 9.0 * 914400
                if cy > maxH { cx *= maxH / cy; cy = maxH }
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(Int(cx))" cy="\(Int(cy))"/><wp:docPr id="\(imageIndex)" name="Picture \(imageIndex)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(imageIndex)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(Int(cx))" cy="\(Int(cy))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(mediaTypes.map { "<Default Extension=\"\($0)\" ContentType=\"image/\($0)\"/>" }.joined())<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
        try contentTypes.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try document.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try docRels.write(to: dir.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)

        let zipTmp = Naming.tempFile(ext: "zip")
        let r = try Shell.run("/bin/sh", ["-c", "cd \"$0\" && \"$1\" -X -q -r \"$2\" '[Content_Types].xml' _rels word", dir.path, Binaries.zip, zipTmp.path])
        if r.status != 0 { throw ConvError.failed("Could not package DOCX: \(r.stderr)") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: zipTmp, to: url)
    }

    /// Reads the text of a DOCX (or any rich text file AppKit understands).
    static func readAttributed(_ url: URL) throws -> NSAttributedString {
        let kind = Formats.kind(of: url)
        let type: NSAttributedString.DocumentType = kind == "docx" ? .officeOpenXML : .plain
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw ConvError.failed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

import AppKit

/// Routes a wheel selection to conversions, batch jobs or editor windows.
enum Actions {
    static func perform(files: [URL], itemID: String, advanced: Bool) {
        if !advanced {
            for file in files {
                JobCenter.shared.run(title: "Converting to \(Formats.displayName(itemID))", fileName: file.lastPathComponent) { job in
                    try convert(files: [file], target: itemID, job: job)
                }
            }
            return
        }
        guard let tool = Tool(rawValue: itemID) else { return }
        if Formats.audio.contains(Formats.kind(of: files[0])) || Formats.video.contains(Formats.kind(of: files[0])) {
            if Binaries.ffmpeg == nil, tool != .removeMetadata || Formats.kind(of: files[0]) != "gif" {
                showError(ConvError.missingTool("ffmpeg"))
                return
            }
        }
        switch tool {
        case .compress, .normalizeAudio, .muteVideo, .splitPDF, .extractArchive:
            for file in files {
                JobCenter.shared.run(title: batchTitle(tool), fileName: file.lastPathComponent) { job in
                    try runHeadless(tool: tool, files: [file], job: job)
                }
            }
        case .createPDF, .mergePDF:
            JobCenter.shared.run(title: tool == .createPDF ? "Creating PDF" : "Merging PDFs", fileName: "\(files.count) files") { job in
                try runHeadless(tool: tool, files: files, job: job)
            }
        case .audioChannels: ChannelsWindow(files: files).show()
        case .annotateImage: AnnotateWindow(files: files).show()
        case .joinVideos: JoinWindow(files: files).show()
        case .changeVideoSpeed: SpeedWindow(files: files).show()
        case .audioToVideo: VisualizerWindow(files: files).show()
        case .createCollage: CollageWindow(files: files).show()
        case .editImage: EditImageWindow(files: files).show()
        case .frameImage: FrameImageWindow(files: files).show()
        case .cropImage: CropWindow(files: files, isVideo: false).show()
        case .cropVideo: CropWindow(files: files, isVideo: true).show()
        case .redactImage: RedactWindow(files: files, isVideo: false).show()
        case .redactVideo: RedactWindow(files: files, isVideo: true).show()
        case .trimAudio, .trimVideo: TrimWindow(files: files).show()
        case .splitVideo: SplitVideoWindow(files: files).show()
        case .videoSnapshots: SnapshotsWindow(files: files).show()
        case .redactAudio: BleepWindow(files: files).show()
        case .organizePDF: OrganizePDFWindow(files: files).show()
        case .removeMetadata: MetadataWindow(files: files).show()
        }
    }

    private static func batchTitle(_ tool: Tool) -> String {
        switch tool {
        case .compress: return "Compressing"
        case .normalizeAudio: return "Normalizing volume"
        case .muteVideo: return "Removing audio"
        case .splitPDF: return "Splitting PDF"
        case .extractArchive: return "Extracting"
        default: return tool.name
        }
    }

    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Dropwheel"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Converts one file to `target`. Returns the produced files/folders.
    static func convert(files: [URL], target: String, job: Job?) throws -> [URL] {
        var outputs: [URL] = []
        for url in files {
            let kind = Formats.kind(of: url)
            guard Formats.targets(for: kind).contains(target) else {
                throw ConvError.unsupported("\(url.lastPathComponent) cannot be converted to \(Formats.displayName(target))")
            }
            switch Formats.category(of: kind) {
            case .image where target == "txt": outputs.append(try SmartText.ocr(url, job: job))
            case .image: outputs.append(try ImageConvert.convert(url, to: target, job: job))
            case .audio, .video:
                if ["txt", "srt", "vtt"].contains(target) { outputs.append(try SmartText.transcribe(url, to: target, job: job)) }
                else { outputs.append(try MediaConvert.convert(url, to: target, job: job)) }
            case .document where kind == "pdf": outputs += try PDFConvert.convert(url, to: target, job: job)
            case .document, .subtitle: outputs.append(try TextConvert.convert(url, to: target, job: job))
            case .archive: outputs.append(try ArchiveConvert.convert(url, to: target, job: job))
            case .none: throw ConvError.unsupported("Unsupported file \(url.lastPathComponent)")
            }
        }
        return outputs
    }

    /// Runs a tool with default parameters (batch tools, and defaults for editors when used from the CLI).
    static func runHeadless(tool: Tool, files: [URL], job: Job?) throws -> [URL] {
        guard let first = files.first else { return [] }
        let kind = Formats.kind(of: first)
        let cat = Formats.category(of: kind)
        switch tool {
        case .compress:
            switch cat {
            case .image: return [try ImageConvert.compress(first)]
            case .audio, .video: return [try MediaConvert.compress(first, job: job)]
            case .document: return [try PDFConvert.compress(first, job: job)]
            default: throw ConvError.unsupported("Cannot compress \(first.lastPathComponent)")
            }
        case .removeMetadata:
            switch cat {
            case .image: return [try ImageConvert.stripMetadata(first)]
            case .audio, .video: return [try MediaConvert.stripMetadata(first, job: job)]
            case .document: return [try PDFConvert.stripMetadata(first)]
            default: throw ConvError.unsupported("No metadata support for \(first.lastPathComponent)")
            }
        case .normalizeAudio: return [try MediaConvert.normalize(first, job: job)]
        case .muteVideo: return [try MediaConvert.mute(first, job: job)]
        case .splitPDF: return [try PDFConvert.split(first, job: job)]
        case .extractArchive: return [try ArchiveConvert.extract(first, job: job)]
        case .createPDF:
            let out = Naming.output(beside: first, suffix: files.count > 1 ? "and \(files.count - 1) more" : nil, ext: "pdf")
            try PDFConvert.imagesToPDF(files, output: out)
            return [out]
        case .mergePDF: return [try PDFConvert.merge(files)]
        case .joinVideos: return [try MediaConvert.join(files, job: job)]
        case .audioChannels: return [try MediaConvert.channels(first, mode: .mono, job: job)]
        case .annotateImage:
            let cg = try ImageConvert.load(first)
            let shape = Annotate.Shape(kind: .arrow, from: CGPoint(x: cg.width / 5, y: cg.height / 5), to: CGPoint(x: cg.width / 2, y: cg.height / 2), color: .systemRed, width: 8, text: "")
            return [try Annotate.save(first, shapes: [shape])]
        case .changeVideoSpeed: return [try MediaConvert.speed(first, factor: 2, job: job)]
        case .audioToVideo: return [try MediaConvert.visualize(first, shape: .landscape, color: NSColor(calibratedRed: 0.12, green: 0.83, blue: 0.72, alpha: 1), image: nil, job: job)]
        case .createCollage: return [try Collage.render(files, options: Collage.Options(), output: Naming.output(beside: first, suffix: "Collage", ext: "png"))]
        case .trimAudio, .trimVideo:
            let d = try Shell.probe(first).duration
            return [try MediaConvert.trim(first, start: d * 0.25, end: d * 0.75, job: job)]
        case .splitVideo:
            let d = try Shell.probe(first).duration
            return [try MediaConvert.split(first, at: [d / 2], job: job)]
        case .videoSnapshots:
            let d = try Shell.probe(first).duration
            return try MediaConvert.snapshots(first, times: [0, d / 2], job: job)
        case .cropImage:
            let cg = try ImageConvert.load(first)
            let r = CGRect(x: cg.width / 4, y: cg.height / 4, width: cg.width / 2, height: cg.height / 2)
            return [try ImageTools.crop(first, rect: r)]
        case .cropVideo:
            let info = try Shell.probe(first)
            return [try MediaConvert.crop(first, rect: CGRect(x: info.width / 4, y: info.height / 4, width: info.width / 2, height: info.height / 2), job: job)]
        case .redactImage:
            let cg = try ImageConvert.load(first)
            return [try ImageTools.redact(first, rects: [CGRect(x: cg.width / 4, y: cg.height / 4, width: cg.width / 2, height: cg.height / 4)], style: .pixelate)]
        case .redactVideo:
            let info = try Shell.probe(first)
            return [try MediaConvert.redact(first, redactions: [.init(rect: CGRect(x: info.width / 4, y: info.height / 4, width: info.width / 2, height: info.height / 4), start: 0.5, end: nil)], style: .blur, job: job)]
        case .redactAudio: return [try MediaConvert.bleep(first, ranges: [(0.5, 1.5)], job: job)]
        case .editImage: return [try ImageTools.edit(first, adjustments: ImageTools.Adjustments(contrast: 1.2, saturation: 1.2))]
        case .frameImage: return [try ImageTools.frame(first, options: ImageTools.FrameOptions())]
        case .organizePDF:
            let doc = try PDFConvert.open(first)
            return [try PDFTools.organize(doc, order: Array((0..<doc.pageCount).reversed()), rotations: [:], source: first)]
        }
    }
}

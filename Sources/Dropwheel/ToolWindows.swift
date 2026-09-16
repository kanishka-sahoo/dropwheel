import AppKit
import AVFoundation
import PDFKit
import CoreImage

// MARK: - Image editors

final class EditImageWindow: ToolWindow {
    private var adjustments = ImageTools.Adjustments()
    private let canvas = ImageCanvasView()
    private var source: CIImage?
    private var previewSource: CIImage?
    private var renderPending = false

    init(files: [URL]) {
        super.init(title: "Edit Photo", files: files)
        setPreview(canvas)
        addHeading("Light")
        addSlider("Exposure", min: -2, max: 2, value: 0) { [weak self] v in self?.adjustments.exposure = v; self?.render() }
        addSlider("Brightness", min: -0.5, max: 0.5, value: 0) { [weak self] v in self?.adjustments.brightness = v; self?.render() }
        addSlider("Contrast", min: 0.5, max: 1.5, value: 1) { [weak self] v in self?.adjustments.contrast = v; self?.render() }
        addSlider("Highlights", min: 0.3, max: 1, value: 1) { [weak self] v in self?.adjustments.highlights = v; self?.render() }
        addSlider("Shadows", min: -1, max: 1, value: 0) { [weak self] v in self?.adjustments.shadows = v; self?.render() }
        addHeading("Color")
        addSlider("Saturation", min: 0, max: 2, value: 1) { [weak self] v in self?.adjustments.saturation = v; self?.render() }
        addSlider("Warmth", min: -100, max: 100, value: 0, format: { String(format: "%.0f", $0) }) { [weak self] v in self?.adjustments.temperature = v; self?.render() }
        addHeading("Detail")
        addSlider("Sharpness", min: 0, max: 2, value: 0) { [weak self] v in self?.adjustments.sharpness = v; self?.render() }
        addSlider("Clarity", min: 0, max: 1, value: 0) { [weak self] v in self?.adjustments.clarity = v; self?.render() }
        addSlider("Dehaze", min: 0, max: 1, value: 0) { [weak self] v in self?.adjustments.dehaze = v; self?.render() }
        addSlider("Noise reduction", min: 0, max: 1, value: 0) { [weak self] v in self?.adjustments.noiseReduction = v; self?.render() }
        addSlider("Grain", min: 0, max: 1, value: 0) { [weak self] v in self?.adjustments.grain = v; self?.render() }
        addSlider("Vignette", min: 0, max: 2, value: 0) { [weak self] v in self?.adjustments.vignette = v; self?.render() }
        addHeading("Effect")
        addPopup("Filter", items: ImageTools.effects.map { $0.0 }) { [weak self] i in self?.adjustments.effect = ImageTools.effects[i].1; self?.render() }
        addSeparator()
        addNote("Adjustments are applied at full resolution when you save. The original is left untouched.")
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        setStatus("Loading…")
        DispatchQueue.global().async { [weak self] in
            guard let self, let cg = try? ImageConvert.load(self.files[0]) else { return }
            let ci = CIImage(cgImage: cg)
            let scale = min(1, 1600 / max(ci.extent.width, ci.extent.height))
            let preview = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
            DispatchQueue.main.async {
                self.source = ci
                self.previewSource = ImageConvert.render(preview).map { CIImage(cgImage: $0) }
                self.setStatus("\(cg.width) × \(cg.height)")
                self.render()
            }
        }
    }

    private func render() {
        guard let previewSource, !renderPending else { return }
        renderPending = true
        let adj = adjustments
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let cg = ImageConvert.render(ImageTools.apply(previewSource, adj))
            DispatchQueue.main.async {
                self?.canvas.image = cg
                self?.renderPending = false
            }
        }
    }

    override func performSave() -> Bool {
        let adj = adjustments, url = files[0]
        runJob(title: "Editing photo") { _ in [try ImageTools.edit(url, adjustments: adj)] }
        return true
    }
}

final class FrameImageWindow: ToolWindow {
    private var options = ImageTools.FrameOptions()
    private let canvas = ImageCanvasView()
    private var preview: CGImage?
    private var colorA = NSColor.white, colorB = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1, alpha: 1)
    private var bgImage: URL?
    private var kind = 0
    private static let aspects: [(String, CGFloat?)] = [("Original", nil), ("Square 1:1", 1), ("Portrait 4:5", 0.8), ("Landscape 3:2", 1.5), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0)]

    init(files: [URL]) {
        super.init(title: "Add Background", files: files)
        setPreview(canvas)
        addHeading("Background")
        addPopup("Type", items: ["Solid color", "Gradient", "Image"]) { [weak self] i in self?.kind = i; self?.rebuild() }
        addColorWell("Color", color: colorA) { [weak self] c in self?.colorA = c; self?.rebuild() }
        addColorWell("Second color", color: colorB) { [weak self] c in self?.colorB = c; self?.rebuild() }
        addButton("Choose Image…", symbol: "photo") { [weak self] in
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            if p.runModal() == .OK { self?.bgImage = p.url; self?.kind = 2; self?.rebuild() }
        }
        addHeading("Layout")
        addPopup("Aspect ratio", items: Self.aspects.map { $0.0 }) { [weak self] i in self?.options.aspect = Self.aspects[i].1; self?.rebuild() }
        addSlider("Spacing", min: 0, max: 0.4, value: 0.08, format: { String(format: "%.0f%%", $0 * 100) }) { [weak self] v in self?.options.padding = v; self?.rebuild() }
        addSlider("Corner radius", min: 0, max: 0.3, value: 0.04, format: { String(format: "%.0f%%", $0 * 100) }) { [weak self] v in self?.options.radius = v; self?.rebuild() }
        DispatchQueue.global().async { [weak self] in
            guard let self, let cg = try? ImageConvert.load(self.files[0]) else { return }
            let small = ImageConvert.resized(cg, maxDimension: 1200)
            DispatchQueue.main.async { self.preview = small; self.rebuild() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func currentOptions() -> ImageTools.FrameOptions {
        var o = options
        switch kind {
        case 1: o.background = .gradient(colorA, colorB)
        case 2: o.background = bgImage.map { .image($0) } ?? .solid(colorA)
        default: o.background = .solid(colorA)
        }
        return o
    }

    private func rebuild() {
        guard let preview else { return }
        let o = currentOptions()
        DispatchQueue.global().async { [weak self] in
            let img = try? ImageTools.framed(preview, options: o)
            DispatchQueue.main.async { self?.canvas.image = img }
        }
    }

    override func performSave() -> Bool {
        let o = currentOptions(), url = files[0]
        runJob(title: "Adding background") { _ in [try ImageTools.frame(url, options: o)] }
        return true
    }
}

final class CropWindow: ToolWindow {
    private let editor = RectEditorView()
    private let isVideo: Bool
    private var wField: NSTextField!, hField: NSTextField!
    private static let aspects: [(String, CGFloat?)] = [("Free", nil), ("Original", -1), ("Square 1:1", 1), ("4:5", 0.8), ("3:2", 1.5), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0)]

    init(files: [URL], isVideo: Bool) {
        self.isVideo = isVideo
        super.init(title: isVideo ? "Crop Video" : "Crop Image", files: files)
        editor.mode = .single
        setPreview(editor)
        addHeading("Crop")
        addPopup("Aspect ratio", items: Self.aspects.map { $0.0 }) { [weak self] i in
            guard let self else { return }
            let a = Self.aspects[i].1
            self.editor.aspect = a == -1 ? self.editor.imageSize.width / self.editor.imageSize.height : a
            self.editor.resetSingle()
        }
        wField = addField("Width (px)", value: "") { [weak self] v in self?.setSize(w: Int(v)) }
        hField = addField("Height (px)", value: "") { [weak self] v in self?.setSize(h: Int(v)) }
        addButton("Reset", symbol: "arrow.counterclockwise") { [weak self] in self?.editor.resetSingle() }
        addNote(isVideo ? "Drag the box or its handles. The original audio is kept." : "Drag the box or its handles, or enter exact pixel dimensions. The copy is saved at full resolution.")
        editor.onChange = { [weak self] in
            guard let r = self?.editor.rects.first else { return }
            self?.wField.stringValue = "\(Int(r.width))"
            self?.hField.stringValue = "\(Int(r.height))"
            self?.setStatus("\(Int(r.width)) × \(Int(r.height)) at \(Int(r.minX)), \(Int(r.minY))")
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let cg = try? (isVideo ? MediaConvert.frame(self.files[0]) : ImageConvert.load(self.files[0]))
            DispatchQueue.main.async {
                self.editor.image = cg
                self.editor.resetSingle()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setSize(w: Int? = nil, h: Int? = nil) {
        guard var r = editor.rects.first else { return }
        if let w { r.size.width = CGFloat(max(8, w)); if let a = editor.aspect { r.size.height = r.width / a } }
        if let h { r.size.height = CGFloat(max(8, h)); if let a = editor.aspect { r.size.width = r.height * a } }
        r.size.width = min(r.width, editor.imageSize.width); r.size.height = min(r.height, editor.imageSize.height)
        editor.rects = [r]
    }

    override func performSave() -> Bool {
        guard let rect = editor.rects.first else { return false }
        let url = files[0], video = isVideo
        runJob(title: video ? "Cropping video" : "Cropping image") { job in
            [video ? try MediaConvert.crop(url, rect: rect.integral, job: job) : try ImageTools.crop(url, rect: rect.integral)]
        }
        return true
    }
}

final class RedactWindow: ToolWindow {
    private let editor = RectEditorView()
    private let isVideo: Bool
    private var style = MediaConvert.RedactStyle.solid
    private var ranges: [Int: (Double?, Double?)] = [:]   // rect index -> (start, end)
    private var startField: NSTextField?
    private var endField: NSTextField?
    private var duration: Double = 0

    init(files: [URL], isVideo: Bool) {
        self.isVideo = isVideo
        super.init(title: isVideo ? "Redact Video" : "Redact Photo", files: files)
        editor.mode = .multiple
        setPreview(editor)
        addHeading("Redaction")
        addPopup("Style", items: ["Solid block", "Blur", "Pixelate"]) { [weak self] i in self?.style = .init(rawValue: i) ?? .solid }
        addButton("Remove Selected", symbol: "minus.circle") { [weak self] in
            if let s = self?.editor.selectedIndex { self?.editor.rects.remove(at: s); self?.editor.selectedIndex = nil }
        }
        addButton("Clear All", symbol: "trash") { [weak self] in self?.editor.rects = []; self?.editor.selectedIndex = nil; self?.ranges = [:] }
        if isVideo {
            addHeading("Time range for selected redaction")
            startField = addField("From (s)", value: "") { [weak self] v in self?.setRange(start: v) }
            endField = addField("To (s)", value: "") { [weak self] v in self?.setRange(end: v) }
            addButton("Whole Video", symbol: "arrow.left.and.right") { [weak self] in
                guard let self, let i = self.editor.selectedIndex else { return }
                self.ranges[i] = nil; self.startField?.stringValue = ""; self.endField?.stringValue = ""
            }
        }
        addNote("Drag on the image to add a redaction. Click one to select it, drag its handles to resize, or press Delete to remove it." + (isVideo ? " Leave the time range empty to hide the area for the whole video." : ""))
        editor.onChange = { [weak self] in
            guard let self else { return }
            self.setStatus("\(self.editor.rects.count) redaction(s)")
            if let i = self.editor.selectedIndex, let r = self.ranges[i] {
                self.startField?.stringValue = r.0.map { String(format: "%.2f", $0) } ?? ""
                self.endField?.stringValue = r.1.map { String(format: "%.2f", $0) } ?? ""
            } else { self.startField?.stringValue = ""; self.endField?.stringValue = "" }
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let cg = try? (isVideo ? MediaConvert.frame(self.files[0]) : ImageConvert.load(self.files[0]))
            let d = isVideo ? ((try? Shell.probe(self.files[0]))?.duration ?? 0) : 0
            DispatchQueue.main.async { self.editor.image = cg; self.duration = d; if d > 0 { self.setStatus("Duration \(timeString(d))") } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setRange(start: String? = nil, end: String? = nil) {
        guard let i = editor.selectedIndex else { setStatus("Select a redaction first"); return }
        var r = ranges[i] ?? (nil, nil)
        if let start { r.0 = Double(start) }
        if let end { r.1 = Double(end) }
        ranges[i] = (r.0 == nil && r.1 == nil) ? nil : r
    }

    override func performSave() -> Bool {
        let rects = editor.rects.map { $0.integral }
        guard !rects.isEmpty else { setStatus("Add at least one redaction"); return false }
        let url = files[0], video = isVideo, style = style
        let redactions = rects.enumerated().map { i, r in MediaConvert.Redaction(rect: r, start: ranges[i]?.0, end: ranges[i]?.1) }
        runJob(title: video ? "Redacting video" : "Redacting photo") { job in
            [video ? try MediaConvert.redact(url, redactions: redactions, style: style, job: job) : try ImageTools.redact(url, rects: rects, style: style)]
        }
        return true
    }
}

// MARK: - Timeline editors (trim, split, snapshots, bleep)

/// Shared plumbing: preview player (video or audio), waveform timeline and transport buttons.
class TimelineWindow: ToolWindow {
    let player = Player()
    let timeline = WaveformView()
    let timeLabel = NSTextField(labelWithString: "00:00.00")
    var duration: Double = 0
    var info: Shell.MediaInfo?
    private var previewTemp: URL?
    let isVideo: Bool

    init(title: String, files: [URL]) {
        isVideo = Formats.video.contains(Formats.kind(of: files[0]))
        super.init(title: title, files: files)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        if isVideo { stack.addArrangedSubview(player.view) } else {
            let art = NSImageView(image: NSWorkspace.shared.icon(forFile: files[0].path))
            art.imageScaling = .scaleProportionallyUpOrDown
            art.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(art)
        }
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.heightAnchor.constraint(equalToConstant: 110).isActive = true
        stack.addArrangedSubview(timeline)
        stack.arrangedSubviews[0].widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        timeline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setPreview(stack)

        let transport = NSStackView()
        transport.orientation = .horizontal
        transport.spacing = 6
        func tb(_ symbol: String, _ tip: String, _ handler: @escaping () -> Void) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            let box = ActionBox(handler); b.target = box; b.action = #selector(ActionBox.fire)
            objc_setAssociatedObject(b, "box", box, .OBJC_ASSOCIATION_RETAIN)
            return b
        }
        transport.addArrangedSubview(tb("backward.frame", "Previous frame") { [weak self] in self?.player.step(-1) })
        transport.addArrangedSubview(tb("playpause.fill", "Play / Pause") { [weak self] in self?.player.toggle() })
        transport.addArrangedSubview(tb("forward.frame", "Next frame") { [weak self] in self?.player.step(1) })
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        transport.addArrangedSubview(timeLabel)
        addView(transport)
        player.onTime = { [weak self] t in
            self?.timeline.playhead = t
            self?.timeLabel.stringValue = timeString(t)
            self?.playheadMoved(t)
        }
        timeline.onSeek = { [weak self] t in self?.player.seek(t) }
        loadMedia()
    }
    required init?(coder: NSCoder) { fatalError() }

    func playheadMoved(_ t: Double) {}
    func mediaLoaded() {}

    private func loadMedia() {
        setStatus("Preparing preview…")
        let url = files[0]
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let info = try? Shell.probe(url)
            let preview = try? MediaConvert.previewURL(url, job: nil)
            let peaks = MediaConvert.waveform(url, buckets: 400)
            DispatchQueue.main.async {
                self.info = info
                self.duration = info?.duration ?? 0
                self.timeline.duration = max(0.01, self.duration)
                self.timeline.peaks = peaks
                if let preview { self.player.load(preview); if preview != url { self.previewTemp = preview } }
                self.setStatus(info.map { "\(timeString($0.duration))" + ($0.hasVideo ? " · \($0.width)×\($0.height)" : "") } ?? "")
                self.mediaLoaded()
            }
        }
    }

    override func cleanup() {
        player.stop()
        if let previewTemp { try? FileManager.default.removeItem(at: previewTemp) }
    }
}

final class TrimWindow: TimelineWindow {
    private let startLabel = NSTextField(labelWithString: "Start: 00:00.00")
    private let endLabel = NSTextField(labelWithString: "End: 00:00.00")

    init(files: [URL]) {
        super.init(title: Formats.video.contains(Formats.kind(of: files[0])) ? "Trim Video" : "Trim Audio", files: files)
        timeline.mode = .range
        addHeading("Range")
        startLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        endLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        addView(startLabel); addView(endLabel)
        addButton("Set Start to Playhead", symbol: "arrow.right.to.line") { [weak self] in
            guard let self else { return }; self.timeline.range = (self.timeline.playhead, max(self.timeline.range.1, self.timeline.playhead + 0.1))
        }
        addButton("Set End to Playhead", symbol: "arrow.left.to.line") { [weak self] in
            guard let self else { return }; self.timeline.range = (min(self.timeline.range.0, self.timeline.playhead - 0.1), self.timeline.playhead)
        }
        addButton("Play Selection", symbol: "play.fill") { [weak self] in
            guard let self else { return }; self.player.seek(self.timeline.range.0); self.player.player.play()
        }
        if !isVideo {
            addButton("Remove Silence at Ends", symbol: "waveform.badge.minus") { [weak self] in
                guard let self else { return }
                self.setStatus("Detecting silence…")
                let url = self.files[0], d = self.duration
                DispatchQueue.global().async {
                    let bounds = MediaConvert.silenceBounds(url, duration: d)
                    DispatchQueue.main.async {
                        if let b = bounds { self.timeline.range = b; self.setStatus("Trimmed silence") } else { self.setStatus("No leading or trailing silence found") }
                    }
                }
            }
        }
        addNote("Drag the handles on the timeline, or move the playhead and set the start or end to it.")
        timeline.onChange = { [weak self] in
            guard let self else { return }
            self.startLabel.stringValue = "Start: \(timeString(self.timeline.range.0))"
            self.endLabel.stringValue = "End: \(timeString(self.timeline.range.1))"
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mediaLoaded() { timeline.range = (0, duration) }

    override func playheadMoved(_ t: Double) {
        if player.player.rate > 0, t >= timeline.range.1 { player.pause() }
    }

    override func performSave() -> Bool {
        let (s, e) = timeline.range
        guard e > s else { return false }
        let url = files[0]
        runJob(title: isVideo ? "Trimming video" : "Trimming audio") { job in [try MediaConvert.trim(url, start: s, end: e, job: job)] }
        return true
    }
}

final class SplitVideoWindow: TimelineWindow {
    private let countLabel = NSTextField(labelWithString: "1 clip")
    init(files: [URL]) {
        super.init(title: "Split Video", files: files)
        timeline.mode = .markers
        addHeading("Split points")
        addView(countLabel)
        addButton("Add Split at Playhead", symbol: "plus") { [weak self] in
            guard let self else { return }; self.timeline.markers.append(self.timeline.playhead)
        }
        addButton("Split Every…", symbol: "timer") { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = "Split every N seconds"
            let field = NSTextField(string: "60"); field.frame = NSRect(x: 0, y: 0, width: 120, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, let n = Double(field.stringValue), n > 0 {
                self.timeline.markers = stride(from: n, to: self.duration, by: n).map { $0 }
            }
        }
        addButton("Into Equal Parts…", symbol: "rectangle.split.3x1") { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = "Split into how many equal parts?"
            let field = NSTextField(string: "2"); field.frame = NSRect(x: 0, y: 0, width: 120, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue), n > 1 {
                self.timeline.markers = (1..<n).map { Double($0) * self.duration / Double(n) }
            }
        }
        addButton("Clear", symbol: "trash") { [weak self] in self?.timeline.markers = [] }
        addNote("Every section between split points is saved as a separate clip in a new folder. Drag a marker to move it; press Delete with the playhead on a marker to remove it.")
        timeline.onChange = { [weak self] in self?.countLabel.stringValue = "\((self?.timeline.markers.count ?? 0) + 1) clips" }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func performSave() -> Bool {
        let points = timeline.markers, url = files[0]
        runJob(title: "Splitting video") { job in [try MediaConvert.split(url, at: points, job: job)] }
        return true
    }
}

final class SnapshotsWindow: TimelineWindow {
    private let list = NSTextField(wrappingLabelWithString: "No snapshots yet")
    init(files: [URL]) {
        super.init(title: "Video Snapshots", files: files)
        timeline.mode = .markers
        addHeading("Snapshots")
        addButton("Capture Current Frame", symbol: "camera") { [weak self] in
            guard let self else { return }; self.timeline.markers.append(self.timeline.playhead)
        }
        addButton("Clear", symbol: "trash") { [weak self] in self?.timeline.markers = [] }
        list.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addView(list)
        addNote("Scrub or step through frames and capture the ones you want. Snapshots are exported as full-resolution PNGs.")
        timeline.onChange = { [weak self] in
            guard let self else { return }
            let m = self.timeline.markers.sorted()
            self.list.stringValue = m.isEmpty ? "No snapshots yet" : m.map(timeString).joined(separator: "\n")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func performSave() -> Bool {
        let times = timeline.markers.sorted(), url = files[0]
        guard !times.isEmpty else { setStatus("Capture at least one frame"); return false }
        runJob(title: "Saving snapshots") { job in try MediaConvert.snapshots(url, times: times, job: job) }
        return true
    }
}

final class BleepWindow: TimelineWindow {
    init(files: [URL]) {
        super.init(title: "Bleep Audio", files: files)
        timeline.mode = .ranges
        addHeading("Ranges")
        addButton("Add 1s at Playhead", symbol: "plus") { [weak self] in
            guard let self else { return }
            self.timeline.ranges.append((self.timeline.playhead, min(self.duration, self.timeline.playhead + 1)))
            self.timeline.selectedRange = self.timeline.ranges.count - 1
        }
        addButton("Remove Selected", symbol: "minus.circle") { [weak self] in
            guard let self, let s = self.timeline.selectedRange, s < self.timeline.ranges.count else { return }
            self.timeline.ranges.remove(at: s); self.timeline.selectedRange = nil
        }
        addNote("Drag across the waveform to mark speech to bleep. Click a range to select it, then drag its handles or press Delete.")
        timeline.onChange = { [weak self] in self?.setStatus("\(self?.timeline.ranges.count ?? 0) range(s)") }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func performSave() -> Bool {
        let ranges = timeline.ranges, url = files[0]
        guard !ranges.isEmpty else { setStatus("Mark at least one range"); return false }
        runJob(title: "Bleeping audio") { job in [try MediaConvert.bleep(url, ranges: ranges, job: job)] }
        return true
    }
}

// MARK: - Option-only windows

final class SpeedWindow: ToolWindow {
    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
    private var factor = 2.0
    init(files: [URL]) {
        super.init(title: "Change Video Speed", files: files, size: NSSize(width: 420, height: 240), showsPreview: false)
        addHeading("Playback speed")
        addPopup("Speed", items: Self.speeds.map { "\($0)×" }, selected: 5) { [weak self] i in self?.factor = Self.speeds[i] }
        addNote("Audio keeps its pitch. Applies to every selected file.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func performSave() -> Bool {
        let f = factor
        for url in files { JobCenter.shared.run(title: "Changing speed to \(f)×", fileName: url.lastPathComponent) { job in [try MediaConvert.speed(url, factor: f, job: job)] } }
        return true
    }
}

final class ChannelsWindow: ToolWindow {
    private var mode = MediaConvert.ChannelMode.mono
    init(files: [URL]) {
        super.init(title: "Convert Audio Channels", files: files, size: NSSize(width: 440, height: 240), showsPreview: false)
        addHeading("Channels")
        let current = (try? Shell.probe(files[0]))?.audioChannels ?? 0
        addPopup("Convert to", items: MediaConvert.ChannelMode.allCases.map { $0.name }, selected: current == 1 ? 1 : 0) { [weak self] i in self?.mode = .init(rawValue: i) ?? .mono }
        if current > 0 { setStatus("Currently \(current == 1 ? "mono" : "\(current) channels")") }
        addNote("Mono mixes both channels into one. Stereo duplicates a mono recording into both channels. The left/right options copy one channel to both sides or swap them.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func performSave() -> Bool {
        let m = mode
        for url in files { JobCenter.shared.run(title: "Converting channels", fileName: url.lastPathComponent) { job in [try MediaConvert.channels(url, mode: m, job: job)] } }
        return true
    }
}

final class VisualizerWindow: ToolWindow {
    private var shape = MediaConvert.VisualizerShape.landscape
    private var color = NSColor(calibratedRed: 0.12, green: 0.83, blue: 0.72, alpha: 1)
    private var image: URL?
    private var imageLabel = NSTextField(labelWithString: "Background: black")
    init(files: [URL]) {
        super.init(title: "Audio Visualizer", files: files, size: NSSize(width: 440, height: 320), showsPreview: false)
        addHeading("Video")
        addPopup("Shape", items: ["Landscape 1920×1080", "Portrait 1080×1920", "Square 1080×1080"]) { [weak self] i in self?.shape = .init(rawValue: i) ?? .landscape }
        addColorWell("Waveform color", color: color) { [weak self] c in self?.color = c }
        addView(imageLabel)
        addButton("Choose Background Image…", symbol: "photo") { [weak self] in
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            if p.runModal() == .OK { self?.image = p.url; self?.imageLabel.stringValue = "Background: \(p.url?.lastPathComponent ?? "")" }
        }
        addButton("Use Black Background") { [weak self] in self?.image = nil; self?.imageLabel.stringValue = "Background: black" }
        addNote("Creates an MP4 with a live waveform drawn over a black background or your image.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func performSave() -> Bool {
        let s = shape, c = color, img = image
        for url in files { JobCenter.shared.run(title: "Rendering visualizer", fileName: url.lastPathComponent) { job in [try MediaConvert.visualize(url, shape: s, color: c, image: img, job: job)] } }
        return true
    }
}

/// Reorderable file list used by Join Videos and Collage.
final class OrderListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var urls: [URL] { didSet { table.reloadData(); onChange?() } }
    var onChange: (() -> Void)?
    private let table = NSTableView()
    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Order (drag to rearrange)"
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.string])
        table.headerView = nil
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(equalToConstant: 180)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let iv = NSImageView(image: NSWorkspace.shared.icon(forFile: urls[row].path))
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: "\(row + 1). \(urls[row].lastPathComponent)")
        tf.lineBreakMode = .byTruncatingMiddle
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv); cell.addSubview(tf)
        NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor), iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16), tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { "\(row)" as NSString }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: .string), let from = Int(s) else { return false }
        var list = urls
        let item = list.remove(at: from)
        list.insert(item, at: from < row ? row - 1 : row)
        urls = list
        return true
    }
}

final class JoinWindow: ToolWindow {
    private let list: OrderListView
    init(files: [URL]) {
        list = OrderListView(urls: files)
        super.init(title: "Join Videos", files: files, size: NSSize(width: 460, height: 360), showsPreview: false)
        addHeading("Playback order")
        addView(list)
        addNote("Clips are scaled to match the first clip and saved as one MP4 beside it.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func performSave() -> Bool {
        let urls = list.urls
        runJob(title: "Joining videos", fileName: "\(urls.count) clips") { job in [try MediaConvert.join(urls, job: job)] }
        return true
    }
}

final class CollageWindow: ToolWindow {
    private var options = Collage.Options()
    private let canvas = ImageCanvasView()
    private let list: OrderListView
    private var thumbs: [URL: CGImage] = [:]
    private var format = "png"

    init(files: [URL]) {
        list = OrderListView(urls: files)
        super.init(title: "Create Collage", files: files)
        setPreview(canvas)
        addHeading("Layout")
        addPopup("Layout", items: ["Grid", "Row", "Column", "Featured"]) { [weak self] i in self?.options.layout = .init(rawValue: i) ?? .grid; self?.rebuild() }
        addSlider("Spacing", min: 0, max: 0.08, value: 0.02, format: { String(format: "%.1f%%", $0 * 100) }) { [weak self] v in self?.options.spacing = v; self?.rebuild() }
        addSlider("Corner radius", min: 0, max: 0.2, value: 0.02, format: { String(format: "%.0f%%", $0 * 100) }) { [weak self] v in self?.options.radius = v; self?.rebuild() }
        addColorWell("Background", color: .white) { [weak self] c in self?.options.background = c; self?.rebuild() }
        addPopup("Save as", items: ["PNG", "JPG"]) { [weak self] i in self?.format = i == 0 ? "png" : "jpg" }
        addHeading("Order")
        addView(list)
        list.onChange = { [weak self] in self?.rebuild() }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var t: [URL: CGImage] = [:]
            for u in files { if let cg = try? ImageConvert.load(u) { t[u] = ImageConvert.resized(cg, maxDimension: 600) } }
            DispatchQueue.main.async { self.thumbs = t; self.rebuild() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        let imgs = list.urls.compactMap { thumbs[$0] }
        guard !imgs.isEmpty else { return }
        var o = options; o.cell = 400
        DispatchQueue.global().async { [weak self] in
            let cg = try? Collage.image(imgs, options: o, maxWidth: 1600)
            DispatchQueue.main.async { self?.canvas.image = cg }
        }
    }

    override func performSave() -> Bool {
        let urls = list.urls, o = options, ext = format
        runJob(title: "Creating collage", fileName: "\(urls.count) images") { _ in
            [try Collage.render(urls, options: o, output: Naming.output(beside: urls[0], suffix: "Collage", ext: ext))]
        }
        return true
    }
}

// MARK: - PDF organizer

final class OrganizePDFWindow: ToolWindow {
    private let grid = PageGridView()
    private var doc: PDFDocument?

    init(files: [URL]) {
        super.init(title: "Organize PDF", files: files)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = grid
        scroll.drawsBackground = false
        setPreview(scroll)
        grid.onChange = { [weak self] in self?.setStatus("\(self?.grid.pages.count ?? 0) pages") }
        addHeading("Pages")
        addButton("Rotate Left", symbol: "rotate.left") { [weak self] in self?.grid.rotateSelected(-90) }
        addButton("Rotate Right", symbol: "rotate.right") { [weak self] in self?.grid.rotateSelected(90) }
        addButton("Duplicate", symbol: "plus.square.on.square") { [weak self] in self?.grid.duplicateSelected() }
        addButton("Remove", symbol: "trash") { [weak self] in self?.grid.removeSelected() }
        addButton("Reverse Order", symbol: "arrow.up.arrow.down") { [weak self] in self?.grid.pages.reverse() }
        addNote("Click a page to select it and drag it to a new position. Rotations and removals are applied when you save.")
        DispatchQueue.global().async { [weak self] in
            guard let self, let doc = try? PDFConvert.open(self.files[0]) else { return }
            var pages: [PageGridView.Page] = []
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                let thumb = p.thumbnail(of: NSSize(width: 220, height: 220), for: .mediaBox)
                pages.append(.init(index: i, rotation: 0, thumb: thumb))
            }
            DispatchQueue.main.async { self.doc = doc; self.grid.pages = pages }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func performSave() -> Bool {
        guard let doc else { return false }
        let order = grid.pages.map { $0.index }
        var rotations: [Int: Int] = [:]
        for (i, p) in grid.pages.enumerated() where p.rotation != 0 { rotations[i] = p.rotation }
        let url = files[0]
        runJob(title: "Organizing PDF") { _ in [try PDFTools.organize(doc, order: order, rotations: rotations, source: url)] }
        return true
    }
}

final class PageGridView: NSView {
    struct Page { var index: Int; var rotation: Int; var thumb: NSImage }
    var pages: [Page] = [] { didSet { relayout(); onChange?() } }
    var selected: Int? { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?
    private let cell: CGFloat = 150, gap: CGFloat = 16
    private var dragIndex: Int?
    private var dragPoint: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var columns: Int { max(1, Int((bounds.width - gap) / (cell + gap))) }
    private func frame(for i: Int) -> CGRect {
        CGRect(x: gap + CGFloat(i % columns) * (cell + gap), y: gap + CGFloat(i / columns) * (cell + gap + 20), width: cell, height: cell)
    }
    override func layout() { super.layout(); relayout() }
    private func relayout() {
        let rows = pages.isEmpty ? 1 : (pages.count + columns - 1) / columns
        let height = gap + CGFloat(rows) * (cell + gap + 20)
        if frame.height != height { setFrameSize(NSSize(width: max(bounds.width, superview?.bounds.width ?? bounds.width), height: height)) }
        needsDisplay = true
    }
    override func viewDidMoveToSuperview() { if let s = superview { setFrameSize(NSSize(width: s.bounds.width, height: bounds.height)); autoresizingMask = [.width] } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        for (i, p) in pages.enumerated() {
            var f = frame(for: i)
            if i == dragIndex, let dp = dragPoint { f.origin = CGPoint(x: dp.x - cell / 2, y: dp.y - cell / 2) }
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: f, xRadius: 8, yRadius: 8).fill()
            let s = p.thumb.size
            let scale = min((cell - 16) / s.width, (cell - 16) / s.height)
            let w = s.width * scale, h = s.height * scale
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: f.midX, yBy: f.midY)
            t.rotate(byDegrees: CGFloat(-p.rotation))
            t.concat()
            p.thumb.draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            if i == selected {
                NSColor.controlAccentColor.setStroke()
                let o = NSBezierPath(roundedRect: f.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8); o.lineWidth = 3; o.stroke()
            }
            let label = "\(i + 1)" + (p.rotation != 0 ? " · \(p.rotation)°" : "")
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.lightGray]
            let sz = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: f.midX - sz.width / 2, y: f.maxY + 3), withAttributes: attrs)
        }
    }

    private func index(at p: CGPoint) -> Int? { pages.indices.first { frame(for: $0).contains(p) } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        selected = index(at: p)
        dragIndex = selected
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragIndex = nil; dragPoint = nil; needsDisplay = true }
        guard let from = dragIndex, let dp = dragPoint else { return }
        // Nearest slot to the drop point.
        var best = from, bestD = CGFloat.greatestFiniteMagnitude
        for i in pages.indices { let f = frame(for: i); let d = hypot(f.midX - dp.x, f.midY - dp.y); if d < bestD { bestD = d; best = i } }
        guard best != from else { return }
        let item = pages.remove(at: from)
        pages.insert(item, at: best)
        selected = best
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { removeSelected() } else { super.keyDown(with: event) }
    }
    func rotateSelected(_ deg: Int) { guard let s = selected, s < pages.count else { return }; pages[s].rotation = (pages[s].rotation + deg + 360) % 360 }
    func duplicateSelected() { guard let s = selected, s < pages.count else { return }; pages.insert(pages[s], at: s + 1) }
    func removeSelected() { guard let s = selected, s < pages.count else { return }; pages.remove(at: s); selected = nil }
}

// MARK: - Metadata editor

final class MetadataWindow: ToolWindow, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var entries: [(key: String, value: String)] = []
    private var readOnly: [(key: String, value: String)] = []   // per-track and chapter info (shown, not written)
    private var filter = ""
    private var visible: [(key: String, value: String, editable: Bool)] {
        let all = entries.map { ($0.key, $0.value, true) } + readOnly.map { ($0.key, $0.value, false) }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.0.localizedCaseInsensitiveContains(filter) || $0.1.localizedCaseInsensitiveContains(filter) }
    }
    private let table = NSTableView()
    private let search = NSSearchField()
    private let category: Category?
    private var imageProps: [CFString: Any] = [:]
    private var hasGPS = false

    private static let imageFields: [(String, CFString, CFString)] = [
        ("Title", kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName),
        ("Description", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
        ("Author", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist),
        ("Copyright", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright),
        ("Software", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware),
        ("Camera make", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake),
        ("Camera model", kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel),
        ("Lens", kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel),
        ("Date taken", kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal),
        ("Comment", kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment),
    ]
    private static let mediaFields = ["title", "artist", "album", "album_artist", "composer", "genre", "date", "track", "comment", "description", "copyright", "encoder", "location", "make", "model"]
    private static let pdfFields: [(String, PDFDocumentAttribute)] = [("Title", .titleAttribute), ("Author", .authorAttribute), ("Subject", .subjectAttribute), ("Keywords", .keywordsAttribute), ("Creator", .creatorAttribute), ("Producer", .producerAttribute)]

    init(files: [URL]) {
        category = Formats.category(of: Formats.kind(of: files[0]))
        super.init(title: "Metadata", files: files, size: NSSize(width: 560, height: 480), showsPreview: false)
        sidebar.alignment = .leading
        search.placeholderString = "Search fields (file, track, chapter)"
        search.delegate = self
        addView(search)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        let keyCol = NSTableColumn(identifier: .init("key")); keyCol.title = "Field"; keyCol.width = 150
        let valCol = NSTableColumn(identifier: .init("value")); valCol.title = "Value"; valCol.width = 340
        table.addTableColumn(keyCol); table.addTableColumn(valCol)
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        addView(scroll)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let removeAll = NSButton(title: "Save Without Any Metadata", target: self, action: #selector(removeAllTapped))
        buttons.addArrangedSubview(removeAll)
        if category == .image {
            let gps = NSButton(title: "Remove Location", target: self, action: #selector(removeGPS))
            buttons.addArrangedSubview(gps)
        }
        addView(buttons, fullWidth: false)
        addNote("Edit a value and press Return. Save Copy writes a new file with the changes; the original is untouched.")
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        let url = files[0]
        switch category {
        case .image:
            imageProps = ImageConvert.metadata(of: url)
            hasGPS = (imageProps[kCGImagePropertyGPSDictionary] as? [CFString: Any])?.isEmpty == false
            entries = Self.imageFields.map { (name, dict, key) in
                (name, ((imageProps[dict] as? [CFString: Any])?[key]).map { "\($0)" } ?? "")
            }
            setStatus(hasGPS ? "Contains GPS location" : "No GPS location")
        case .audio, .video:
            let info = try? Shell.probe(url)
            let tags = info?.tags ?? [:]
            var keys = Self.mediaFields
            for k in tags.keys.sorted() where !keys.contains(k.lowercased()) { keys.append(k) }
            entries = keys.map { k in (k, tags[k] ?? tags.first { $0.key.lowercased() == k }?.value ?? "") }
            readOnly = (info?.streamTags ?? []).map { ($0.0, $0.1) } + (info?.chapters ?? []).map { ($0.0, $0.1) }
        case .document:
            let attrs = (try? PDFConvert.open(url))?.documentAttributes ?? [:]
            entries = Self.pdfFields.map { ($0.0, (attrs[$0.1] as? String) ?? "") }
        default:
            entries = []
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let v = visible[row]
        return tableColumn?.identifier.rawValue == "key" ? v.key : v.value
    }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "value", visible[row].editable else { return }
        let key = visible[row].key
        if let i = entries.firstIndex(where: { $0.key == key }) { entries[i].value = object as? String ?? "" }
    }
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { tableColumn?.identifier.rawValue == "value" && visible[row].editable }
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { filter = search.stringValue; table.reloadData() }
    }

    @objc private func removeGPS() {
        imageProps.removeValue(forKey: kCGImagePropertyGPSDictionary)
        if var exif = imageProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for k in exif.keys where "\(k)".lowercased().contains("gps") { exif.removeValue(forKey: k) }
            imageProps[kCGImagePropertyExifDictionary] = exif
        }
        hasGPS = false
        setStatus("Location will be removed on save")
    }

    @objc private func removeAllTapped() {
        let url = files[0]
        runJob(title: "Removing metadata") { job in try Actions.runHeadless(tool: .removeMetadata, files: [url], job: job) }
        window?.close()
    }

    override func performSave() -> Bool {
        window?.makeFirstResponder(nil)
        let url = files[0]
        switch category {
        case .image:
            var props = imageProps
            for (i, f) in Self.imageFields.enumerated() {
                var dict = props[f.1] as? [CFString: Any] ?? [:]
                let v = entries[i].value
                if v.isEmpty { dict.removeValue(forKey: f.2) } else { dict[f.2] = v }
                props[f.1] = dict
            }
            let kind = Formats.kind(of: url)
            runJob(title: "Writing metadata") { _ in
                let out = Naming.output(beside: url, suffix: "Tagged", ext: kind)
                try ImageConvert.writeMetadata(props, from: url, to: out)
                return [out]
            }
        case .audio, .video:
            var tags: [String: String] = [:]
            for e in entries where !e.value.isEmpty { tags[e.key] = e.value }
            runJob(title: "Writing metadata") { job in [try MediaConvert.writeMetadata(url, tags: tags, job: job)] }
        case .document:
            let values = entries
            runJob(title: "Writing metadata") { _ in
                let doc = try PDFConvert.open(url)
                var attrs: [AnyHashable: Any] = [:]
                for (i, f) in Self.pdfFields.enumerated() where !values[i].value.isEmpty { attrs[f.1] = values[i].value }
                doc.documentAttributes = attrs
                let out = Naming.output(beside: url, suffix: "Tagged", ext: "pdf")
                guard doc.write(to: out) else { throw ConvError.failed("Could not write PDF") }
                return [out]
            }
        default: return false
        }
        return true
    }
}

import AppKit

/// Arrows, boxes, ellipses, freehand strokes and text drawn over a photo.
enum Annotate {
    enum Kind: Int, CaseIterable { case arrow = 0, rectangle, ellipse, line, freehand, text, highlight
        var name: String { ["Arrow", "Rectangle", "Ellipse", "Line", "Freehand", "Text", "Highlighter"][rawValue] }
    }

    struct Shape {
        var kind: Kind
        var from: CGPoint          // image pixels, top-left origin
        var to: CGPoint
        var color: NSColor
        var width: CGFloat
        var text: String
        var points: [CGPoint] = [] // freehand
    }

    /// Draws shapes into a CGContext whose coordinate system is already flipped (top-left origin, pixel units).
    static func draw(_ shapes: [Shape], in ctx: CGContext, scale: CGFloat = 1) {
        for s in shapes {
            let color = (s.color.usingColorSpace(.sRGB) ?? s.color).cgColor
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(s.width * scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let a = CGPoint(x: s.from.x * scale, y: s.from.y * scale), b = CGPoint(x: s.to.x * scale, y: s.to.y * scale)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            switch s.kind {
            case .rectangle:
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s.width * scale, cornerHeight: s.width * scale, transform: nil)); ctx.strokePath()
            case .ellipse:
                ctx.addEllipse(in: rect); ctx.strokePath()
            case .line:
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            case .highlight:
                ctx.setFillColor(color.copy(alpha: 0.35) ?? color)
                ctx.fill(rect)
            case .arrow:
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(12, s.width * 4) * scale
                let tip = b
                let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6)
                ctx.move(to: a); ctx.addLine(to: shaftEnd); ctx.strokePath()
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x - cos(angle - 0.45) * head, y: tip.y - sin(angle - 0.45) * head))
                ctx.addLine(to: CGPoint(x: tip.x - cos(angle + 0.45) * head, y: tip.y - sin(angle + 0.45) * head))
                ctx.closePath(); ctx.fillPath()
            case .freehand:
                guard let first = s.points.first else { break }
                ctx.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
                for p in s.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
                ctx.strokePath()
            case .text:
                let font = NSFont.systemFont(ofSize: max(10, s.width * 5) * scale, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: s.color, .strokeColor: NSColor.black.withAlphaComponent(0.6), .strokeWidth: -2]
                let str = NSAttributedString(string: s.text.isEmpty ? "Text" : s.text, attributes: attrs)
                let line = CTLineCreateWithAttributedString(str)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: a.x, y: a.y + font.ascender)
                ctx.scaleBy(x: 1, y: -1)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    static func render(_ cg: CGImage, shapes: [Shape]) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConvError.failed("Cannot create canvas") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.translateBy(x: 0, y: CGFloat(cg.height))
        ctx.scaleBy(x: 1, y: -1)
        draw(shapes, in: ctx)
        guard let out = ctx.makeImage() else { throw ConvError.failed("Cannot render annotations") }
        return out
    }

    static func save(_ url: URL, shapes: [Shape]) throws -> URL {
        let kind = Formats.kind(of: url)
        let outKind = kind == "svg" ? "png" : kind
        let out = Naming.output(beside: url, suffix: "Annotated", ext: outKind)
        try ImageConvert.write(try render(try ImageConvert.load(url), shapes: shapes), to: out, kind: outKind, quality: 0.92)
        return out
    }
}

final class AnnotateView: ImageCanvasView {
    var shapes: [Annotate.Shape] = [] { didSet { needsDisplay = true; onChange?() } }
    var tool: Annotate.Kind = .arrow
    var color: NSColor = .systemRed
    var strokeWidth: CGFloat = 6
    var text = "Text"
    var onChange: (() -> Void)?
    private var drawing = false
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard image != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = imageFrame
        ctx.saveGState()
        ctx.clip(to: f)
        ctx.translateBy(x: f.minX, y: f.maxY)
        ctx.scaleBy(x: 1, y: -1)
        Annotate.draw(shapes, in: ctx, scale: scale)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        guard imageFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        drawing = true
        var s = Annotate.Shape(kind: tool, from: p, to: p, color: color, width: strokeWidth, text: text)
        if tool == .freehand { s.points = [p] }
        shapes.append(s)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing, !shapes.isEmpty else { return }
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        shapes[shapes.count - 1].to = p
        if tool == .freehand { shapes[shapes.count - 1].points.append(p) }
    }

    override func mouseUp(with event: NSEvent) {
        drawing = false
        if let last = shapes.last, last.kind != .text, last.kind != .freehand, hypot(last.to.x - last.from.x, last.to.y - last.from.y) < 3 { shapes.removeLast() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, !shapes.isEmpty { shapes.removeLast() } else { super.keyDown(with: event) }
    }
}

final class AnnotateWindow: ToolWindow {
    private let canvas = AnnotateView()

    init(files: [URL]) {
        super.init(title: "Annotate Photo", files: files)
        setPreview(canvas)
        addHeading("Tool")
        addPopup("Shape", items: Annotate.Kind.allCases.map { $0.name }) { [weak self] i in self?.canvas.tool = Annotate.Kind(rawValue: i) ?? .arrow }
        addColorWell("Color", color: .systemRed) { [weak self] c in self?.canvas.color = c }
        addSlider("Stroke", min: 2, max: 30, value: 6, format: { String(format: "%.0f px", $0) }) { [weak self] v in self?.canvas.strokeWidth = v }
        addField("Text", value: "Text") { [weak self] v in self?.canvas.text = v }
        addSeparator()
        addButton("Undo Last", symbol: "arrow.uturn.backward") { [weak self] in if self?.canvas.shapes.isEmpty == false { self?.canvas.shapes.removeLast() } }
        addButton("Clear All", symbol: "trash") { [weak self] in self?.canvas.shapes = [] }
        addNote("Drag on the photo to draw. For text, click where it should start; edit the Text field first. Delete removes the last shape.")
        canvas.onChange = { [weak self] in self?.setStatus("\(self?.canvas.shapes.count ?? 0) annotation(s)") }
        DispatchQueue.global().async { [weak self] in
            guard let self, let cg = try? ImageConvert.load(self.files[0]) else { return }
            DispatchQueue.main.async { self.canvas.image = cg }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func performSave() -> Bool {
        let shapes = canvas.shapes, url = files[0]
        guard !shapes.isEmpty else { setStatus("Draw at least one annotation"); return false }
        runJob(title: "Annotating photo") { _ in [try Annotate.save(url, shapes: shapes)] }
        return true
    }
}

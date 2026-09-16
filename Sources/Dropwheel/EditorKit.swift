import AppKit
import AVFoundation
import AVKit

/// Keeps editor windows alive while they are open.
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [ToolWindow] = []
    func retain(_ w: ToolWindow) { windows.append(w) }
    func release(_ w: ToolWindow) { windows.removeAll { $0 === w } }
}

/// Base class for tool editor windows: preview on the left, controls on the right, Cancel/Save at the bottom.
class ToolWindow: NSWindowController, NSWindowDelegate {
    let files: [URL]
    let previewContainer = NSView()
    let sidebar = NSStackView()
    let saveButton = NSButton(title: "Save Copy", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    var sidebarWidth: CGFloat = 280

    init(title: String, files: [URL], size: NSSize = NSSize(width: 980, height: 640), showsPreview: Bool = true) {
        self.files = files
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(title) — \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: showsPreview ? 700 : 420, height: 400)
        super.init(window: window)
        window.delegate = self
        if !showsPreview { sidebarWidth = size.width }

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(sidebar)
        scroll.documentView = clip

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        bottom.addArrangedSubview(statusLabel)
        bottom.addArrangedSubview(NSView())
        bottom.addArrangedSubview(cancel)
        bottom.addArrangedSubview(saveButton)

        content.addSubview(previewContainer)
        content.addSubview(scroll)
        content.addSubview(bottom)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        NSLayoutConstraint.activate([
            previewContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewContainer.topAnchor.constraint(equalTo: content.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: divider.topAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: scroll.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: sidebarWidth),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            sidebar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: clip.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if !showsPreview { previewContainer.widthAnchor.constraint(equalToConstant: 0).isActive = true }
        window.contentView = content
        window.center()
        WindowRegistry.shared.retain(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
        WindowRegistry.shared.release(self)
    }

    /// Subclasses override to stop players etc.
    func cleanup() {}

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    /// Subclasses schedule their job here; return false to keep the window open.
    func performSave() -> Bool { true }

    @objc private func saveTapped() {
        if performSave() { window?.close() }
    }

    @objc private func cancelTapped() { window?.close() }

    /// Helper: run a job with the window's first file name and close.
    func runJob(title: String, fileName: String? = nil, work: @escaping (Job) throws -> [URL]) {
        JobCenter.shared.run(title: title, fileName: fileName ?? files[0].lastPathComponent, work: work)
    }

    // MARK: sidebar helpers

    func setPreview(_ view: NSView) {
        previewContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
    }

    func addHeading(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(l)
    }

    func addNote(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = sidebarWidth - 32
        sidebar.addArrangedSubview(l)
    }

    func addSeparator() {
        let b = NSBox()
        b.boxType = .separator
        sidebar.addArrangedSubview(b)
        b.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -32).isActive = true
    }

    func addView(_ v: NSView, fullWidth: Bool = true) {
        sidebar.addArrangedSubview(v)
        if fullWidth { v.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -32).isActive = true }
    }

    @discardableResult
    func addSlider(_ title: String, min: Double, max: Double, value: Double, format: @escaping (Double) -> String = { String(format: "%.2f", $0) }, handler: @escaping (Double) -> Void) -> NSSlider {
        let row = NSStackView()
        row.orientation = .horizontal
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let value = NSTextField(labelWithString: format(value))
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 60).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(value)
        let slider = NSSlider(value: value.doubleValue, minValue: min, maxValue: max, target: nil, action: nil)
        slider.doubleValue = Double(format(0).isEmpty ? 0 : 0)
        slider.doubleValue = value.stringValue.isEmpty ? min : slider.doubleValue
        let box = SliderBox(slider: slider, valueLabel: value, format: format, handler: handler)
        slider.doubleValue = box.initial
        slider.target = box
        slider.action = #selector(SliderBox.changed)
        slider.isContinuous = true
        objc_setAssociatedObject(slider, "box", box, .OBJC_ASSOCIATION_RETAIN)
        addView(row)
        addView(slider)
        return slider
    }

    private final class SliderBox: NSObject {
        let valueLabel: NSTextField
        let format: (Double) -> String
        let handler: (Double) -> Void
        let initial: Double
        init(slider: NSSlider, valueLabel: NSTextField, format: @escaping (Double) -> String, handler: @escaping (Double) -> Void) {
            self.valueLabel = valueLabel; self.format = format; self.handler = handler
            self.initial = Double(valueLabel.stringValue.replacingOccurrences(of: "[^0-9.-]", with: "", options: .regularExpression)) ?? slider.doubleValue
        }
        @objc func changed(_ s: NSSlider) { valueLabel.stringValue = format(s.doubleValue); handler(s.doubleValue) }
    }

    @discardableResult
    func addPopup(_ title: String, items: [String], selected: Int = 0, handler: @escaping (Int) -> Void) -> NSPopUpButton {
        let row = NSStackView()
        row.orientation = .horizontal
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: items)
        popup.selectItem(at: selected)
        let box = ActionBox { handler(popup.indexOfSelectedItem) }
        popup.target = box
        popup.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(popup, "box", box, .OBJC_ASSOCIATION_RETAIN)
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        addView(row)
        return popup
    }

    @discardableResult
    func addCheckbox(_ title: String, on: Bool, handler: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        let box = ActionBox { handler(b.state == .on) }
        b.target = box
        b.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(b, "box", box, .OBJC_ASSOCIATION_RETAIN)
        addView(b)
        return b
    }

    @discardableResult
    func addButton(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        let box = ActionBox(handler)
        b.target = box
        b.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(b, "box", box, .OBJC_ASSOCIATION_RETAIN)
        addView(b, fullWidth: false)
        return b
    }

    @discardableResult
    func addColorWell(_ title: String, color: NSColor, handler: @escaping (NSColor) -> Void) -> NSColorWell {
        let row = NSStackView()
        row.orientation = .horizontal
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let well = NSColorWell()
        well.color = color
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let box = ActionBox { handler(well.color) }
        well.target = box
        well.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(well, "box", box, .OBJC_ASSOCIATION_RETAIN)
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(well)
        addView(row)
        return well
    }

    @discardableResult
    func addField(_ title: String, value: String, handler: @escaping (String) -> Void) -> NSTextField {
        let row = NSStackView()
        row.orientation = .horizontal
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let field = NSTextField(string: value)
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let box = ActionBox { handler(field.stringValue) }
        field.target = box
        field.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(field, "box", box, .OBJC_ASSOCIATION_RETAIN)
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(field)
        addView(row)
        return field
    }
}

final class ActionBox: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Shows an image fit to the view. Subclasses draw overlays in image-pixel space.
class ImageCanvasView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize: CGSize { CGSize(width: image?.width ?? 1, height: image?.height ?? 1) }

    /// Frame of the image inside the view (points).
    var imageFrame: CGRect {
        let s = imageSize
        let avail = bounds.insetBy(dx: 16, dy: 16)
        let scale = min(avail.width / s.width, avail.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }
    var scale: CGFloat { imageFrame.width / imageSize.width }

    /// Image pixel rect (top-left origin) → view rect.
    func viewRect(_ r: CGRect) -> CGRect {
        let f = imageFrame, s = scale
        return CGRect(x: f.minX + r.minX * s, y: f.maxY - (r.minY + r.height) * s, width: r.width * s, height: r.height * s)
    }
    /// View point → image pixel point (top-left origin).
    func imagePoint(_ p: CGPoint) -> CGPoint {
        let f = imageFrame, s = scale
        return CGPoint(x: (p.x - f.minX) / s, y: (f.maxY - p.y) / s)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageFrame)
    }
}

/// Crop (single rect with aspect) or redaction (many rects) editor.
final class RectEditorView: ImageCanvasView {
    enum Mode { case single, multiple }
    var mode: Mode = .single
    var rects: [CGRect] = [] { didSet { needsDisplay = true; onChange?() } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var aspect: CGFloat? { didSet { if let a = aspect, mode == .single, !rects.isEmpty { rects[0] = fitAspect(rects[0], a) } } }
    var onChange: (() -> Void)?

    private enum Handle: Int { case none = -1, tl, t, tr, r, br, b, bl, l, move }
    private var dragHandle: Handle = .none
    private var dragStart = CGPoint.zero
    private var dragOrigin = CGRect.zero
    private var creating = false

    override var acceptsFirstResponder: Bool { true }

    func resetSingle() {
        let s = imageSize
        rects = [CGRect(x: s.width * 0.1, y: s.height * 0.1, width: s.width * 0.8, height: s.height * 0.8)]
        if let a = aspect { rects[0] = fitAspect(rects[0], a) }
        selectedIndex = 0
    }

    private func fitAspect(_ r: CGRect, _ a: CGFloat) -> CGRect {
        var out = r
        if r.width / r.height > a { out.size.width = r.height * a } else { out.size.height = r.width / a }
        out.origin.x = r.midX - out.width / 2
        out.origin.y = r.midY - out.height / 2
        return clamp(out)
    }

    private func clamp(_ r: CGRect) -> CGRect {
        var out = r
        out.size.width = min(out.width, imageSize.width)
        out.size.height = min(out.height, imageSize.height)
        out.origin.x = max(0, min(imageSize.width - out.width, out.minX))
        out.origin.y = max(0, min(imageSize.height - out.height, out.minY))
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard image != nil else { return }
        if mode == .single, let r = rects.first {
            let vr = viewRect(r)
            let dim = NSBezierPath(rect: imageFrame)
            dim.appendRect(vr)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: vr)
            outline.lineWidth = 1.5
            outline.stroke()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            for i in 1...2 {
                let v = NSBezierPath(); v.move(to: CGPoint(x: vr.minX + vr.width * CGFloat(i) / 3, y: vr.minY)); v.line(to: CGPoint(x: vr.minX + vr.width * CGFloat(i) / 3, y: vr.maxY)); v.stroke()
                let h = NSBezierPath(); h.move(to: CGPoint(x: vr.minX, y: vr.minY + vr.height * CGFloat(i) / 3)); h.line(to: CGPoint(x: vr.maxX, y: vr.minY + vr.height * CGFloat(i) / 3)); h.stroke()
            }
            drawHandles(vr)
        } else {
            for (i, r) in rects.enumerated() {
                let vr = viewRect(r)
                NSColor.systemRed.withAlphaComponent(0.35).setFill()
                vr.fill()
                (i == selectedIndex ? NSColor.white : NSColor.systemRed).setStroke()
                let p = NSBezierPath(rect: vr); p.lineWidth = i == selectedIndex ? 2 : 1; p.stroke()
                if i == selectedIndex { drawHandles(vr) }
            }
        }
    }

    private func drawHandles(_ vr: CGRect) {
        NSColor.white.setFill()
        for p in handlePoints(vr) {
            NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
        }
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: CGPoint, for r: CGRect) -> Handle {
        let vr = viewRect(r)
        for (i, hp) in handlePoints(vr).enumerated() where hypot(hp.x - p.x, hp.y - p.y) < 9 { return Handle(rawValue: i)! }
        return vr.contains(p) ? .move : .none
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = imagePoint(p)
        creating = false
        if mode == .single {
            guard let r = rects.first else { return }
            dragHandle = handle(at: p, for: r)
            dragOrigin = r
        } else {
            if let sel = selectedIndex, sel < rects.count, handle(at: p, for: rects[sel]) != .none {
                dragHandle = handle(at: p, for: rects[sel])
                dragOrigin = rects[sel]
            } else if let hit = rects.lastIndex(where: { viewRect($0).contains(p) }) {
                selectedIndex = hit
                dragHandle = .move
                dragOrigin = rects[hit]
            } else if imageFrame.contains(p) {
                creating = true
                rects.append(CGRect(origin: dragStart, size: .zero))
                selectedIndex = rects.count - 1
                dragHandle = .br
                dragOrigin = rects.last!
            } else {
                selectedIndex = nil
                dragHandle = .none
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragHandle != .none, let idx = (mode == .single ? 0 : selectedIndex), idx < rects.count else { return }
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        var r = dragOrigin
        switch dragHandle {
        case .move: r.origin.x += dx; r.origin.y += dy
        case .tl: r.origin.x += dx; r.origin.y += dy; r.size.width -= dx; r.size.height -= dy
        case .t: r.origin.y += dy; r.size.height -= dy
        case .tr: r.origin.y += dy; r.size.width += dx; r.size.height -= dy
        case .r: r.size.width += dx
        case .br: r.size.width += dx; r.size.height += dy
        case .b: r.size.height += dy
        case .bl: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
        case .l: r.origin.x += dx; r.size.width -= dx
        case .none: break
        }
        r = r.standardized
        if dragHandle != .move {
            r.size.width = max(8, r.width); r.size.height = max(8, r.height)
            if let a = aspect, mode == .single {
                let anchoredRight = [Handle.tl, .l, .bl].contains(dragHandle), anchoredBottom = [Handle.tl, .t, .tr].contains(dragHandle)
                if [Handle.t, .b].contains(dragHandle) { r.size.width = r.height * a } else { r.size.height = r.width / a }
                if anchoredRight { r.origin.x = dragOrigin.maxX - r.width }
                if anchoredBottom { r.origin.y = dragOrigin.maxY - r.height }
            }
        }
        r = clamp(r)
        rects[idx] = r
    }

    override func mouseUp(with event: NSEvent) {
        if creating, let idx = selectedIndex, idx < rects.count, rects[idx].width < 4 || rects[idx].height < 4 {
            rects.remove(at: idx)
            selectedIndex = nil
        }
        dragHandle = .none
        creating = false
    }

    override func keyDown(with event: NSEvent) {
        if mode == .multiple, event.keyCode == 51 || event.keyCode == 117, let s = selectedIndex, s < rects.count {
            rects.remove(at: s)
            selectedIndex = nil
        } else { super.keyDown(with: event) }
    }
}

/// Timeline with a waveform, a playhead and either a trim range, multiple ranges or point markers.
final class WaveformView: NSView {
    enum Mode { case range, ranges, markers }
    var mode: Mode = .range { didSet { needsDisplay = true } }
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var range: (Double, Double) = (0, 1) { didSet { needsDisplay = true; onChange?() } }
    var ranges: [(Double, Double)] = [] { didSet { needsDisplay = true; onChange?() } }
    var markers: [Double] = [] { didSet { needsDisplay = true; onChange?() } }
    var selectedRange: Int? { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onChange: (() -> Void)?
    var accent: NSColor = .controlAccentColor

    private enum Drag { case none, start, end, playhead, newRange(Int), marker(Int), rangeStart(Int), rangeEnd(Int), moveRange(Int, Double), moveTrim(Double) }
    private var drag: Drag = .none
    override var acceptsFirstResponder: Bool { true }

    private var trackRect: CGRect { bounds.insetBy(dx: 10, dy: 8) }
    private func x(_ t: Double) -> CGFloat { trackRect.minX + CGFloat(t / max(duration, 0.001)) * trackRect.width }
    private func t(_ x: CGFloat) -> Double { max(0, min(duration, Double((x - trackRect.minX) / trackRect.width) * duration)) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()
        let tr = trackRect
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: tr, xRadius: 6, yRadius: 6).fill()
        // waveform
        let count = peaks.count
        if count > 0 {
            let barW = tr.width / CGFloat(count)
            for (i, p) in peaks.enumerated() {
                let h = max(2, CGFloat(p) * (tr.height - 8))
                let r = CGRect(x: tr.minX + CGFloat(i) * barW, y: tr.midY - h / 2, width: max(1, barW - 1), height: h)
                let tt = Double(i) / Double(count) * duration
                var inside = false
                switch mode {
                case .range: inside = tt >= range.0 && tt <= range.1
                case .ranges: inside = ranges.contains { tt >= $0.0 && tt <= $0.1 }
                case .markers: inside = true
                }
                (inside ? accent : NSColor(calibratedWhite: 0.45, alpha: 1)).setFill()
                r.fill()
            }
        }
        switch mode {
        case .range:
            NSColor.black.withAlphaComponent(0.5).setFill()
            CGRect(x: tr.minX, y: tr.minY, width: x(range.0) - tr.minX, height: tr.height).fill()
            CGRect(x: x(range.1), y: tr.minY, width: tr.maxX - x(range.1), height: tr.height).fill()
            drawHandle(at: x(range.0)); drawHandle(at: x(range.1))
        case .ranges:
            for (i, r) in ranges.enumerated() {
                let rect = CGRect(x: x(r.0), y: tr.minY, width: x(r.1) - x(r.0), height: tr.height)
                NSColor.systemRed.withAlphaComponent(i == selectedRange ? 0.45 : 0.3).setFill()
                rect.fill()
                if i == selectedRange { drawHandle(at: x(r.0), color: .systemRed); drawHandle(at: x(r.1), color: .systemRed) }
            }
        case .markers:
            for m in markers {
                NSColor.systemYellow.setFill()
                CGRect(x: x(m) - 1, y: tr.minY, width: 2, height: tr.height).fill()
                let tri = NSBezierPath()
                tri.move(to: CGPoint(x: x(m) - 6, y: tr.maxY)); tri.line(to: CGPoint(x: x(m) + 6, y: tr.maxY)); tri.line(to: CGPoint(x: x(m), y: tr.maxY - 8)); tri.close()
                tri.fill()
            }
        }
        NSColor.white.setFill()
        CGRect(x: x(playhead) - 1, y: tr.minY, width: 2, height: tr.height).fill()
    }

    private func drawHandle(at hx: CGFloat, color: NSColor = .white) {
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: hx - 4, y: trackRect.minY - 2, width: 8, height: trackRect.height + 4), xRadius: 3, yRadius: 3).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let tt = t(p.x)
        drag = .playhead
        switch mode {
        case .range:
            if abs(p.x - x(range.0)) < 8 { drag = .start } else if abs(p.x - x(range.1)) < 8 { drag = .end }
            else if event.modifierFlags.contains(.option), tt > range.0, tt < range.1 { drag = .moveTrim(tt - range.0) }
        case .ranges:
            if let s = selectedRange, s < ranges.count {
                if abs(p.x - x(ranges[s].0)) < 8 { drag = .rangeStart(s); return }
                if abs(p.x - x(ranges[s].1)) < 8 { drag = .rangeEnd(s); return }
            }
            if let hit = ranges.firstIndex(where: { tt >= $0.0 && tt <= $0.1 }) {
                selectedRange = hit
                drag = .moveRange(hit, tt - ranges[hit].0)
                return
            } else if event.modifierFlags.contains(.shift) || event.clickCount == 1 {
                ranges.append((tt, tt))
                selectedRange = ranges.count - 1
                drag = .newRange(ranges.count - 1)
                return
            }
        case .markers:
            if let hit = markers.firstIndex(where: { abs(x($0) - p.x) < 7 }) { drag = .marker(hit); return }
        }
        if case .playhead = drag { playhead = tt; onSeek?(tt) }
    }

    override func mouseDragged(with event: NSEvent) {
        let tt = t(convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .start: range = (min(tt, range.1 - 0.05), range.1)
        case .end: range = (range.0, max(tt, range.0 + 0.05))
        case .playhead: playhead = tt; onSeek?(tt)
        case .newRange(let i), .rangeEnd(let i): ranges[i] = (min(ranges[i].0, tt), max(ranges[i].0, tt))
        case .rangeStart(let i): ranges[i] = (min(tt, ranges[i].1), ranges[i].1)
        case .marker(let i): markers[i] = tt
        case .moveRange(let i, let offset):
            let len = ranges[i].1 - ranges[i].0
            let s = max(0, min(duration - len, tt - offset))
            ranges[i] = (s, s + len)
        case .moveTrim(let offset):
            let len = range.1 - range.0
            let s = max(0, min(duration - len, tt - offset))
            range = (s, s + len)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .newRange(let i) = drag, i < ranges.count, ranges[i].1 - ranges[i].0 < 0.05 {
            ranges.remove(at: i)
            selectedRange = nil
        }
        drag = .none
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if mode == .ranges, let s = selectedRange, s < ranges.count { ranges.remove(at: s); selectedRange = nil; return }
            if mode == .markers, let hit = markers.firstIndex(where: { abs($0 - playhead) < 0.2 }) { markers.remove(at: hit); return }
        }
        super.keyDown(with: event)
    }
}

/// AVPlayer wrapper with a time callback.
final class Player {
    let player = AVPlayer()
    let view = AVPlayerView()
    private var observer: Any?
    var onTime: ((Double) -> Void)?
    var duration: Double { player.currentItem?.duration.seconds ?? 0 }

    init() {
        view.controlsStyle = .none
        view.player = player
        view.translatesAutoresizingMaskIntoConstraints = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.onTime?(t.seconds)
        }
    }

    func load(_ url: URL) { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
    func seek(_ t: Double) { player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func toggle() { if player.rate == 0 { player.play() } else { player.pause() } }
    func pause() { player.pause() }
    func step(_ frames: Int) { player.pause(); player.currentItem?.step(byCount: frames) }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
}

func timeString(_ t: Double) -> String {
    let m = Int(t) / 60, s = Int(t) % 60, ms = Int((t - floor(t)) * 100)
    return String(format: "%02d:%02d.%02d", m, s, ms)
}

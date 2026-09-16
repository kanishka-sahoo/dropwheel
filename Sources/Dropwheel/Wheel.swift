import AppKit
import UniformTypeIdentifiers

struct WheelItem {
    let id: String
    let label: String
    let symbol: String?
    let description: String
}

final class OverlayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Owns the full-screen transparent panel that hosts the radial wheel.
final class WheelController {
    static let shared = WheelController()

    private let panel: OverlayPanel
    private let view = WheelView()
    private(set) var keyboardMode = false
    var showForcingAdvanced = false
    var isVisible: Bool { panel.isVisible }

    private init() {
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = view
        panel.acceptsMouseMovedEvents = true
        view.controller = self
    }

    func show(files: [URL], at point: NSPoint, keyboard: Bool) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        keyboardMode = keyboard
        panel.allowsKey = keyboard
        panel.setFrame(screen.frame, display: false)
        let local = NSPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        view.configure(files: files, center: local, keyboard: keyboard, advanced: showForcingAdvanced || NSEvent.modifierFlags.contains(.option))
        showForcingAdvanced = false
        if keyboard {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        keyboardMode = false
        panel.allowsKey = false
        panel.orderOut(nil)
        view.reset()
    }
}

/// Draws the wheel and acts as the drag destination.
final class WheelView: NSView {
    weak var controller: WheelController?

    private var files: [URL] = []
    private var center = NSPoint.zero
    private var items: [WheelItem] = []
    private var selected: Int?
    private var advanced = false
    private var keyboard = false
    private var didDrop = false
    private var hint = ""
    private var trackingArea: NSTrackingArea?

    private let innerRadius: CGFloat = 54
    private let outerRadius: CGFloat = 156
    private let gapDegrees: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func configure(files: [URL], center: NSPoint, keyboard: Bool, advanced: Bool) {
        self.files = files
        self.center = center
        self.keyboard = keyboard
        self.advanced = advanced
        self.selected = keyboard ? 0 : nil
        self.didDrop = false
        rebuildItems()
        clampCenter()
        if keyboard, trackingArea == nil {
            let ta = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(ta)
            trackingArea = ta
        }
        needsDisplay = true
    }

    func reset() {
        files = []
        items = []
        selected = nil
        needsDisplay = true
    }

    private func clampCenter() {
        let margin = outerRadius + 40
        center.x = max(margin, min(bounds.width - margin, center.x))
        center.y = max(margin + 20, min(bounds.height - margin, center.y))
    }

    private func rebuildItems() {
        if advanced {
            items = Tool.tools(for: files).map { WheelItem(id: $0.rawValue, label: $0.title, symbol: $0.symbol, description: $0.name) }
        } else {
            items = Formats.targets(for: files).map { WheelItem(id: $0, label: Formats.displayName($0).uppercased(), symbol: nil, description: "Convert to \(Formats.displayName($0))") }
        }
        if let s = selected, s >= items.count { selected = items.isEmpty ? nil : 0 }
        updateHint()
    }

    private func updateHint() {
        if items.isEmpty {
            hint = advanced ? "No tools for this selection" : "No conversions for this selection"
        } else if let s = selected {
            hint = (keyboard ? "Press Return to " : "Let go to ") + items[s].description.lowercased()
        } else {
            hint = advanced ? "Drop onto a tool" : "Drop onto a new format. Add Option for advanced tools."
        }
    }

    // MARK: geometry

    private var step: CGFloat { items.isEmpty ? 360 : 360 / CGFloat(items.count) }

    private func index(for point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let dist = hypot(dx, dy)
        guard dist > innerRadius * 0.85, dist < outerRadius + 70 else { return nil }
        var theta = atan2(dx, dy) * 180 / .pi  // 0 at top, clockwise positive
        if theta < 0 { theta += 360 }
        return Int((theta / step).rounded()) % items.count
    }

    private func setAdvanced(_ on: Bool) {
        guard on != advanced else { return }
        advanced = on
        rebuildItems()
        needsDisplay = true
    }

    private func updateSelection(at point: NSPoint) {
        let idx = index(for: point)
        if idx != selected {
            selected = idx
            updateHint()
            needsDisplay = true
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !files.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        let backdrop = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius - 10, y: center.y - outerRadius - 10, width: (outerRadius + 10) * 2, height: (outerRadius + 10) * 2))
        (advanced ? NSColor(calibratedWhite: 0.93, alpha: 0.72) : NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.86, alpha: 0.72)).setFill()
        backdrop.fill()
        NSGraphicsContext.restoreGraphicsState()

        let dense = items.count > 6
        for (i, item) in items.enumerated() {
            let isSel = i == selected
            let path = petalPath(index: i)
            let base: NSColor = advanced ? NSColor(calibratedWhite: 0.99, alpha: 0.96) : NSColor(calibratedRed: 1, green: 0.95, blue: 0.9, alpha: 0.96)
            (isSel ? NSColor.controlAccentColor : base).setFill()
            path.fill()
            let angle = petalCenterAngle(index: i)
            let labelR = innerRadius + (outerRadius - innerRadius) * 0.56
            let p = NSPoint(x: center.x + cos(angle) * labelR, y: center.y + sin(angle) * labelR)
            let color: NSColor = isSel ? .white : .black
            let font = NSFont.systemFont(ofSize: dense ? 11 : 13, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: 0.6]
            let size = (item.label as NSString).size(withAttributes: attrs)
            var textY = p.y - size.height / 2
            if let symbol = item.symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: dense ? 15 : 18, weight: .medium)
                let icon = img.withSymbolConfiguration(cfg)!
                let tinted = tint(icon, color)
                let s = tinted.size
                tinted.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
                textY = p.y - size.height + 2
            }
            (item.label as NSString).draw(at: NSPoint(x: p.x - size.width / 2, y: textY), withAttributes: attrs)
        }

        // Centre: file icon and size.
        let icon = NSWorkspace.shared.icon(forFile: files[0].path)
        icon.draw(in: NSRect(x: center.x - 24, y: center.y - 14, width: 48, height: 48))
        let sizeText = totalSizeText()
        let sattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.8)]
        let ss = (sizeText as NSString).size(withAttributes: sattrs)
        let pill = NSRect(x: center.x - ss.width / 2 - 6, y: center.y - 34, width: ss.width + 12, height: ss.height + 4)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (sizeText as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: sattrs)

        // Hint below the wheel.
        let hattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let hs = (hint as NSString).size(withAttributes: hattrs)
        let hr = NSRect(x: center.x - hs.width / 2 - 10, y: center.y - outerRadius - 40, width: hs.width + 20, height: hs.height + 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: hr, xRadius: 8, yRadius: 8).fill()
        (hint as NSString).draw(at: NSPoint(x: hr.minX + 10, y: hr.minY + 4), withAttributes: hattrs)
    }

    private func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        color.set()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private func totalSizeText() -> String {
        let bytes = files.reduce(Int64(0)) { acc, url in
            acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return files.count > 1 ? "\(files.count) files · \(text)" : text
    }

    /// Angle in radians (standard math orientation) of petal i's centre.
    private func petalCenterAngle(index i: Int) -> CGFloat {
        (90 - CGFloat(i) * step) * .pi / 180
    }

    private func petalPath(index i: Int) -> NSBezierPath {
        let centerDeg = 90 - CGFloat(i) * step
        let half = step / 2
        let gap = items.count == 1 ? 0 : gapDegrees
        let start = centerDeg + half - gap / 2   // counterclockwise edge
        let end = centerDeg - half + gap / 2     // clockwise edge
        let path = NSBezierPath()
        let inner = innerRadius + 6, outer = outerRadius
        if items.count == 1 {
            path.appendOval(in: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.appendOval(in: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            path.windingRule = .evenOdd
            return path
        }
        // Widen the gap slightly on the inner ring so the spokes look uniform.
        let innerGapExtra = gap * (outer / inner - 1) / 2
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: inner, startAngle: end + innerGapExtra, endAngle: start - innerGapExtra, clockwise: false)
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    // MARK: drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if files.isEmpty {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            files = urls.filter { Formats.isSupported($0) }
            rebuildItems()
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let flags = NSEvent.modifierFlags
        guard flags.contains(.shift) else {
            controller?.hide()
            return []
        }
        setAdvanced(flags.contains(.option))
        updateSelection(at: convert(sender.draggingLocation, from: nil))
        return selected == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        selected = nil
        updateHint()
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { selected != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = selected, s < items.count else { return false }
        didDrop = true
        let item = items[s]
        let files = self.files
        let adv = advanced
        DispatchQueue.main.async {
            Actions.perform(files: files, itemID: item.id, advanced: adv)
        }
        controller?.hide()
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if !keyboard { controller?.hide() }
    }

    // MARK: keyboard mode

    override func keyDown(with event: NSEvent) {
        guard keyboard else { return }
        switch event.keyCode {
        case 53: controller?.hide()                        // Escape
        case 36, 76: apply()                               // Return / Enter
        case 123, 126: move(-1)                            // Left / Up
        case 124, 125: move(1)                             // Right / Down
        case 48: setAdvanced(!advanced)                    // Tab toggles tools
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard keyboard else { return }
        setAdvanced(event.modifierFlags.contains(.option))
        updateHint()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard keyboard else { return }
        if let idx = index(for: convert(event.locationInWindow, from: nil)) { selected = idx; updateHint(); needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard keyboard else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let idx = index(for: p) { selected = idx; apply() } else if hypot(p.x - center.x, p.y - center.y) > outerRadius + 20 { controller?.hide() }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = ((selected ?? 0) + delta + items.count) % items.count
        updateHint()
        needsDisplay = true
    }

    private func apply() {
        guard let s = selected, s < items.count else { return }
        let item = items[s], files = self.files, adv = advanced
        controller?.hide()
        Actions.perform(files: files, itemID: item.id, advanced: adv)
    }
}

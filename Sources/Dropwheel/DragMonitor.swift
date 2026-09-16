import AppKit

/// Watches the system drag pasteboard and shows the wheel when files are Shift-dragged.
/// Uses only public, permission-free APIs: the drag pasteboard, pressed mouse buttons and modifier flags.
final class DragMonitor {
    static let shared = DragMonitor()

    private var timer: Timer?
    private var idleChangeCount = NSPasteboard(name: .drag).changeCount
    private var currentDragCount: Int?
    private var dragFiles: [URL] = []
    private var eventMonitor: Any?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let wheel = WheelController.shared

        guard buttonDown else {
            if currentDragCount != nil {
                currentDragCount = nil
                dragFiles = []
                // The drop, if any, is delivered right after mouse-up; give it a moment before hiding.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if wheel.isVisible, !wheel.keyboardMode, NSEvent.pressedMouseButtons & 1 == 0 { wheel.hide() }
                }
            }
            idleChangeCount = pb.changeCount
            return
        }
        guard Settings.enabled, pb.changeCount != idleChangeCount else { return }
        if currentDragCount != pb.changeCount {
            currentDragCount = pb.changeCount
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            dragFiles = urls.filter { Formats.isSupported($0) }
        }
        guard !dragFiles.isEmpty, !wheel.keyboardMode else { return }
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, !wheel.isVisible {
            wheel.show(files: dragFiles, at: NSEvent.mouseLocation, keyboard: false)
        } else if !shift, wheel.isVisible {
            wheel.hide()
        }
    }
}

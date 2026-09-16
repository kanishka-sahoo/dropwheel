import AppKit
import Carbon

// Entry point. `--convert <file> <target>` and `--tool <tool> <files...>` run headless for testing.
let cliArgs = CommandLine.arguments
if cliArgs.count >= 3, cliArgs[1] == "--convert" || cliArgs[1] == "--tool" {
    CLI.run(cliArgs)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var welcome: WelcomeWindow?
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "Dropwheel")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
        DragMonitor.shared.start()
        registerHotKey()
        if !Settings.hasSeenWelcome { showWelcome() }
        if let i = cliArgs.firstIndex(of: "--wheel"), i + 1 < cliArgs.count {
            let files = cliArgs[(i + 1)...].map { URL(fileURLWithPath: $0) }.filter { Formats.isSupported($0) }
            let advanced = cliArgs.contains("--tools")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if advanced { WheelController.shared.showForcingAdvanced = true }
                WheelController.shared.show(files: files, at: NSEvent.mouseLocation, keyboard: true)
            }
        }
        if Binaries.ffmpeg == nil {
            NSLog("ffmpeg not found; audio/video features are disabled until it is installed")
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let enabled = NSMenuItem(title: "Enable Shift-Drag Wheel", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.state = Settings.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(NSMenuItem(title: "Convert Finder Selection…   ⌃⌥⌘C", action: #selector(convertFinderSelection), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: ""))
        menu.addItem(.separator())
        let info = NSMenuItem(title: "\(Formats.totalConversionOptions) conversions · \(Tool.allCases.count) tools · all local", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        if Binaries.ffmpeg == nil {
            let warn = NSMenuItem(title: "⚠︎ ffmpeg not found (brew install ffmpeg)", action: #selector(openSettings), keyEquivalent: "")
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "How It Works", action: #selector(showWelcome), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dropwheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        return menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        Settings.enabled.toggle()
        sender.state = Settings.enabled ? .on : .off
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
        settingsWindow?.show()
    }

    @objc func showWelcome() {
        if welcome == nil { welcome = WelcomeWindow() }
        welcome?.show()
        Settings.hasSeenWelcome = true
    }

    @objc func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to convert. The wheel opens at the pointer; use arrow keys or the mouse, hold Option for tools."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let files = panel.urls.filter { Formats.isSupported($0) }
            guard !files.isEmpty else { return }
            WheelController.shared.show(files: files, at: NSEvent.mouseLocation, keyboard: true)
        }
    }

    @objc func convertFinderSelection() {
        let script = """
        tell application "Finder"
            set sel to selection as alias list
            set out to {}
            repeat with f in sel
                set end of out to POSIX path of f
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            let alert = NSAlert()
            alert.messageText = "Could not read the Finder selection"
            alert.informativeText = (error?["NSAppleScriptErrorMessage"] as? String) ?? "Allow Dropwheel to control Finder in System Settings → Privacy & Security → Automation."
            alert.runModal()
            return
        }
        var files: [URL] = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let path = result.atIndex(i)?.stringValue { files.append(URL(fileURLWithPath: path)) }
            }
        } else if let path = result.stringValue, !path.isEmpty {
            files.append(URL(fileURLWithPath: path))
        }
        files = files.filter { Formats.isSupported($0) }
        guard !files.isEmpty else { NSSound.beep(); return }
        WheelController.shared.show(files: files, at: NSEvent.mouseLocation, keyboard: true)
    }

    /// ⌃⌥⌘C opens the wheel for the current Finder selection (Carbon hot keys need no extra permission).
    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                if WheelController.shared.isVisible { WheelController.shared.hide() }
                else { (NSApp.delegate as? AppDelegate)?.convertFinderSelection() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x44434E56), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey | cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// First-run explainer.
final class WelcomeWindow: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dropwheel"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        let title = NSTextField(labelWithString: "The zero-click offline file converter")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(title)
        func row(_ symbol: String, _ head: String, _ body: String) {
            let h = NSStackView()
            h.spacing = 10
            h.alignment = .top
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let t = NSTextField(wrappingLabelWithString: "")
            let a = NSMutableAttributedString(string: head + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            a.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
            t.attributedStringValue = a
            t.preferredMaxLayoutWidth = 360
            h.addArrangedSubview(icon)
            h.addArrangedSubview(t)
            stack.addArrangedSubview(h)
        }
        row("shift", "Hold Shift while dragging a file", "A wheel of output formats appears at the pointer. Drop the file onto a format to convert it. The result is saved beside the original.")
        row("option", "Add Option for advanced tools", "Compress, crop, trim, split, merge, redact, edit metadata and more, depending on the file type.")
        row("keyboard", "Or use the keyboard", "Select files in Finder and press ⌃⌥⌘C. Arrow keys choose, Return applies, Option switches to tools, Escape cancels.")
        row("lock.shield", "Everything runs on your Mac", "Nothing is uploaded. Audio and video use the ffmpeg you have installed with Homebrew.")
        let ok = NSButton(title: "Got it", target: self, action: #selector(closeWindow))
        ok.keyEquivalent = "\r"
        stack.addArrangedSubview(ok)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    @objc private func closeWindow() { window?.close() }
}

final class SettingsWindow: NSWindowController {
    private let ffmpegField = NSTextField()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dropwheel Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let grid = NSGridView()
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }

        let strength = NSPopUpButton()
        strength.addItems(withTitles: ["Balanced", "Strong"])
        strength.selectItem(at: Settings.compression.rawValue)
        strength.target = self; strength.action = #selector(strengthChanged)
        let resize = NSPopUpButton()
        resize.addItems(withTitles: ["Keep original size", "Limit to 4096 px", "Limit to 2048 px", "Limit to 1280 px", "Limit to 1920 px"])
        let dims = [0, 4096, 2048, 1280, 1920]
        resize.selectItem(at: dims.firstIndex(of: Settings.compressMaxDimension) ?? 0)
        resize.target = self; resize.action = #selector(resizeChanged)
        let reveal = NSButton(checkboxWithTitle: "Reveal results in Finder when done", target: self, action: #selector(revealChanged))
        reveal.state = Settings.revealResults ? .on : .off
        let sounds = NSButton(checkboxWithTitle: "Play a sound when a job finishes", target: self, action: #selector(soundsChanged))
        sounds.state = Settings.playSounds ? .on : .off
        let login = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(loginChanged))
        login.state = Settings.launchAtLogin ? .on : .off
        ffmpegField.placeholderString = Binaries.ffmpeg ?? "/opt/homebrew/bin/ffmpeg"
        ffmpegField.stringValue = Settings.ffmpegPath ?? ""
        ffmpegField.target = self; ffmpegField.action = #selector(ffmpegChanged)
        ffmpegField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        grid.addRow(with: [label("Compression:"), strength])
        grid.addRow(with: [label("Resize when compressing:"), resize])
        grid.addRow(with: [NSGridCell.emptyContentView, reveal])
        grid.addRow(with: [NSGridCell.emptyContentView, sounds])
        grid.addRow(with: [NSGridCell.emptyContentView, login])
        grid.addRow(with: [label("ffmpeg path:"), ffmpegField])
        let note = NSTextField(wrappingLabelWithString: "Audio, video, WebP and AVIF need ffmpeg. Install with: brew install ffmpeg")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        grid.addRow(with: [NSGridCell.emptyContentView, note])
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 460, height: grid.fittingSize.height + 40))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    @objc private func strengthChanged(_ s: NSPopUpButton) { Settings.compression = .init(rawValue: s.indexOfSelectedItem) ?? .balanced }
    @objc private func resizeChanged(_ s: NSPopUpButton) { Settings.compressMaxDimension = [0, 4096, 2048, 1280, 1920][s.indexOfSelectedItem] }
    @objc private func revealChanged(_ b: NSButton) { Settings.revealResults = b.state == .on }
    @objc private func soundsChanged(_ b: NSButton) { Settings.playSounds = b.state == .on }
    @objc private func loginChanged(_ b: NSButton) { Settings.launchAtLogin = b.state == .on }
    @objc private func ffmpegChanged() { Settings.ffmpegPath = ffmpegField.stringValue.isEmpty ? nil : ffmpegField.stringValue }
}

/// Headless mode used by the test script.
enum CLI {
    static func run(_ args: [String]) {
        let files = Array(args[3...]).map { URL(fileURLWithPath: $0) }
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        let job = Job(title: "cli", fileName: "")
        DispatchQueue.global().async {
            do {
                let outputs: [URL]
                if args[1] == "--convert" {
                    outputs = try Actions.convert(files: [URL(fileURLWithPath: args[2])], target: args[3], job: job)
                } else {
                    guard let tool = Tool(rawValue: args[2]) else { throw ConvError.unsupported("Unknown tool \(args[2])") }
                    outputs = try Actions.runHeadless(tool: tool, files: files, job: job)
                }
                for o in outputs { print(o.path) }
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exitCode = 1
            }
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        exit(exitCode)
    }
}

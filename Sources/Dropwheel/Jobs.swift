import AppKit

/// A unit of background work shown in the progress panel.
final class Job {
    let id = UUID()
    let title: String
    let fileName: String
    /// 0...1, or negative for indeterminate.
    var progress: Double = -1 {
        didSet { DispatchQueue.main.async { JobCenter.shared.refresh() } }
    }
    private(set) var isCancelled = false
    var process: Process?
    var status: String?
    var failed = false
    var finished = false

    init(title: String, fileName: String) {
        self.title = title
        self.fileName = fileName
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    func checkCancelled() throws {
        if isCancelled { throw ConvError.cancelled }
    }
}

/// Runs jobs on a background queue and keeps the progress panel in sync.
final class JobCenter {
    static let shared = JobCenter()
    private(set) var jobs: [Job] = []
    private let queue = OperationQueue()
    private lazy var panel = ProgressPanel()

    private init() {
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    /// Schedules `work`; the returned URLs are the produced files (used to reveal/bounce results).
    func run(title: String, fileName: String, work: @escaping (Job) throws -> [URL]) {
        let job = Job(title: title, fileName: fileName)
        jobs.append(job)
        refresh()
        queue.addOperation {
            var outputs: [URL] = []
            var error: Error?
            do { outputs = try work(job) } catch let e { error = e }
            DispatchQueue.main.async {
                job.finished = true
                if let error {
                    if case ConvError.cancelled = error {
                        self.remove(job)
                        return
                    }
                    job.failed = true
                    job.status = error.localizedDescription
                    self.refresh()
                    if Settings.playSounds { NSSound(named: "Basso")?.play() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.remove(job) }
                } else {
                    job.progress = 1
                    job.status = "Done"
                    self.refresh()
                    if Settings.playSounds { NSSound(named: "Glass")?.play() }
                    if Settings.revealResults, !outputs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.remove(job) }
                }
            }
        }
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0 === job }
        refresh()
    }

    func refresh() {
        panel.update(jobs: jobs)
    }
}

/// Floating panel in the bottom-right corner listing running jobs.
final class ProgressPanel: NSPanel {
    private let stack = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        contentView = effect
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    func update(jobs: [Job]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !jobs.isEmpty else { orderOut(nil); return }
        for job in jobs {
            let row = JobRowView(job: job)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        layoutIfNeeded()
        let height = stack.fittingSize.height
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.visibleFrame.maxX - 380 - 20, y: screen.visibleFrame.minY + 20, width: 380, height: height)
        setFrame(frame, display: true)
        if !isVisible { orderFrontRegardless() }
    }
}

final class JobRowView: NSView {
    private let job: Job

    init(job: Job) {
        self.job = job
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(image: NSImage(systemSymbolName: job.finished ? (job.failed ? "exclamationmark.circle" : "checkmark.circle.fill") : "xmark.circle.fill", accessibilityDescription: "Cancel")!, target: self, action: #selector(cancelTapped))
        cancel.isBordered = false
        cancel.contentTintColor = job.failed ? .systemRed : (job.finished ? .systemGreen : .secondaryLabelColor)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: job.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let sub = NSTextField(labelWithString: job.status ?? job.fileName)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = job.failed ? .systemRed : .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        sub.maximumNumberOfLines = job.failed ? 3 : 1
        sub.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = job.progress < 0 && !job.finished
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = max(0, job.progress)
        if bar.isIndeterminate { bar.startAnimation(nil) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = job.failed
        addSubview(cancel); addSubview(title); addSubview(sub); addSubview(bar)
        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: leadingAnchor),
            cancel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            cancel.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: cancel.trailingAnchor, constant: 6),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: job.failed ? -10 : -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func cancelTapped() {
        if job.finished { JobCenter.shared.remove(job) } else { job.cancel() }
    }
}

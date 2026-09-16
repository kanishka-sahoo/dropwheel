import Foundation

enum ConvError: LocalizedError {
    case missingTool(String)
    case failed(String)
    case unsupported(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTool(let t): return "\(t) is not installed. Install it with Homebrew (brew install \(t)) or set its path in Dropwheel Settings."
        case .failed(let m): return m
        case .unsupported(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

/// Locates command-line helpers used for audio, video and archives.
enum Binaries {
    private static func find(_ name: String, override: String? = nil) -> String? {
        var candidates: [String] = []
        if let o = override, !o.isEmpty {
            candidates.append(o)
            candidates.append((o as NSString).deletingLastPathComponent + "/" + name)
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)"]
        for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(path)/\(name)")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpeg: String? { find("ffmpeg", override: Settings.ffmpegPath) }
    static var ffprobe: String? { find("ffprobe", override: Settings.ffmpegPath) }
    static var bsdtar: String { find("bsdtar") ?? "/usr/bin/bsdtar" }
    static var zip: String { find("zip") ?? "/usr/bin/zip" }
    static var cwebp: String? { find("cwebp") }

    static func requireFFmpeg() throws -> String {
        guard let p = ffmpeg else { throw ConvError.missingTool("ffmpeg") }
        return p
    }
    static func requireFFprobe() throws -> String {
        guard let p = ffprobe else { throw ConvError.missingTool("ffmpeg") }
        return p
    }

    private static var encoderCache: Set<String>?
    /// Names of encoders supported by the installed ffmpeg.
    static func ffmpegEncoders() -> Set<String> {
        if let c = encoderCache { return c }
        guard let ff = ffmpeg, let out = try? Shell.run(ff, ["-hide_banner", "-encoders"]).stdout else { return [] }
        var set = Set<String>()
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { set.insert(String(parts[1])) }
        }
        encoderCache = set
        return set
    }
}

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum Shell {
    /// Runs a process synchronously. If `job` is given the process can be cancelled and,
    /// for ffmpeg-style `-progress pipe:1` output, progress is reported against `duration`.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], job: Job? = nil, duration: Double? = nil,
                    stdin: Data? = nil) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        var outData = Data()
        let outGroup = DispatchGroup()
        outGroup.enter()
        DispatchQueue.global().async {
            if let job, let duration, duration > 0 {
                var buffer = ""
                while true {
                    let chunk = out.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    outData.append(chunk)
                    buffer += String(decoding: chunk, as: UTF8.self)
                    var lines = buffer.components(separatedBy: "\n")
                    buffer = lines.removeLast()
                    for line in lines where line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                        if let us = Double(line.split(separator: "=").last ?? "") {
                            job.progress = min(0.99, us / 1_000_000 / duration)
                        }
                    }
                }
            } else {
                outData = out.fileHandleForReading.readDataToEndOfFile()
            }
            outGroup.leave()
        }
        try p.run()
        job?.process = p
        p.waitUntilExit()
        job?.process = nil
        outGroup.wait()
        errGroup.wait()
        if let job, job.isCancelled { throw ConvError.cancelled }
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs ffmpeg with progress reporting, throwing a readable error on failure.
    static func ffmpeg(_ args: [String], job: Job? = nil, duration: Double? = nil) throws {
        let ff = try Binaries.requireFFmpeg()
        var full = ["-hide_banner", "-y", "-nostdin"]
        if job != nil { full += ["-progress", "pipe:1", "-nostats", "-loglevel", "error"] } else { full += ["-loglevel", "error"] }
        full += args
        let r = try run(ff, full, job: job, duration: duration)
        if r.status != 0 {
            let tail = r.stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw ConvError.failed(tail.isEmpty ? "ffmpeg failed (\(r.status))" : tail)
        }
    }

    /// Media information from ffprobe.
    struct MediaInfo {
        var duration: Double = 0
        var width: Int = 0
        var height: Int = 0
        var hasAudio = false
        var hasVideo = false
        var audioChannels = 0
        var fps: Double = 30
        var tags: [String: String] = [:]
        var sampleRate: Int = 44100
        /// Per-stream tags, keyed like "Track 1 (audio): title".
        var streamTags: [(String, String)] = []
        var chapters: [(String, String)] = []
    }

    static func probe(_ url: URL) throws -> MediaInfo {
        let fp = try Binaries.requireFFprobe()
        let r = try run(fp, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        guard let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvError.failed("Could not read media information for \(url.lastPathComponent)")
        }
        var info = MediaInfo()
        if let format = json["format"] as? [String: Any] {
            info.duration = Double(format["duration"] as? String ?? "") ?? 0
            if let tags = format["tags"] as? [String: Any] {
                for (k, v) in tags { info.tags[k] = "\(v)" }
            }
        }
        for (idx, ch) in (json["chapters"] as? [[String: Any]] ?? []).enumerated() {
            let title = ((ch["tags"] as? [String: Any])?["title"]).map { "\($0)" } ?? ""
            let start = Double(ch["start_time"] as? String ?? "") ?? 0
            info.chapters.append(("Chapter \(idx + 1) @ \(String(format: "%.1f", start))s", title))
        }
        for (idx, s) in (json["streams"] as? [[String: Any]] ?? []).enumerated() {
            let type = s["codec_type"] as? String
            for (k, v) in (s["tags"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                info.streamTags.append(("Track \(idx + 1) (\(type ?? "stream")): \(k)", "\(v)"))
            }
            if type == "video", (s["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 {
                info.hasVideo = true
                info.width = s["width"] as? Int ?? 0
                info.height = s["height"] as? Int ?? 0
                if let r = s["r_frame_rate"] as? String {
                    let parts = r.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0 { info.fps = parts[0] / parts[1] } else if parts.count == 1 { info.fps = parts[0] }
                }
                if info.duration == 0, let d = Double(s["duration"] as? String ?? "") { info.duration = d }
            } else if type == "audio" {
                info.hasAudio = true
                info.audioChannels = s["channels"] as? Int ?? 2
                info.sampleRate = Int(s["sample_rate"] as? String ?? "") ?? 44100
                if info.duration == 0, let d = Double(s["duration"] as? String ?? "") { info.duration = d }
            }
        }
        return info
    }
}

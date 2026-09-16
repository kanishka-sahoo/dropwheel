import AppKit
import AVFoundation

/// Audio and video conversion and tools, all driven by ffmpeg.
enum MediaConvert {
    static func audioArgs(for kind: String, compress: Bool = false) -> [String] {
        switch kind {
        case "mp3": return ["-c:a", "libmp3lame"] + (compress ? ["-b:a", "96k"] : ["-q:a", "2"])
        case "m4a": return ["-c:a", "aac", "-b:a", compress ? "96k" : "192k"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac", "-compression_level", compress ? "12" : "5"]
        case "ogg":
            if Binaries.ffmpegEncoders().contains("libvorbis") { return ["-c:a", "libvorbis", "-q:a", compress ? "2" : "5"] }
            return ["-c:a", "vorbis", "-strict", "-2", "-sample_fmt", "fltp", "-ac", "2", "-b:a", compress ? "96k" : "160k"]
        case "opus":
            if Binaries.ffmpegEncoders().contains("libopus") { return ["-c:a", "libopus", "-b:a", compress ? "64k" : "128k"] }
            return ["-c:a", "opus", "-strict", "-2", "-b:a", compress ? "64k" : "128k"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        case "wma": return ["-c:a", "wmav2", "-b:a", compress ? "96k" : "192k"]
        default: return ["-c:a", "aac", "-b:a", "160k"]
        }
    }

    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Encoder settings for a video container. `filters` is prepended to the scale filter.
    static func videoArgs(for kind: String, crf: Int = 20, extraFilters: [String] = []) -> [String] {
        let vf = (extraFilters + [evenScale]).joined(separator: ",")
        switch kind {
        case "mp4", "mov", "mkv":
            return ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "\(crf)", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"] + (kind == "mkv" ? [] : ["-movflags", "+faststart"])
        case "webm":
            return ["-vf", vf, "-c:v", "libvpx-vp9", "-crf", "\(crf + 12)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return ["-vf", vf, "-c:v", "mpeg4", "-q:v", "\(max(2, crf / 5))", "-c:a", "libmp3lame", "-b:a", "160k"]
        case "wmv":
            return ["-vf", vf, "-c:v", "wmv2", "-b:v", crf > 24 ? "2M" : "4M", "-c:a", "wmav2", "-b:a", "160k"]
        default:
            return ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "\(crf)", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        }
    }

    static func convert(_ url: URL, to target: String, job: Job?) throws -> URL {
        let info = try Shell.probe(url)
        let out = Naming.output(beside: url, ext: target)
        var args = ["-i", url.path]
        if Formats.audio.contains(target) {
            args += ["-vn", "-map_metadata", "0"] + audioArgs(for: target)
        } else if target == "gif" {
            let fps = min(15, max(5, Int(info.fps.rounded())))
            args += ["-an", "-vf", "fps=\(fps),scale='min(720,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5", "-loop", "0"]
        } else {
            args += ["-map_metadata", "0"] + videoArgs(for: target)
            if !info.hasAudio { args += ["-an"] }
        }
        args.append(out.path)
        try Shell.ffmpeg(args, job: job, duration: info.duration)
        return out
    }

    static func compress(_ url: URL, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let info = try Shell.probe(url)
        let strong = Settings.compression == .strong
        if Formats.audio.contains(kind) {
            let outKind = kind == "wav" || kind == "aiff" ? "flac" : kind
            let out = Naming.output(beside: url, suffix: "Compressed", ext: outKind)
            try Shell.ffmpeg(["-i", url.path, "-vn", "-map_metadata", "0"] + audioArgs(for: outKind, compress: true) + [out.path], job: job, duration: info.duration)
            return out
        }
        let out = Naming.output(beside: url, suffix: "Compressed", ext: kind)
        var filters: [String] = []
        var maxDim = Settings.compressMaxDimension
        if strong, maxDim == 0 { maxDim = 1280 }
        if maxDim > 0, max(info.width, info.height) > maxDim {
            filters.append("scale='if(gt(iw,ih),min(\(maxDim),iw),-2)':'if(gt(iw,ih),-2,min(\(maxDim),ih))'")
        }
        var args = ["-i", url.path, "-map_metadata", "0"] + videoArgs(for: kind, crf: strong ? 30 : 26, extraFilters: filters)
        if !info.hasAudio { args += ["-an"] }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration)
        return out
    }

    static func stripMetadata(_ url: URL, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "No Metadata", ext: kind)
        let info = try Shell.probe(url)
        try Shell.ffmpeg(["-i", url.path, "-map_metadata", "-1", "-map_chapters", "-1", "-map", "0", "-c", "copy", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", out.path], job: job, duration: info.duration)
        return out
    }

    /// Writes tags. Passing an empty dictionary clears everything.
    static func writeMetadata(_ url: URL, tags: [String: String], job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Tagged", ext: kind)
        let info = try Shell.probe(url)
        var args = ["-i", url.path, "-map", "0", "-c", "copy", "-map_metadata", "-1"]
        for (k, v) in tags where !v.isEmpty { args += ["-metadata", "\(k)=\(v)"] }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration)
        return out
    }

    static func normalize(_ url: URL, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Normalized", ext: kind)
        let info = try Shell.probe(url)
        var args = ["-i", url.path, "-map_metadata", "0", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
        if Formats.audio.contains(kind) { args += ["-vn"] + audioArgs(for: kind) } else { args += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration)
        return out
    }

    enum ChannelMode: Int, CaseIterable {
        case mono = 0, stereo, leftOnly, rightOnly, swap
        var name: String { ["Mono (mix both channels)", "Stereo (duplicate if mono)", "Left channel to both", "Right channel to both", "Swap left and right"][rawValue] }
        var suffix: String { ["Mono", "Stereo", "Left", "Right", "Swapped"][rawValue] }
    }

    static func channels(_ url: URL, mode: ChannelMode, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: mode.suffix, ext: kind)
        let info = try Shell.probe(url)
        var args = ["-i", url.path, "-map_metadata", "0", "-vn"]
        switch mode {
        case .mono: args += ["-ac", "1"]
        case .stereo: args += ["-ac", "2"]
        case .leftOnly: args += ["-af", "pan=stereo|c0=c0|c1=c0"]
        case .rightOnly: args += ["-af", "pan=stereo|c0=c1|c1=c1"]
        case .swap: args += ["-af", "pan=stereo|c0=c1|c1=c0"]
        }
        try Shell.ffmpeg(args + audioArgs(for: kind) + [out.path], job: job, duration: info.duration)
        return out
    }

    static func mute(_ url: URL, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Muted", ext: kind)
        let info = try Shell.probe(url)
        try Shell.ffmpeg(["-i", url.path, "-map_metadata", "0", "-c:v", "copy", "-an", out.path], job: job, duration: info.duration)
        return out
    }

    static func trim(_ url: URL, start: Double, end: Double, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Trimmed", ext: kind)
        let info = try Shell.probe(url)
        var args = ["-ss", "\(start)", "-to", "\(end)", "-i", url.path, "-map_metadata", "0"]
        if Formats.audio.contains(kind) { args += ["-vn"] + audioArgs(for: kind) } else { args += videoArgs(for: kind); if !info.hasAudio { args += ["-an"] } }
        try Shell.ffmpeg(args + [out.path], job: job, duration: end - start)
        return out
    }

    /// Splits at the given timestamps into a folder of clips.
    static func split(_ url: URL, at points: [Double], job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let info = try Shell.probe(url)
        let folder = try Naming.folder(beside: url, suffix: "Clips")
        let bounds = [0] + points.sorted().filter { $0 > 0 && $0 < info.duration } + [info.duration]
        let base = Naming.baseName(of: url)
        for i in 0..<(bounds.count - 1) {
            try job?.checkCancelled()
            let out = folder.appendingPathComponent(String(format: "%@-%02d.%@", base, i + 1, kind))
            var args = ["-ss", "\(bounds[i])", "-to", "\(bounds[i + 1])", "-i", url.path, "-map_metadata", "0"] + videoArgs(for: kind)
            if !info.hasAudio { args += ["-an"] }
            let sub = Job(title: "", fileName: "")
            job?.process = nil
            try Shell.ffmpeg(args + [out.path], job: sub, duration: bounds[i + 1] - bounds[i])
            job?.progress = Double(i + 1) / Double(bounds.count - 1)
        }
        return folder
    }

    static func crop(_ url: URL, rect: CGRect, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Cropped", ext: kind)
        let info = try Shell.probe(url)
        let crop = "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"
        var args = ["-i", url.path, "-map_metadata", "0"] + videoArgs(for: kind, extraFilters: [crop])
        args = args.map { $0 == "-c:a" ? "-c:a" : $0 }
        if info.hasAudio { args += ["-c:a", "copy"] } else { args += ["-an"] }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration)
        return out
    }

    static func speed(_ url: URL, factor: Double, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let label = factor == factor.rounded() ? "\(Int(factor))x" : "\(factor)x"
        let out = Naming.output(beside: url, suffix: "Speed \(label)", ext: kind)
        let info = try Shell.probe(url)
        // atempo accepts 0.5...100 per stage; chain stages for slower speeds.
        var tempo: [String] = []
        var f = factor
        while f < 0.5 { tempo.append("atempo=0.5"); f /= 0.5 }
        tempo.append("atempo=\(f)")
        var args = ["-i", url.path, "-map_metadata", "0"]
        if info.hasAudio {
            args += ["-filter_complex", "[0:v]setpts=PTS/\(factor),\(evenScale)[v];[0:a]\(tempo.joined(separator: ","))[a]", "-map", "[v]", "-map", "[a]"]
        } else {
            args += ["-filter_complex", "[0:v]setpts=PTS/\(factor),\(evenScale)[v]", "-map", "[v]", "-an"]
        }
        args += videoArgs(for: kind).filter { $0 != "-vf" && $0 != evenScale }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration / factor)
        return out
    }

    /// Concatenates clips (scaled to the first clip's size) into one MP4.
    static func join(_ urls: [URL], job: Job?) throws -> URL {
        let infos = try urls.map { try Shell.probe($0) }
        guard let first = infos.first, first.width > 0 else { throw ConvError.failed("Could not read the first clip") }
        let out = Naming.output(beside: urls[0], suffix: "Joined", ext: "mp4")
        var args: [String] = []
        for url in urls { args += ["-i", url.path] }
        var chain = ""
        var maps = ""
        for (i, info) in infos.enumerated() {
            chain += "[\(i):v]scale=\(first.width):\(first.height):force_original_aspect_ratio=decrease,pad=\(first.width):\(first.height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(Int(first.fps.rounded()))[v\(i)];"
            if info.hasAudio {
                chain += "[\(i):a]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
            } else {
                chain += "anullsrc=r=48000:cl=stereo,atrim=duration=\(info.duration)[a\(i)];"
            }
            maps += "[v\(i)][a\(i)]"
        }
        chain += "\(maps)concat=n=\(urls.count):v=1:a=1[v][a]"
        args += ["-filter_complex", chain, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out.path]
        try Shell.ffmpeg(args, job: job, duration: infos.reduce(0) { $0 + $1.duration })
        return out
    }

    /// Full-resolution PNG frames at the given times.
    static func snapshots(_ url: URL, times: [Double], job: Job?) throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let base = Naming.baseName(of: url)
        var outputs: [URL] = []
        let dir: URL? = times.count > 1 ? try Naming.folder(beside: url, suffix: "Snapshots") : nil
        for (i, t) in times.enumerated() {
            try job?.checkCancelled()
            job?.progress = Double(i) / Double(times.count)
            let cg: CGImage
            if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                cg = img
            } else {
                let tmp = Naming.tempFile(ext: "png")
                try Shell.ffmpeg(["-ss", "\(t)", "-i", url.path, "-frames:v", "1", tmp.path])
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                cg = img
            }
            let stamp = String(format: "%02d-%02d-%02d", Int(t / 3600), Int(t / 60) % 60, Int(t) % 60)
            let out = dir.map { $0.appendingPathComponent("\(base) \(stamp).png") } ?? Naming.output(beside: url, suffix: "Snapshot \(stamp)", ext: "png")
            try ImageConvert.write(cg, to: out, kind: "png")
            outputs.append(out)
        }
        return dir.map { [$0] } ?? outputs
    }

    enum RedactStyle: Int { case solid = 0, blur = 1, pixelate = 2 }

    /// A rectangle (pixel coordinates, top-left origin) hidden for all of the video or only between `start` and `end`.
    struct Redaction {
        var rect: CGRect
        var start: Double? = nil
        var end: Double? = nil
    }

    /// Applies rectangular redactions to every frame, or only within each redaction's time range.
    static func redact(_ url: URL, redactions: [Redaction], style: RedactStyle, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Redacted", ext: kind)
        let info = try Shell.probe(url)
        var chain = "[0:v]\(evenScale)[base0];"
        for (i, red) in redactions.enumerated() {
            let r = red.rect
            let x = Int(r.minX), y = Int(r.minY), w = max(2, Int(r.width) / 2 * 2), h = max(2, Int(r.height) / 2 * 2)
            let inp = "[base\(i)]", outp = "[base\(i + 1)]"
            var enable = ""
            if red.start != nil || red.end != nil {
                enable = ":enable='between(t,\(red.start ?? 0),\(red.end ?? info.duration + 1))'"
            }
            switch style {
            case .solid:
                chain += "\(inp)drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill\(enable)\(outp);"
            case .blur:
                chain += "\(inp)split[s\(i)a][s\(i)b];[s\(i)b]crop=\(w):\(h):\(x):\(y),boxblur=luma_radius=min(h\\,w)/8:luma_power=3[bl\(i)];[s\(i)a][bl\(i)]overlay=\(x):\(y)\(enable)\(outp);"
            case .pixelate:
                chain += "\(inp)split[s\(i)a][s\(i)b];[s\(i)b]crop=\(w):\(h):\(x):\(y),scale=iw/16:ih/16:flags=area,scale=\(w):\(h):flags=neighbor[px\(i)];[s\(i)a][px\(i)]overlay=\(x):\(y)\(enable)\(outp);"
            }
        }
        let final = "[base\(redactions.count)]"
        chain = String(chain.dropLast())
        var args = ["-i", url.path, "-map_metadata", "0", "-filter_complex", chain, "-map", final]
        if info.hasAudio { args += ["-map", "0:a?", "-c:a", "copy"] } else { args += ["-an"] }
        args += videoArgs(for: kind).filter { $0 != "-vf" && $0 != evenScale }
        try Shell.ffmpeg(args + [out.path], job: job, duration: info.duration)
        return out
    }

    /// Replaces the given ranges with a 1 kHz tone.
    static func bleep(_ url: URL, ranges: [(Double, Double)], job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "Bleeped", ext: kind)
        let info = try Shell.probe(url)
        let enable = ranges.map { "between(t,\($0.0),\($0.1))" }.joined(separator: "+")
        let chain = "[0:a]volume=0:enable='\(enable)'[muted];sine=frequency=1000:sample_rate=\(info.sampleRate):duration=\(info.duration)[tone];[tone]volume=0.4:enable='\(enable)',volume=0:enable='not(\(enable))'[bleep];[muted][bleep]amix=inputs=2:duration=first:normalize=0[a]"
        try Shell.ffmpeg(["-i", url.path, "-map_metadata", "0", "-filter_complex", chain, "-map", "[a]", "-vn"] + audioArgs(for: kind) + [out.path], job: job, duration: info.duration)
        return out
    }

    enum VisualizerShape: Int { case landscape = 0, portrait = 1, square = 2
        var size: (Int, Int) { switch self { case .landscape: return (1920, 1080); case .portrait: return (1080, 1920); case .square: return (1080, 1080) } }
    }

    /// Renders a waveform video from an audio file, optionally over a static image.
    static func visualize(_ url: URL, shape: VisualizerShape, color: NSColor, image: URL?, job: Job?) throws -> URL {
        let out = Naming.output(beside: url, suffix: "Visualizer", ext: "mp4")
        let info = try Shell.probe(url)
        let (w, h) = shape.size
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let hex = String(format: "0x%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        var args = ["-i", url.path]
        var chain: String
        if let image {
            args += ["-loop", "1", "-framerate", "30", "-i", image.path]
            chain = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),format=rgba[bg];[0:a]showwaves=s=\(w)x\(h / 3):mode=cline:colors=\(hex)@0.9:rate=30:scale=sqrt[wave];[bg][wave]overlay=0:\(h - h / 3 - h / 12):shortest=1,format=yuv420p[v]"
        } else {
            chain = "color=c=black:s=\(w)x\(h):r=30[bg];[0:a]showwaves=s=\(w)x\(h / 2):mode=cline:colors=\(hex):rate=30:scale=sqrt[wave];[bg][wave]overlay=0:\(h / 4):shortest=1,format=yuv420p[v]"
        }
        args += ["-filter_complex", chain, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", "\(info.duration)", out.path]
        try Shell.ffmpeg(args, job: job, duration: info.duration)
        return out
    }

    // MARK: helpers for editor windows

    /// Mono peak amplitudes (0...1) in `buckets` equal slices of the file.
    static func waveform(_ url: URL, buckets: Int) -> [Float] {
        guard let ff = Binaries.ffmpeg else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-v", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let count = raw.count / 2
        guard count > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        raw.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let samples = ptr.bindMemory(to: Int16.self)
            let per = max(1, count / buckets)
            for b in 0..<buckets {
                var peak: Int16 = 0
                let start = b * per, end = min(count, start + per)
                var i = start
                while i < end { let v = abs(samples[i]); if v > peak { peak = v }; i += 1 }
                peaks[b] = Float(peak) / 32767
            }
        }
        return peaks
    }

    /// Detects leading/trailing silence, returning the trimmed range.
    static func silenceBounds(_ url: URL, duration: Double) -> (Double, Double)? {
        guard let ff = Binaries.ffmpeg,
              let r = try? Shell.run(ff, ["-hide_banner", "-i", url.path, "-af", "silencedetect=noise=-40dB:d=0.3", "-f", "null", "-"]) else { return nil }
        var starts: [Double] = [], ends: [Double] = []
        for line in r.stderr.split(separator: "\n") {
            if let range = line.range(of: "silence_start: ") { starts.append(Double(line[range.upperBound...].split(separator: " ")[0]) ?? 0) }
            if let range = line.range(of: "silence_end: ") { ends.append(Double(line[range.upperBound...].split(separator: " ")[0]) ?? 0) }
        }
        var s = 0.0, e = duration
        if let firstStart = starts.first, firstStart < 0.05, let firstEnd = ends.first { s = firstEnd }
        if let lastStart = starts.last, ends.count < starts.count || (ends.last ?? 0) >= duration - 0.05 { e = lastStart }
        return e > s ? (s, e) : nil
    }

    /// A URL AVPlayer can play: the original if supported, otherwise a temporary transcode.
    static func previewURL(_ url: URL, job: Job?) throws -> URL {
        let kind = Formats.kind(of: url)
        if ["mp3", "m4a", "wav", "aiff", "mp4", "mov"].contains(kind) { return url }
        let isAudio = Formats.audio.contains(kind)
        let tmp = Naming.tempFile(ext: isAudio ? "m4a" : "mp4")
        let info = try Shell.probe(url)
        var args = ["-i", url.path]
        if isAudio { args += ["-vn", "-c:a", "aac", "-b:a", "128k"] }
        else { args += ["-vf", "scale='min(1280,iw)':-2", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"] }
        try Shell.ffmpeg(args + [tmp.path], job: job, duration: info.duration)
        return tmp
    }

    /// First frame (or a frame at `time`) as a CGImage, for crop/redact editors.
    static func frame(_ url: URL, at time: Double = 0) throws -> CGImage {
        let tmp = Naming.tempFile(ext: "png")
        try Shell.ffmpeg(["-ss", "\(time)", "-i", url.path, "-frames:v", "1", tmp.path])
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvError.failed("Could not read a frame from \(url.lastPathComponent)")
        }
        return cg
    }
}

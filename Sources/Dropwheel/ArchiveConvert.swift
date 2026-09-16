import Foundation

/// ZIP/TAR/GZIP/RAR handling with bsdtar (libarchive). RAR is read-only.
enum ArchiveConvert {
    static func extract(_ url: URL, job: Job?) throws -> URL {
        let folder = try Naming.folder(beside: url, suffix: "Extracted")
        let r = try Shell.run(Binaries.bsdtar, ["-xf", url.path, "-C", folder.path], job: job)
        if r.status != 0 {
            try? FileManager.default.removeItem(at: folder)
            throw ConvError.failed("Could not extract \(url.lastPathComponent): \(r.stderr.split(separator: "\n").last ?? "")")
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("__MACOSX"))
        return folder
    }

    static func convert(_ url: URL, to target: String, job: Job?) throws -> URL {
        let tmp = try Naming.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let x = try Shell.run(Binaries.bsdtar, ["-xf", url.path, "-C", tmp.path], job: job)
        if x.status != 0 { throw ConvError.failed("Could not read \(url.lastPathComponent): \(x.stderr.split(separator: "\n").last ?? "")") }
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("__MACOSX"))
        let out = Naming.output(beside: url, ext: Formats.fileExtension(for: target))
        let entries = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { !$0.hasPrefix(".") }
        try job?.checkCancelled()
        if target == "rar" {
            try Rar.write(directory: tmp, to: out, job: job)
            return out
        }
        let format: [String]
        switch target {
        case "zip": format = ["--format", "zip"]
        case "tar": format = ["--format", "ustar"]
        case "gz": format = ["--format", "ustar", "--gzip"]
        default: throw ConvError.unsupported("Writing \(Formats.displayName(target)) archives is not supported")
        }
        let c = try Shell.run(Binaries.bsdtar, ["-cf", out.path] + format + ["--no-xattrs", "-C", tmp.path] + entries, job: job)
        if c.status != 0 { throw ConvError.failed("Could not create archive: \(c.stderr)") }
        return out
    }
}

import Foundation

/// Produces output locations beside the source that never overwrite existing files.
enum Naming {
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(name.dropLast(4)) }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `photo.jpg` + suffix "Compressed" + ext "jpg" → `photo Compressed.jpg` (or `photo Compressed 2.jpg`).
    static func output(beside source: URL, suffix: String? = nil, ext: String, directory: URL? = nil) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        let base = baseName(of: source) + (suffix.map { " \($0)" } ?? "")
        return unique(in: dir, base: base, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Creates a fresh folder beside the source for multi-file results.
    static func folder(beside source: URL, suffix: String) throws -> URL {
        let url = unique(in: source.deletingLastPathComponent(), base: baseName(of: source) + " " + suffix, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tempFile(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString).\(ext)")
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

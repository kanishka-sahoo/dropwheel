import Foundation

enum Category: String {
    case image, audio, video, document, subtitle, archive
}

/// Static knowledge about which file kinds exist and what they can become.
enum Formats {
    static let images = ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
    static let rasterImages = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp"]
    static let audio = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    static let video = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    static let archives = ["zip", "tar", "gz", "rar"]
    static let subtitles = ["srt", "vtt"]
    static let textDocuments = ["txt", "md", "html", "csv", "json", "code"]
    static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "java", "c", "h", "cpp", "hpp", "cc", "m", "mm", "go", "rs", "rb", "php", "sh", "zsh", "bash", "kt", "cs", "sql", "yaml", "yml", "toml", "xml", "css", "scss", "lua", "r", "pl", "dart", "scala", "ex", "exs", "hs", "ini", "conf", "plist"]

    /// Normalizes a URL's extension to one of the canonical keys used throughout the app.
    static func kind(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "gz" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpeg", "jpe", "jfif": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "m4v": return "mp4"
        case "aif", "aifc": return "aiff"
        case "oga": return "ogg"
        case "gzip": return "gz"
        case "webvtt": return "vtt"
        case "text", "log": return "txt"
        case "md", "markdown", "mdown", "mkd": return "md"
        case "htm", "html", "xhtml": return "html"
        case "csv", "tsv": return "csv"
        case _ where codeExtensions.contains(ext): return "code"
        default: return ext
        }
    }

    static func category(of kind: String) -> Category? {
        if images.contains(kind) { return .image }
        if audio.contains(kind) { return .audio }
        if video.contains(kind) || kind == "gif" { return .video }
        if ["pdf", "docx"].contains(kind) || textDocuments.contains(kind) { return .document }
        if subtitles.contains(kind) { return .subtitle }
        if archives.contains(kind) { return .archive }
        return nil
    }

    /// The output formats a single file of `kind` can be converted to.
    static func targets(for kind: String) -> [String] {
        switch kind {
        case "svg": return rasterImages + ["pdf", "docx"]
        case _ where rasterImages.contains(kind): return rasterImages.filter { $0 != kind } + ["pdf", "docx", "txt"]
        case _ where audio.contains(kind): return audio.filter { $0 != kind } + ["txt", "srt", "vtt"]
        case _ where video.contains(kind): return video.filter { $0 != kind } + ["gif", "mp3", "txt", "srt", "vtt"]
        case "gif": return video
        case "pdf": return ["docx", "jpg", "png", "txt"]
        case "docx": return ["pdf", "txt", "html", "md"]
        case "txt": return ["pdf", "jpg", "png", "docx", "html", "srt", "vtt"]
        case "md": return ["pdf", "jpg", "png", "docx", "html", "txt"]
        case "html": return ["pdf", "jpg", "png", "docx", "md", "txt"]
        case "csv": return ["pdf", "jpg", "png", "json", "html", "docx"]
        case "json": return ["csv", "pdf", "png"]
        case "code": return ["pdf", "jpg", "png", "html"]
        case "srt": return ["vtt", "txt"]
        case "vtt": return ["srt", "txt"]
        case _ where archives.contains(kind): return archives.filter { $0 != kind }
        default: return []
        }
    }

    /// Targets shared by every file in a multi-file drag, in the order of the first file.
    static func targets(for urls: [URL]) -> [String] {
        guard let first = urls.first else { return [] }
        var result = targets(for: kind(of: first))
        for url in urls.dropFirst() {
            let set = Set(targets(for: kind(of: url)))
            result = result.filter { set.contains($0) }
        }
        return result
    }

    static func displayName(_ kind: String) -> String {
        switch kind {
        case "gz": return "GZIP"
        case "webp": return "WebP"
        case "md": return "MD"
        case "code": return "Code"
        default: return kind.uppercased()
        }
    }

    /// File extension written for a target kind.
    static func fileExtension(for target: String) -> String {
        target == "gz" ? "tar.gz" : target
    }

    static func isSupported(_ url: URL) -> Bool {
        category(of: kind(of: url)) != nil
    }

    static let totalConversionOptions: Int = {
        let kinds = images + audio + video + ["gif", "pdf", "docx"] + textDocuments + subtitles + archives
        return kinds.reduce(0) { $0 + targets(for: $1).count }
    }()
}

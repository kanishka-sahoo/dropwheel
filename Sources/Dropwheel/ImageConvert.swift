import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Image loading, saving and conversion using ImageIO/CoreImage, with ffmpeg for WebP/AVIF encoding.
enum ImageConvert {
    /// Loads any supported image as a CGImage with EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        let kind = Formats.kind(of: url)
        if kind == "svg" {
            guard let img = NSImage(contentsOf: url) else { throw ConvError.failed("Could not read \(url.lastPathComponent)") }
            var size = img.size
            let scale = max(1, 2048 / max(size.width, size.height))
            size = NSSize(width: size.width * scale, height: size.height * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage else { throw ConvError.failed("Could not rasterize SVG") }
            return cg
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let orientation = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            return orientation == 1 ? cg : applyOrientation(cg, orientation)
        }
        // Fallback: let ffmpeg decode to PNG.
        let tmp = Naming.tempFile(ext: "png")
        try Shell.ffmpeg(["-i", url.path, "-frames:v", "1", tmp.path])
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvError.failed("Could not decode \(url.lastPathComponent)")
        }
        return cg
    }

    static func applyOrientation(_ cg: CGImage, _ orientation: UInt32) -> CGImage {
        let ci = CIImage(cgImage: cg).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        return render(ci) ?? cg
    }

    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func render(_ ci: CIImage) -> CGImage? {
        ciContext.createCGImage(ci, from: ci.extent.integral)
    }

    static func utType(for kind: String) -> UTType? {
        switch kind {
        case "jpg": return .jpeg
        case "png": return .png
        case "tiff": return .tiff
        case "heic": return .heic
        case "bmp": return .bmp
        case "gif": return .gif
        case "webp": return .webP
        default: return nil
        }
    }

    /// Writes a CGImage in the given format. `quality` applies to lossy formats (0...1).
    static func write(_ cg: CGImage, to url: URL, kind: String, quality: Double = 0.9, metadata: [CFString: Any]? = nil) throws {
        switch kind {
        case "webp":
            if let cwebp = Binaries.cwebp {
                let tmp = Naming.tempFile(ext: "png")
                try writeImageIO(cg, to: tmp, type: .png, quality: 1, metadata: nil)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let r = try Shell.run(cwebp, ["-quiet", "-q", "\(Int(quality * 100))", tmp.path, "-o", url.path])
                if r.status != 0 { throw ConvError.failed("WebP encoding failed: \(r.stderr)") }
            } else {
                try writeViaFFmpeg(cg, to: url, args: ["-c:v", "libwebp", "-quality", "\(Int(quality * 100))"])
            }
        case "avif":
            let enc = Binaries.ffmpegEncoders()
            let crf = "\(Int((1 - quality) * 50 + 8))"
            if enc.contains("libsvtav1") {
                try writeViaFFmpeg(cg, to: url, args: ["-c:v", "libsvtav1", "-crf", crf, "-preset", "6", "-pix_fmt", "yuv420p", "-f", "avif"])
            } else if enc.contains("libaom-av1") {
                try writeViaFFmpeg(cg, to: url, args: ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf, "-cpu-used", "6", "-pix_fmt", "yuv420p", "-f", "avif"])
            } else {
                throw ConvError.unsupported("The installed ffmpeg has no AV1 encoder, so AVIF cannot be written.")
            }
        default:
            guard let type = utType(for: kind) else { throw ConvError.unsupported("Cannot write \(Formats.displayName(kind)) images") }
            try writeImageIO(cg, to: url, type: type, quality: quality, metadata: metadata)
        }
    }

    private static func writeViaFFmpeg(_ cg: CGImage, to url: URL, args: [String]) throws {
        let tmp = Naming.tempFile(ext: "png")
        try writeImageIO(cg, to: tmp, type: .png, quality: 1, metadata: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.ffmpeg(["-i", tmp.path] + args + ["-frames:v", "1", url.path])
    }

    static func writeImageIO(_ cg: CGImage, to url: URL, type: UTType, quality: Double, metadata: [CFString: Any]?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvError.failed("Cannot create \(url.lastPathComponent)")
        }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        var image = cg
        if type == .jpeg || type == .bmp, cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst {
            image = flattened(cg)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvError.failed("Failed to write \(url.lastPathComponent)") }
    }

    /// Composites transparent pixels over white for formats without alpha.
    static func flattened(_ cg: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()!
    }

    static func resized(_ cg: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(cg.width, cg.height)
        guard maxDimension > 0, longest > maxDimension else { return cg }
        let scale = CGFloat(maxDimension) / CGFloat(longest)
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    // MARK: high-level operations

    static func convert(_ url: URL, to target: String, job: Job?) throws -> URL {
        let out = Naming.output(beside: url, ext: Formats.fileExtension(for: target))
        switch target {
        case "pdf":
            try PDFConvert.imagesToPDF([url], output: out)
        case "docx":
            let cg = try load(url)
            try Docx.write([.image(cg, kind: Formats.kind(of: url) == "jpg" ? "jpg" : "png")], to: out)
        default:
            let cg = try load(url)
            try job?.checkCancelled()
            try write(cg, to: out, kind: target, quality: 0.9)
        }
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        let kind = Formats.kind(of: url)
        var cg = try load(url)
        let strong = Settings.compression == .strong
        var maxDim = Settings.compressMaxDimension
        if kind == "png" || kind == "bmp" || kind == "tiff", strong, maxDim == 0 { maxDim = 2048 }
        cg = resized(cg, maxDimension: maxDim)
        let quality = strong ? 0.45 : 0.65
        let outKind = (kind == "bmp" || kind == "tiff") ? "png" : kind
        let out = Naming.output(beside: url, suffix: "Compressed", ext: outKind)
        try write(cg, to: out, kind: outKind, quality: quality)
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let kind = Formats.kind(of: url)
        let out = Naming.output(beside: url, suffix: "No Metadata", ext: kind)
        if kind == "gif" {
            try Shell.ffmpeg(["-i", url.path, "-map_metadata", "-1", "-c", "copy", out.path])
            return out
        }
        let cg = try load(url)
        try write(cg, to: out, kind: kind, quality: 0.92)
        return out
    }

    /// Reads editable metadata properties from an image file.
    static func metadata(of url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        return props
    }

    /// Rewrites the image with new properties, keeping pixel data where possible.
    static func writeMetadata(_ props: [CFString: Any], from url: URL, to out: URL) throws {
        let kind = Formats.kind(of: url)
        guard let type = utType(for: kind), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            let cg = try load(url)
            try write(cg, to: out, kind: kind, quality: 0.92, metadata: props)
            return
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvError.failed("Failed to write metadata") }
    }
}

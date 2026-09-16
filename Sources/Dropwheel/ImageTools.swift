import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit

enum ImageTools {
    // MARK: crop

    static func cropped(_ cg: CGImage, rect: CGRect) -> CGImage {
        cg.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))) ?? cg
    }

    static func crop(_ url: URL, rect: CGRect) throws -> URL {
        let kind = Formats.kind(of: url)
        let outKind = kind == "svg" ? "png" : kind
        let out = Naming.output(beside: url, suffix: "Cropped", ext: outKind)
        try ImageConvert.write(cropped(try ImageConvert.load(url), rect: rect), to: out, kind: outKind, quality: 0.92)
        return out
    }

    // MARK: redact

    /// Rects are in pixel coordinates with a top-left origin.
    static func redacted(_ cg: CGImage, rects: [CGRect], style: MediaConvert.RedactStyle) -> CGImage {
        var image = CIImage(cgImage: cg)
        let h = CGFloat(cg.height)
        for r in rects {
            let ciRect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)  // flip to CI's bottom-left origin
            let patch: CIImage
            switch style {
            case .solid:
                patch = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ciRect)
            case .blur:
                let f = CIFilter.gaussianBlur()
                f.inputImage = image.clampedToExtent()
                f.radius = Float(max(8, min(r.width, r.height) / 6))
                patch = f.outputImage!.cropped(to: ciRect)
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = image.clampedToExtent()
                f.scale = Float(max(12, min(r.width, r.height) / 8))
                f.center = CGPoint(x: ciRect.minX, y: ciRect.minY)
                patch = f.outputImage!.cropped(to: ciRect)
            }
            image = patch.composited(over: image)
        }
        return ImageConvert.render(image.cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))) ?? cg
    }

    static func redact(_ url: URL, rects: [CGRect], style: MediaConvert.RedactStyle) throws -> URL {
        let kind = Formats.kind(of: url)
        let outKind = kind == "svg" ? "png" : kind
        let out = Naming.output(beside: url, suffix: "Redacted", ext: outKind)
        try ImageConvert.write(redacted(try ImageConvert.load(url), rects: rects, style: style), to: out, kind: outKind, quality: 0.92)
        return out
    }

    // MARK: edit (adjustments)

    struct Adjustments {
        var exposure = 0.0        // -2...2
        var brightness = 0.0      // -0.5...0.5
        var contrast = 1.0        // 0.5...1.5
        var saturation = 1.0      // 0...2
        var temperature = 0.0     // -100...100
        var sharpness = 0.0       // 0...2
        var vignette = 0.0        // 0...2
        var highlights = 1.0      // 0...1 (1 = unchanged)
        var shadows = 0.0         // -1...1
        var clarity = 0.0         // 0...1  local contrast
        var dehaze = 0.0          // 0...1
        var grain = 0.0           // 0...1
        var noiseReduction = 0.0  // 0...1
        var effect: String? = nil // CIFilter name, e.g. CIPhotoEffectMono
    }

    static let effects: [(String, String?)] = [("None", nil), ("Mono", "CIPhotoEffectMono"), ("Noir", "CIPhotoEffectNoir"), ("Tonal", "CIPhotoEffectTonal"), ("Fade", "CIPhotoEffectFade"), ("Chrome", "CIPhotoEffectChrome"), ("Process", "CIPhotoEffectProcess"), ("Transfer", "CIPhotoEffectTransfer"), ("Instant", "CIPhotoEffectInstant"), ("Sepia", "CISepiaTone")]

    static func apply(_ input: CIImage, _ a: Adjustments) -> CIImage {
        var img = input
        if a.exposure != 0 { let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(a.exposure); img = f.outputImage ?? img }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = img; f.brightness = Float(a.brightness); f.contrast = Float(a.contrast); f.saturation = Float(a.saturation); img = f.outputImage ?? img
        }
        if a.temperature != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img; f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 6500 + CGFloat(a.temperature) * 30, y: 0); img = f.outputImage ?? img
        }
        if a.highlights != 1 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img; f.highlightAmount = Float(a.highlights); f.shadowAmount = Float(a.shadows); img = f.outputImage ?? img
        }
        if a.noiseReduction > 0 { let f = CIFilter.noiseReduction(); f.inputImage = img; f.noiseLevel = Float(0.02 + a.noiseReduction * 0.1); f.sharpness = Float(0.4); img = f.outputImage ?? img }
        if a.dehaze > 0 {
            // Haze lifts blacks and mutes color: pull the black point down and restore saturation.
            let curve = CIFilter.toneCurve(); curve.inputImage = img
            let k = CGFloat(a.dehaze)
            curve.point0 = CGPoint(x: 0, y: 0); curve.point1 = CGPoint(x: 0.25, y: 0.25 - 0.12 * k); curve.point2 = CGPoint(x: 0.5, y: 0.5 - 0.05 * k); curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.03 * k); curve.point4 = CGPoint(x: 1, y: 1)
            img = curve.outputImage ?? img
            let sat = CIFilter.colorControls(); sat.inputImage = img; sat.saturation = Float(1 + 0.35 * a.dehaze); sat.contrast = Float(1 + 0.15 * a.dehaze); img = sat.outputImage ?? img
        }
        if a.clarity > 0 { let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(max(img.extent.width, img.extent.height) / 40); f.intensity = Float(a.clarity * 0.8); img = f.outputImage?.cropped(to: input.extent) ?? img }
        if a.sharpness > 0 { let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(a.sharpness); img = f.outputImage ?? img }
        if a.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!
            let mono = CIFilter.colorMatrix(); mono.inputImage = noise
            let g = CGFloat(a.grain * 0.18)
            mono.rVector = CIVector(x: g, y: 0, z: 0, w: 0); mono.gVector = CIVector(x: g, y: 0, z: 0, w: 0); mono.bVector = CIVector(x: g, y: 0, z: 0, w: 0); mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            mono.biasVector = CIVector(x: -g / 2, y: -g / 2, z: -g / 2, w: 0)
            if let n = mono.outputImage?.cropped(to: input.extent) {
                let add = CIFilter.additionCompositing(); add.inputImage = n; add.backgroundImage = img; img = add.outputImage ?? img
            }
        }
        if a.vignette > 0 { let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(a.vignette); f.radius = Float(max(img.extent.width, img.extent.height) / 2); img = f.outputImage ?? img }
        if let name = a.effect, let f = CIFilter(name: name) {
            f.setValue(img, forKey: kCIInputImageKey)
            if name == "CISepiaTone" { f.setValue(0.8, forKey: kCIInputIntensityKey) }
            img = f.outputImage ?? img
        }
        return img.cropped(to: input.extent)
    }

    static func edit(_ url: URL, adjustments: Adjustments) throws -> URL {
        let kind = Formats.kind(of: url)
        let outKind = kind == "svg" ? "png" : kind
        let cg = try ImageConvert.load(url)
        guard let result = ImageConvert.render(apply(CIImage(cgImage: cg), adjustments)) else { throw ConvError.failed("Could not render image") }
        let out = Naming.output(beside: url, suffix: "Edited", ext: outKind)
        try ImageConvert.write(result, to: out, kind: outKind, quality: 0.92)
        return out
    }

    // MARK: add background

    enum Background {
        case solid(NSColor)
        case gradient(NSColor, NSColor)
        case image(URL)
    }

    struct FrameOptions {
        var background: Background = .solid(.white)
        var aspect: CGFloat? = nil   // nil keeps the photo's aspect
        var padding = 0.08           // fraction of the shorter canvas edge
        var radius = 0.04            // corner radius as a fraction of the shorter photo edge
    }

    static func framed(_ cg: CGImage, options: FrameOptions) throws -> CGImage {
        let pw = CGFloat(cg.width), ph = CGFloat(cg.height)
        let aspect = options.aspect ?? pw / ph
        // Canvas: photo plus padding, expanded to the requested aspect.
        let pad = CGFloat(options.padding) * min(pw, ph)
        var cw = pw + pad * 2, ch = ph + pad * 2
        if cw / ch < aspect { cw = ch * aspect } else { ch = cw / aspect }
        let w = Int(cw), h = Int(ch)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConvError.failed("Cannot create canvas") }
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        switch options.background {
        case .solid(let c):
            ctx.setFillColor((c.usingColorSpace(.sRGB) ?? c).cgColor)
            ctx.fill(canvas)
        case .gradient(let a, let b):
            let colors = [(a.usingColorSpace(.sRGB) ?? a).cgColor, (b.usingColorSpace(.sRGB) ?? b).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: ch), end: CGPoint(x: cw, y: 0), options: [])
            }
        case .image(let url):
            let bg = try ImageConvert.load(url)
            let s = max(cw / CGFloat(bg.width), ch / CGFloat(bg.height))
            let bw = CGFloat(bg.width) * s, bh = CGFloat(bg.height) * s
            ctx.interpolationQuality = .high
            ctx.draw(bg, in: CGRect(x: (cw - bw) / 2, y: (ch - bh) / 2, width: bw, height: bh))
        }
        let photoRect = CGRect(x: (cw - pw) / 2, y: (ch - ph) / 2, width: pw, height: ph)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.15), blur: pad * 0.6, color: CGColor(gray: 0, alpha: 0.35))
        let radius = CGFloat(options.radius) * min(pw, ph)
        let path = CGPath(roundedRect: photoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: photoRect)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw ConvError.failed("Cannot render canvas") }
        return out
    }

    static func frame(_ url: URL, options: FrameOptions) throws -> URL {
        let kind = Formats.kind(of: url)
        let outKind = kind == "svg" ? "png" : kind
        let out = Naming.output(beside: url, suffix: "Background", ext: outKind)
        try ImageConvert.write(try framed(try ImageConvert.load(url), options: options), to: out, kind: outKind, quality: 0.92)
        return out
    }
}

enum Collage {
    enum Layout: Int { case grid = 0, row, column, featured }

    struct Options {
        var layout: Layout = .grid
        var spacing = 0.02        // fraction of canvas width
        var radius = 0.02         // fraction of cell size
        var background: NSColor = .white
        var cell = 1000           // target cell size in pixels
    }

    /// Cell frames in a unit canvas (0...1 in both axes) plus the canvas aspect ratio.
    static func layout(count n: Int, layout: Layout) -> (cells: [CGRect], aspect: CGFloat) {
        guard n > 0 else { return ([], 1) }
        switch layout {
        case .row:
            let w = 1.0 / CGFloat(n)
            return ((0..<n).map { CGRect(x: CGFloat($0) * w, y: 0, width: w, height: 1) }, CGFloat(n))
        case .column:
            let h = 1.0 / CGFloat(n)
            return ((0..<n).map { CGRect(x: 0, y: CGFloat($0) * h, width: 1, height: h) }, 1 / CGFloat(n))
        case .featured:
            guard n > 1 else { return ([CGRect(x: 0, y: 0, width: 1, height: 1)], 1) }
            let rest = n - 1
            var cells = [CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)]
            let h = 1.0 / CGFloat(rest)
            for i in 0..<rest { cells.append(CGRect(x: 2.0 / 3.0, y: CGFloat(i) * h, width: 1.0 / 3.0, height: h)) }
            return (cells, 3.0 / 2.0)
        case .grid:
            let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
            var cells: [CGRect] = []
            for i in 0..<n {
                let r = i / cols, c = i % cols
                let inRow = min(cols, n - r * cols)
                let w = 1.0 / CGFloat(inRow)
                cells.append(CGRect(x: CGFloat(c) * w, y: CGFloat(r) / CGFloat(rows), width: w, height: 1.0 / CGFloat(rows)))
            }
            return (cells, CGFloat(cols) / CGFloat(rows))
        }
    }

    static func image(_ images: [CGImage], options: Options, maxWidth: Int) throws -> CGImage {
        let (cells, aspect) = layout(count: images.count, layout: options.layout)
        let cols = options.layout == .row ? images.count : (options.layout == .grid ? Int(ceil(sqrt(Double(images.count)))) : (options.layout == .featured ? 3 : 1))
        let width = min(maxWidth, options.cell * cols)
        let height = Int(CGFloat(width) / aspect)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConvError.failed("Cannot create canvas") }
        ctx.setFillColor((options.background.usingColorSpace(.sRGB) ?? options.background).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let gap = CGFloat(options.spacing) * CGFloat(width)
        ctx.interpolationQuality = .high
        for (img, cell) in zip(images, cells) {
            // cells use a top-left origin; flip for CoreGraphics
            var r = CGRect(x: cell.minX * CGFloat(width), y: CGFloat(height) - (cell.minY + cell.height) * CGFloat(height), width: cell.width * CGFloat(width), height: cell.height * CGFloat(height))
            r = r.insetBy(dx: gap / 2, dy: gap / 2)
            let radius = CGFloat(options.radius) * min(r.width, r.height)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            // aspect-fill
            let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { throw ConvError.failed("Cannot render collage") }
        return out
    }

    static func render(_ urls: [URL], options: Options, output: URL) throws -> URL {
        let images = try urls.map { try ImageConvert.load($0) }
        let cg = try image(images, options: options, maxWidth: 6000)
        try ImageConvert.write(cg, to: output, kind: Formats.kind(of: output) == "jpg" ? "jpg" : "png", quality: 0.92)
        return output
    }
}

enum PDFTools {
    /// Writes a new PDF with pages in `order` (indices into the source, duplicates allowed) and per-output-index rotations.
    static func organize(_ doc: PDFDocument, order: [Int], rotations: [Int: Int], source: URL) throws -> URL {
        let out = Naming.output(beside: source, suffix: "Organized", ext: "pdf")
        let result = PDFDocument()
        for (i, pageIndex) in order.enumerated() {
            guard let page = doc.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + (rotations[i] ?? 0) + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0, result.write(to: out) else { throw ConvError.failed("Could not write PDF") }
        return out
    }
}

import AppKit
// Draws an original app icon (blue-teal gradient tile with a converting-arrows glyph) and writes an .icns.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
func render(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.72, alpha: 1)])!
        .draw(in: path, angle: -60)
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.2, dy: s * 0.2))
    ring.lineWidth = s * 0.07
    NSColor.white.withAlphaComponent(0.92).setStroke()
    ring.stroke()
    // Two arrow heads on the ring to suggest conversion.
    for a in [0.0, Double.pi] {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2 - s * 0.2
        let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
        let tri = NSBezierPath()
        let d = s * 0.11
        let dir = a == 0 ? 1.0 : -1.0
        tri.move(to: CGPoint(x: p.x - d * 0.9, y: p.y + CGFloat(dir) * d))
        tri.line(to: CGPoint(x: p.x + d * 0.9, y: p.y + CGFloat(dir) * d))
        tri.line(to: CGPoint(x: p.x, y: p.y - CGFloat(dir) * d * 0.4))
        tri.close()
        NSColor.white.setFill()
        tri.fill()
    }
    img.unlockFocus()
    return img
}
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DropwheelIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for (name, size) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let img = render(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.launchPath = "/usr/bin/iconutil"; p.arguments = ["-c", "icns", tmp.path, "-o", out]; p.launch(); p.waitUntilExit()
print("wrote \(out)")

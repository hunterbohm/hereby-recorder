// Draws the recorder's app icon, Hereby's white "H" on its blue, into mac/AppIcon.icns.
// usage: swift mac/scripts/make-icon.swift   (from the repo root; uses iconutil, which ships with macOS)
// The blue is the one in Hereby's web icon (cloud/web/icon.png): #2456C4.
import AppKit

func drawIcon(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824-point rounded square centred in the 1024 canvas.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor(srgbRed: 36 / 255, green: 86 / 255, blue: 196 / 255, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    shape.addClip()
    NSGradient(starting: NSColor(srgbRed: 52 / 255, green: 106 / 255, blue: 220 / 255, alpha: 1),
               ending: NSColor(srgbRed: 30 / 255, green: 72 / 255, blue: 170 / 255, alpha: 1))!.draw(in: body, angle: -90)

    let font = NSFont.systemFont(ofSize: 560 * s, weight: .heavy)
    let text = NSAttributedString(string: "H", attributes: [.font: font, .foregroundColor: NSColor.white])
    let line = CTLineCreateWithAttributedString(text)
    let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.textPosition = CGPoint(x: body.midX - glyphs.midX, y: body.midY - glyphs.midY)
    CTLineDraw(line, ctx)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Recorder.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! drawIcon(size: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! drawIcon(size: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = URL(fileURLWithPath: "mac/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] {
    try? drawIcon(size: 1024).write(to: URL(fileURLWithPath: preview))
}
try? fm.removeItem(at: set)
if iconutil.terminationStatus != 0 {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(iconutil.terminationStatus)
}
print("wrote \(out.path)")

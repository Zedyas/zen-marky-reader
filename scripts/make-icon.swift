import AppKit

// Renders the macOS app icon set from assets/logo.svg: the mark on a warm paper tile.
// Usage: swift scripts/make-icon.swift <output iconset directory>

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard let logo = NSImage(contentsOf: root.appendingPathComponent("assets/logo.svg")) else {
    FileHandle.standardError.write(Data("Missing assets/logo.svg. Run: swift scripts/make-logo.swift\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.92, green: 0.90, blue: 0.86, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.21, alpha: 0.12).setStroke()
        tile.lineWidth = 6
        tile.stroke()
        logo.draw(in: NSRect(x: 132, y: 132, width: 760, height: 760))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 55, y: 55, width: 914, height: 914)
        let path = NSBezierPath(roundedRect: rect, xRadius: 208, yRadius: 208)
        NSGradient(starting: NSColor(red: 0.22, green: 0.57, blue: 0.51, alpha: 1),
                   ending: NSColor(red: 0.10, green: 0.32, blue: 0.31, alpha: 1))!.draw(in: path, angle: -75)
        NSColor(red: 0.91, green: 0.84, blue: 0.65, alpha: 1).setFill()
        let paper = NSBezierPath(roundedRect: NSRect(x: 300, y: 405, width: 425, height: 355), xRadius: 35, yRadius: 35)
        paper.fill()
        NSColor(red: 0.48, green: 0.49, blue: 0.36, alpha: 0.6).setStroke()
        for y in [655, 595, 535] {
            let line = NSBezierPath(); line.move(to: NSPoint(x: 365, y: y)); line.line(to: NSPoint(x: 645, y: y)); line.lineWidth = 16; line.lineCapStyle = .round; line.stroke()
        }
        NSColor(red: 0.96, green: 0.96, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 230, y: 267, width: 565, height: 230), xRadius: 44, yRadius: 44).fill()
        NSColor(red: 0.17, green: 0.43, blue: 0.39, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 429, y: 397, width: 166, height: 31), xRadius: 15, yRadius: 15).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)

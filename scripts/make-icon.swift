import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
        let background = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.5, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.23, alpha: 1))!.draw(in: background, angle: -90)
        for (x, y, width, color) in [(220.0, 600.0, 580.0, NSColor.systemOrange), (300, 425, 500, NSColor.systemGreen), (220, 250, 580, NSColor.systemPurple)] {
            color.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 125), xRadius: 42, yRadius: 42).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 50, y: y + 55, width: width - 100, height: 15), xRadius: 7, yRadius: 7).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = multiplier == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)\(suffix).png"))
    }
}

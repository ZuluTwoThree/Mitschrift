import AppKit

@main
struct IconMaker {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()

        let outer = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 38
        shadow.shadowOffset = NSSize(width: 0, height: -15)
        shadow.set()
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.15, alpha: 1).setFill()
        outer.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.75, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.98, alpha: 1)
        ])!
        let disc = NSBezierPath(ovalIn: NSRect(x: 192, y: 192, width: 640, height: 640))
        gradient.draw(in: disc, angle: -45)

        let bars: [(CGFloat, CGFloat)] = [
            (48, 220), (48, 340), (48, 470), (48, 300), (48, 190)
        ]
        let gap: CGFloat = 42
        let totalWidth = bars.reduce(0) { $0 + $1.0 } + gap * CGFloat(bars.count - 1)
        var x = (1024 - totalWidth) / 2
        NSColor.white.setFill()
        for (width, height) in bars {
            let rect = NSRect(x: x, y: (1024 - height) / 2, width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
            x += width + gap
        }

        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}

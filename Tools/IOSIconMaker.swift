import AppKit

/// Zeichnet das iOS-App-Icon (1024×1024, ohne Transparenz, ohne abgerundete Ecken; iOS maskiert selbst).
///
/// Motiv: zwei versetzte Sprechblasen auf tiefem Indigo. Die große korallenrote Blase trägt eine
/// Wellenform (Aufnahme), die kleine mintfarbene Blase drei Textzeilen (Mitschrift). Zusammen stehen
/// sie für Gespräch, Sprecherwechsel und Live-Text. Bewusst andere Farbwelt als das macOS-Icon (Cyan/Blau).
@main
struct IOSIconMaker {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Aufruf: IOSIconMaker <ausgabe.png>\n".utf8))
            exit(2)
        }
        let size = 1024
        // Opaker RGB-Kontext ohne Alphakanal (App-Icons dürfen keine Transparenz haben).
        guard let cgContext = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            FileHandle.standardError.write(Data("Kein Grafikkontext.\n".utf8))
            exit(1)
        }
        let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        draw(in: CGFloat(size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let image = cgContext.makeImage() else {
            FileHandle.standardError.write(Data("Bild konnte nicht erzeugt werden.\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("PNG konnte nicht erzeugt werden.\n".utf8))
            exit(1)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }

    static func draw(in s: CGFloat) {
        // Hintergrund: tiefes Indigo mit leichtem Verlauf
        let background = NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.32, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.19, alpha: 1)
        ])!
        background.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -60)

        let coral = NSColor(calibratedRed: 0.99, green: 0.47, blue: 0.36, alpha: 1)
        let coralDeep = NSColor(calibratedRed: 0.93, green: 0.33, blue: 0.30, alpha: 1)
        let mint = NSColor(calibratedRed: 0.52, green: 0.92, blue: 0.78, alpha: 1)
        let ink = NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.20, alpha: 1)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -14)

        // Große Blase unten links (Aufnahme) mit Schweif
        let big = NSRect(x: 112, y: 150, width: 640, height: 500)
        let bigPath = NSBezierPath(roundedRect: big, xRadius: 150, yRadius: 150)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 230, y: 190))
        tail.line(to: NSPoint(x: 150, y: 90))
        tail.line(to: NSPoint(x: 370, y: 160))
        tail.close()
        bigPath.append(tail)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        coral.setFill()
        bigPath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [coral, coralDeep])!.draw(in: bigPath, angle: -90)

        // Wellenform in der großen Blase: sieben Balken
        let heights: [CGFloat] = [120, 220, 330, 250, 300, 180, 110]
        let barWidth: CGFloat = 46
        let gap: CGFloat = 36
        let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        var x = big.midX - total / 2
        let midY = big.midY + 10
        NSColor.white.setFill()
        for h in heights {
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: barWidth, height: h),
                         xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }

        // Kleine Blase oben rechts (Mitschrift), überlappt leicht, Schweif nach unten links
        let small = NSRect(x: 520, y: 560, width: 400, height: 320)
        let smallPath = NSBezierPath(roundedRect: small, xRadius: 100, yRadius: 100)
        let smallTail = NSBezierPath()
        smallTail.move(to: NSPoint(x: 600, y: 600))
        smallTail.line(to: NSPoint(x: 540, y: 500))
        smallTail.line(to: NSPoint(x: 700, y: 580))
        smallTail.close()
        smallPath.append(smallTail)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        mint.setFill()
        smallPath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Drei Textzeilen in der kleinen Blase
        ink.setFill()
        let lineHeight: CGFloat = 34
        let lines: [CGFloat] = [250, 300, 190]
        var y = small.maxY - 92
        for width in lines {
            NSBezierPath(roundedRect: NSRect(x: small.minX + 60, y: y - lineHeight, width: width, height: lineHeight),
                         xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
            y -= lineHeight + 38
        }
    }
}

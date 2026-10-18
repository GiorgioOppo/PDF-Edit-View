import AppKit

// Creates the standard iconset from vector shapes. No downloaded assets needed.
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Uso: create-icon /percorso/AppIcon.iconset\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon() {
    let card = NSBezierPath(roundedRect: NSRect(x: 82, y: 72, width: 860, height: 860),
                            xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = color(0.08, 0.22, 0.22, 0.20)
    cardShadow.shadowBlurRadius = 20
    cardShadow.shadowOffset = NSSize(width: 0, height: -10)
    cardShadow.set()
    color(0.17, 0.42, 0.43).setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.28, 0.57, 0.56), ending: color(0.12, 0.35, 0.38))!
        .draw(in: card, angle: -70)

    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: 298, y: 202))
    paper.line(to: NSPoint(x: 728, y: 202))
    paper.curve(to: NSPoint(x: 752, y: 226), controlPoint1: NSPoint(x: 742, y: 202),
                controlPoint2: NSPoint(x: 752, y: 212))
    paper.line(to: NSPoint(x: 752, y: 671))
    paper.line(to: NSPoint(x: 624, y: 810))
    paper.line(to: NSPoint(x: 298, y: 810))
    paper.curve(to: NSPoint(x: 274, y: 786), controlPoint1: NSPoint(x: 284, y: 810),
                controlPoint2: NSPoint(x: 274, y: 800))
    paper.line(to: NSPoint(x: 274, y: 226))
    paper.curve(to: NSPoint(x: 298, y: 202), controlPoint1: NSPoint(x: 274, y: 212),
                controlPoint2: NSPoint(x: 284, y: 202))
    paper.close()

    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = color(0.04, 0.19, 0.20, 0.30)
    paperShadow.shadowBlurRadius = 34
    paperShadow.shadowOffset = NSSize(width: 0, height: -20)
    paperShadow.set()
    color(0.98, 0.97, 0.93).setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(1, 0.995, 0.97), ending: color(0.94, 0.95, 0.92))!
        .draw(in: paper, angle: -90)

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 624, y: 810))
    fold.line(to: NSPoint(x: 624, y: 697))
    fold.curve(to: NSPoint(x: 650, y: 671), controlPoint1: NSPoint(x: 624, y: 680),
               controlPoint2: NSPoint(x: 634, y: 671))
    fold.line(to: NSPoint(x: 752, y: 671))
    fold.close()
    color(0.80, 0.87, 0.83).setFill()
    fold.fill()

    let title = "PDF" as NSString
    title.draw(at: NSPoint(x: 331, y: 517), withAttributes: [
        .font: NSFont.systemFont(ofSize: 112, weight: .semibold),
        .foregroundColor: color(0.18, 0.37, 0.38),
        .kern: 2
    ])

    for (index, width) in [326.0, 280.0, 325.0, 196.0].enumerated() {
        let line = NSBezierPath(roundedRect: NSRect(x: 340, y: 453 - Double(index) * 48,
                                                   width: width, height: 13),
                                xRadius: 6.5, yRadius: 6.5)
        color(0.52, 0.64, 0.61, index == 3 ? 0.5 : 0.65).setFill()
        line.fill()
    }

    // A warm annotation stroke brings the editor aspect into the icon.
    let highlight = NSBezierPath(roundedRect: NSRect(x: 326, y: 393, width: 317, height: 39),
                                 xRadius: 9, yRadius: 9)
    color(0.92, 0.55, 0.40, 0.35).setFill()
    highlight.fill()

    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 585, y: 285))
    mark.curve(to: NSPoint(x: 712, y: 307), controlPoint1: NSPoint(x: 620, y: 333),
               controlPoint2: NSPoint(x: 672, y: 262))
    mark.lineWidth = 16
    mark.lineCapStyle = .round
    color(0.88, 0.43, 0.32).setStroke()
    mark.stroke()
}

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixelSize = pointSize * scale
        guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                      pixelsWide: pixelSize,
                                                      pixelsHigh: pixelSize,
                                                      bitsPerSample: 8,
                                                      samplesPerPixel: 4,
                                                      hasAlpha: true,
                                                      isPlanar: false,
                                                      colorSpaceName: .deviceRGB,
                                                      bytesPerRow: 0,
                                                      bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: representation) else {
            fatalError("Impossibile creare il contesto grafico dell’icona.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixelSize) / 1024)
        transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            fatalError("Impossibile esportare l’icona in PNG.")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: outputDirectory.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
    }
}

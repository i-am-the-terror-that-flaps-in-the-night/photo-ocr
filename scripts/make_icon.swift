// Draws the Photo OCR app icon (1024 px PNG) and the DMG window background.
// Usage: swift scripts/make_icon.swift <icon.png> <dmg-background.png>
import AppKit
import CoreGraphics

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ ctx: CGContext, to path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: Icon

func drawIcon(to path: String) {
    let ctx = makeContext(1024, 1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(20, 60, 140))
    ctx.fillPath()
    ctx.restoreGState()

    // Blue gradient tile.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(58, 160, 255), rgb(24, 78, 200)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // White page.
    let page = CGRect(x: 302, y: 232, width: 420, height: 560)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0, 20, 80, 0.35))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillPath()
    ctx.restoreGState()

    // Text lines on the page; the middle ones are highlighted as "recognized".
    let lineWidths: [CGFloat] = [300, 250, 300, 210, 300, 270, 160]
    for (i, width) in lineWidths.enumerated() {
        let y = 708 - CGFloat(i) * 64
        let highlighted = (2...3).contains(i)
        let rect = CGRect(x: 362, y: y, width: width, height: 26)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.setFillColor(highlighted ? rgb(36, 120, 240) : rgb(196, 204, 218))
        ctx.fillPath()
    }

    // Viewfinder corner brackets around the page.
    let frame = page.insetBy(dx: -64, dy: -56)
    let arm: CGFloat = 86
    ctx.setStrokeColor(rgb(255, 255, 255, 0.95))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
        (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.strokePath()
    }
    writePNG(ctx, to: path)
}

// MARK: DMG background (660 x 400 points, drawn at 2x)

func drawBackground(to path: String) {
    let scale: CGFloat = 2
    let ctx = makeContext(1320, 800)
    ctx.scaleBy(x: scale, y: scale)
    // Mid-tone blue: Finder draws icon labels black in light mode and white in
    // dark mode, and both stay readable on it.
    ctx.setFillColor(rgb(84, 138, 220))
    ctx.fill(CGRect(x: 0, y: 0, width: 660, height: 400))

    // Arrow from the app icon (x 180) to the Applications folder (x 480).
    ctx.setStrokeColor(rgb(255, 255, 255, 0.9))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let y: CGFloat = 400 - 190
    ctx.move(to: CGPoint(x: 285, y: y))
    ctx.addLine(to: CGPoint(x: 375, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 357, y: y + 18))
    ctx.addLine(to: CGPoint(x: 375, y: y))
    ctx.addLine(to: CGPoint(x: 357, y: y - 18))
    ctx.strokePath()

    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title = NSAttributedString(string: "Drag Photo OCR into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
    ])
    title.draw(in: CGRect(x: 0, y: 400 - 70, width: 660, height: 26))
    let note = NSAttributedString(string: "First launch: System Settings › Privacy & Security › Open Anyway",
                                  attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor(white: 1, alpha: 0.88),
        .paragraphStyle: style,
    ])
    note.draw(in: CGRect(x: 0, y: 400 - 352, width: 660, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    writePNG(ctx, to: path)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make_icon.swift <icon.png> <dmg-background.png>\n".data(using: .utf8)!)
    exit(2)
}
drawIcon(to: args[1])
drawBackground(to: args[2])

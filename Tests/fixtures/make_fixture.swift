// Throwaway: draws known text to sample.png, and a pixel-rotated copy tagged
// with EXIF orientation 6 to sample_rotated.jpg. Usage: make_fixture <out-dir>
import AppKit
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let lines = [
    "The quick brown fox jumps over the lazy dog.",
    "Photo OCR reads printed text from pictures.",
    "Invoice number 48213 is due on 14 March 2027.",
]
let w = 1600, h = 520
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Helvetica", size: 52)!, .foregroundColor: NSColor.black,
]
for (i, line) in lines.enumerated() {
    ctx.textPosition = CGPoint(x: 80, y: h - 140 - i * 120)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs)), ctx)
}
let upright = ctx.makeImage()!

func write(_ image: CGImage, _ name: String, _ type: UTType, _ props: [CFString: Any]) {
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}
write(upright, "sample.png", .png, [:])

// Store pixels rotated 90 degrees counter-clockwise, as a phone held in
// portrait does; orientation 6 ("right") tells readers to rotate 90 CW to view.
let rot = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rot.translateBy(x: CGFloat(h), y: 0)
rot.rotate(by: .pi / 2)
rot.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h))
write(rot.makeImage()!, "sample_rotated.jpg", .jpeg,
      [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9])

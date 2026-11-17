// Renders a macOS app icon master (1024×1024, transparent corners) from a square source image:
// the artwork is scaled into Apple's 824×824 icon body, clipped to a continuous rounded rectangle,
// with the standard soft drop shadow. Usage: swift scripts/make-icon.swift <source.png> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-icon <source.png> <out.png>\n".utf8)); exit(1)
}
let size = 1024, body: CGFloat = 824, inset = (CGFloat(size) - body) / 2, radius: CGFloat = 185.4
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
ctx.interpolationQuality = .high
let rect = CGRect(x: inset, y: inset + 6, width: body, height: body)   // slightly above centre, like system icons
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath

// Shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// Artwork clipped to the body. The source's own (smaller-radius) corners fall outside the clip.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let bleed: CGFloat = 0.02 * body   // crop the source's outer edge slightly so no edge pixels show
ctx.draw(cg, in: rect.insetBy(dx: -bleed, dy: -bleed))
ctx.restoreGState()

// Hairline highlight on the edge, like macOS icons.
ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10)); ctx.setLineWidth(2); ctx.strokePath()

guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))

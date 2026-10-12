// make-icon.swift — draws Perch's app icon from code and writes it as PNG files.
//
// Usage (through scripts/make-icon.sh):  make-icon <output-folder.iconset>
//
// The picture is original and drawn entirely with shapes: a dark rounded square, the notch as a
// black pill hanging from its top edge with a small "all is well" light, and Perch's bird (the
// same bird as the menu-bar icon) sitting on a branch, in the app's periwinkle-to-violet accent.
// Every size macOS wants is drawn directly from the shapes, so each one is sharp.

import AppKit

/// Draws the icon into a square of `side` pixels. All numbers below are for a 1024 canvas.
func drawIcon(side: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.scaleBy(x: side / 1024, y: side / 1024)
    let space = CGColorSpaceCreateDeviceRGB()
    func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    func gradient(_ colours: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colours as CFArray, locations: nil)!
    }

    // The tile: macOS icons leave a margin around a rounded square.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // A soft shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: colour(0x000000, 0.45))
    context.addPath(tilePath)
    context.setFillColor(colour(0x0B0C14))
    context.fillPath()
    context.restoreGState()

    // Background: deep blue at the top falling to near black, with a glow behind the bird.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(gradient([colour(0x232A52), colour(0x10121F), colour(0x07080D)]),
                               start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    context.drawRadialGradient(gradient([colour(0x8A7BFF, 0.55), colour(0x7C93FF, 0.18), colour(0x7C93FF, 0)]),
                               startCenter: CGPoint(x: 500, y: 430), startRadius: 0,
                               endCenter: CGPoint(x: 500, y: 430), endRadius: 430, options: [])

    // The notch: a black pill hanging from the top edge, with a small green light.
    let notch = CGRect(x: 512 - 190, y: tile.maxY - 92, width: 380, height: 150)
    context.addPath(CGPath(roundedRect: notch, cornerWidth: 46, cornerHeight: 46, transform: nil))
    context.setFillColor(colour(0x000000))
    context.fillPath()
    context.addEllipse(in: CGRect(x: notch.maxX - 74, y: tile.maxY - 64, width: 30, height: 30))
    context.setFillColor(colour(0x3DDC97))
    context.fillPath()
    context.restoreGState()

    // A hairline of light around the tile.
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    context.setStrokeColor(colour(0xFFFFFF, 0.12))
    context.setLineWidth(6)
    context.strokePath()

    // The bird and its branch. Coordinates are the menu-bar bird's (a 19 x 18 drawing), enlarged.
    context.saveGState()
    context.translateBy(x: 172, y: 196)
    context.scaleBy(x: 36, y: 36)

    // Branch.
    context.setStrokeColor(colour(0xE9ECFF, 0.92))
    context.setLineWidth(1.25)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 1.2, y: 3.3))
    context.addLine(to: CGPoint(x: 17.8, y: 3.3))
    context.strokePath()

    // The bird's parts, each filled with the same accent gradient. (They are filled one by one:
    // as a single path, the places where two parts overlap would be left as holes.)
    let lean = CGAffineTransform(translationX: 9.6, y: 8.5).rotated(by: -16 * .pi / 180)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 12.4, y: 9.4))
    tail.addLine(to: CGPoint(x: 18.2, y: 7.0))
    tail.addLine(to: CGPoint(x: 17.3, y: 5.2))
    tail.addLine(to: CGPoint(x: 12.0, y: 6.2))
    tail.closeSubpath()
    var parts: [CGPath] = [
        tail,
        CGPath(ellipseIn: CGRect(x: -5.2, y: -3.6, width: 10.4, height: 7.2), transform: [lean]),   // body
        CGPath(ellipseIn: CGRect(x: 2.7, y: 9.0, width: 5.8, height: 5.8), transform: nil),         // head
    ]
    for x in [8.3, 10.7] as [CGFloat] {                                                             // legs
        parts.append(CGPath(rect: CGRect(x: x - 0.5, y: 3.5, width: 1.0, height: 2.4), transform: nil))
    }
    let feathers = gradient([colour(0xAEBBFF), colour(0x7C93FF), colour(0xA873FF)])
    for part in parts {
        context.saveGState()
        context.addPath(part)
        context.clip()
        context.drawLinearGradient(feathers, start: CGPoint(x: 3, y: 15), end: CGPoint(x: 17, y: 4),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    // Beak, in a warm colour so the bird reads at small sizes.
    context.move(to: CGPoint(x: 3.2, y: 13.0))
    context.addLine(to: CGPoint(x: 0.5, y: 11.7))
    context.addLine(to: CGPoint(x: 3.2, y: 10.7))
    context.closePath()
    context.setFillColor(colour(0xFFB547))
    context.fillPath()

    // Eye, and a sliver of wing.
    context.addEllipse(in: CGRect(x: 4.25, y: 11.55, width: 1.5, height: 1.5))
    context.setFillColor(colour(0x0B0C14))
    context.fillPath()
    context.setStrokeColor(colour(0x0B0C14, 0.55))
    context.setLineWidth(0.8)
    context.move(to: CGPoint(x: 8.0, y: 9.3))
    context.addCurve(to: CGPoint(x: 13.4, y: 7.3), control1: CGPoint(x: 9.8, y: 7.2), control2: CGPoint(x: 11.8, y: 6.9))
    context.strokePath()
    context.restoreGState()
}

/// Renders the icon at `pixels` x `pixels` and returns PNG data.
func png(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(side: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output-folder.iconset>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// The names and sizes `iconutil` expects: each point size at 1x and 2x.
let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in files {
    guard let data = png(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not draw \(name)\n".utf8))
        exit(1)
    }
    do { try data.write(to: folder.appendingPathComponent(name)) } catch {
        FileHandle.standardError.write(Data("could not write \(name): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
print("drew \(files.count) sizes into \(folder.path)")

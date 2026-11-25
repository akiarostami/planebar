// Renders Resources/AppIcon.icns: Herdbar's dark tile with three columns of cards (blue,
// yellow, green) and a tick under the last one. Run through scripts/make-icon.sh.
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let side = CGFloat(pixels)
    // The macOS icon shape: a rounded square inset from the canvas.
    let tile = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.1, dy: side * 0.1)
    let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1), CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // Three columns of cards, like a board: three in the first (blue), two in the second
    // (yellow), one in the third (green), and a white tick where the third column's next
    // card would be.
    let blue = CGColor(red: 0.20, green: 0.56, blue: 1.00, alpha: 1)
    let yellow = CGColor(red: 1.00, green: 0.80, blue: 0.10, alpha: 1)
    let green = CGColor(red: 0.20, green: 0.80, blue: 0.40, alpha: 1)
    let w = tile.width
    let columnWidth = w * 0.17
    let gap = w * 0.07
    let cardHeight = w * 0.10
    let cardGap = w * 0.035
    let radius = w * 0.029
    let top = tile.midY + w * 0.22
    var x = tile.midX - (columnWidth * 3 + gap * 2) / 2
    for (colour, count) in [(blue, 3), (yellow, 2), (green, 1)] {
        var y = top
        for _ in 0..<count {
            let card = CGRect(x: x, y: y - cardHeight, width: columnWidth, height: cardHeight)
            context.setFillColor(colour)
            context.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            y -= cardHeight + cardGap
        }
        x += columnWidth + gap
    }
    let tickX = tile.midX + columnWidth + gap - w * 0.005
    let tickY = top - w * 0.32
    let size = w * 0.13
    context.setStrokeColor(CGColor(gray: 0.95, alpha: 1))
    context.setLineWidth(w * 0.035)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: tickX - size * 0.5, y: tickY))
    context.addLine(to: CGPoint(x: tickX - size * 0.12, y: tickY - size * 0.38))
    context.addLine(to: CGPoint(x: tickX + size * 0.55, y: tickY + size * 0.4))
    context.strokePath()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

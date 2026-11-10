// Draws the app icon. Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

func render(pixels: Int, to url: URL) throws {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    // macOS icon grid: an 824/1024 rounded square, centered.
    let inset = size * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [CGColor(srgbRed: 0.11, green: 0.74, blue: 0.56, alpha: 1), CGColor(srgbRed: 0.03, green: 0.38, blue: 0.42, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // Play triangle, nudged right so it looks optically centered.
    let unit = tile.width
    let center = CGPoint(x: tile.midX + unit * 0.035, y: tile.midY)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: center.x - unit * 0.19, y: center.y + unit * 0.25))
    triangle.addLine(to: CGPoint(x: center.x + unit * 0.25, y: center.y))
    triangle.addLine(to: CGPoint(x: center.x - unit * 0.19, y: center.y - unit * 0.25))
    triangle.closeSubpath()
    context.setLineJoin(.round)
    context.setLineWidth(unit * 0.05)
    context.setStrokeColor(.white)
    context.setFillColor(.white)
    context.addPath(triangle)
    context.drawPath(using: .fillStroke)

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

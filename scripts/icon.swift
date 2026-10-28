// Draws Resources/Rondel.icns: the wheel with one slice lit, on a rounded
// square. Run from the repository root with `make icon`; the result is
// committed so building the app doesn't need this.
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let unit = size / 1024
    // Apple's grid leaves about a tenth of the canvas as margin around the tile.
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit), angle: -90)

    let centre = CGPoint(x: 512 * unit, y: 512 * unit)
    let outer = 330 * unit, inner = 130 * unit
    let span: CGFloat = 360 / 7
    for i in 0..<7 {
        let start = 90 - span / 2 - CGFloat(i) * span + 1.5
        let end = start + span - 3
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: outer, startAngle: start, endAngle: end)
        path.appendArc(withCenter: centre, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.close()
        (i == 6 ? NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1) : NSColor(white: 1, alpha: 0.16 + 0.05 * CGFloat(i % 2))).setFill()
        path.fill()
    }
    NSColor(white: 1, alpha: 0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 46 * unit, y: centre.y - 46 * unit, width: 92 * unit, height: 92 * unit)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

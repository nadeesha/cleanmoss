import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
var iconChunks = Data()
func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels)
        NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.20, yRadius: s * 0.20).fill()
        NSColor(calibratedRed: 0.89, green: 0.97, blue: 0.81, alpha: 1).setStroke()
        let path = NSBezierPath(); path.lineWidth = s * 0.055; path.lineCapStyle = .round; path.lineJoinStyle = .round
        for (x, y, dx, dy) in [(0.28,0.28,1.0,1.0),(0.72,0.28,-1.0,1.0),(0.28,0.72,1.0,-1.0),(0.72,0.72,-1.0,-1.0)] {
            path.move(to: NSPoint(x: s * (x + dx * 0.12), y: s * y)); path.line(to: NSPoint(x: s * x, y: s * y)); path.line(to: NSPoint(x: s * x, y: s * (y + dy * 0.12)))
        }
        path.stroke()
        NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.48, alpha: 1).setFill()
        let leaf = NSBezierPath(); leaf.move(to: NSPoint(x: s * 0.41, y: s * 0.39))
        leaf.curve(to: NSPoint(x: s * 0.62, y: s * 0.64), controlPoint1: NSPoint(x: s * 0.34, y: s * 0.59), controlPoint2: NSPoint(x: s * 0.50, y: s * 0.66))
        leaf.curve(to: NSPoint(x: s * 0.41, y: s * 0.39), controlPoint1: NSPoint(x: s * 0.68, y: s * 0.42), controlPoint2: NSPoint(x: s * 0.49, y: s * 0.34)); leaf.fill()
        NSGraphicsContext.restoreGraphicsState()
        let type: String
        switch (size, scale) {
        case (16, 1): type = "icp4"
        case (16, 2): type = "ic11"
        case (32, 1): type = "icp5"
        case (32, 2): type = "ic12"
        case (128, 1): type = "ic07"
        case (128, 2): type = "ic13"
        case (256, 1): type = "ic08"
        case (256, 2): type = "ic14"
        case (512, 1): type = "ic09"
        default: type = "ic10"
        }
        let png = rep.representation(using: .png, properties: [:])!
        iconChunks.append(contentsOf: type.utf8)
        appendUInt32(UInt32(png.count + 8), to: &iconChunks)
        iconChunks.append(png)
    }
}
var container = Data("icns".utf8)
appendUInt32(UInt32(iconChunks.count + 8), to: &container)
container.append(iconChunks)
try container.write(to: outputURL, options: .atomic)

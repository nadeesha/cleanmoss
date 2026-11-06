import Foundation
import AppKit
import CleanmossCore

func runAnnotationChecks() throws {
    _ = NSApplication.shared
    try check("Annotation undo, redo, move, delete and branched history") {
        let document = AnnotationDocument(image: annotationFixture())
        let mark = Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)])
        document.add(mark)
        try expectEqual(document.hitTest(CGPoint(x: 15, y: 15))?.id, mark.id)
        let moved = mark.translated(by: CGPoint(x: 30, y: 10))
        document.replace(moved)
        try expectEqual(document.annotations[0].bounds.origin, CGPoint(x: 40, y: 20))
        document.remove(mark.id); try expect(document.annotations.isEmpty, "Deleted mark remains")
        document.undo(); try expectEqual(document.annotations[0].bounds.origin, CGPoint(x: 40, y: 20))
        document.undo(); try expectEqual(document.annotations[0].bounds.origin, CGPoint(x: 10, y: 10))
        document.redo(); try expectEqual(document.annotations[0].bounds.origin, CGPoint(x: 40, y: 20))
        document.undo(); document.add(Annotation(tool: .line, points: [CGPoint(x: 1, y: 1), CGPoint(x: 4, y: 5)]))
        try expect(!document.canRedo, "A new edit must invalidate redo history")
    }
    try check("Line and freehand selection follows strokes rather than empty bounding boxes") {
        let line = Annotation(tool: .line, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 50)])
        try expect(line.contains(CGPoint(x: 50, y: 30)), "Line midpoint was not selectable")
        try expect(!line.contains(CGPoint(x: 20, y: 45), tolerance: 3), "Empty area in line bounding box was selected")
        let pen = Annotation(tool: .pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 50, y: 50)])
        try expect(pen.contains(CGPoint(x: 0, y: 25)), "Freehand stroke was not selectable")
        try expect(!pen.contains(CGPoint(x: 25, y: 25), tolerance: 3), "Empty area in freehand bounding box was selected")
    }
    try check("Resizing transforms freehand geometry and scales text and steps") {
        let path = Annotation(tool: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 15, y: 25), CGPoint(x: 30, y: 30)])
        let resized = path.resized(to: CGRect(x: 0, y: 0, width: 40, height: 60))
        try expectEqual(resized.points[1], CGPoint(x: 10, y: 45))
        let step = Annotation(tool: .step, points: [CGPoint(x: 30, y: 30)], width: 4)
        let bigStep = step.resized(to: CGRect(x: 10, y: 10, width: 72, height: 72))
        try expectEqual(bigStep.bounds.size, CGSize(width: 72, height: 72))
        let text = Annotation(tool: .text, points: [CGPoint(x: 10, y: 10)], width: 4, text: "Note")
        let large = text.resized(to: CGRect(x: 0, y: 0, width: text.bounds.width * 2, height: text.bounds.height * 2))
        try expectEqual(large.width, 8)
    }
    try check("Crop clips to image bounds and is reversible") {
        let document = AnnotationDocument(image: annotationFixture())
        try expect(!document.crop(to: CGRect(x: 300, y: 300, width: 20, height: 20)), "Out-of-image crop was accepted")
        try expect(!document.canUndo, "Invalid crop changed history")
        try expect(document.crop(to: CGRect(x: -10, y: 10, width: 50, height: 30)), "Valid crop rejected")
        try expectEqual(document.cropRect, CGRect(x: 0, y: 10, width: 40, height: 30))
        document.undo(); try expectEqual(document.cropRect, CGRect(x: 0, y: 0, width: 100, height: 60))
        document.redo(); try expectEqual(document.cropRect.width, 40)
    }
    try check("PNG and JPEG preserve original Retina pixel dimensions") {
        for format in ["png", "jpeg"] {
            let output = AnnotationRenderer.render(image: annotationFixture(), annotations: [])
            guard let data = AnnotationRenderer.data(for: output, format: format), let rep = NSBitmapImageRep(data: data) else { throw AnnotationCheckError("Missing encoded \(format)") }
            try expectEqual(rep.pixelsWide, 200); try expectEqual(rep.pixelsHigh, 120)
        }
    }
    try check("Retina crops preserve pixel size and bottom-left document orientation") {
        let output = AnnotationRenderer.render(image: annotationFixture(), annotations: [], cropRect: CGRect(x: 10, y: 40, width: 30, height: 15))
        let rep = try annotationBitmap(output)
        try expectEqual(rep.pixelsWide, 60); try expectEqual(rep.pixelsHigh, 30)
        let color = rep.colorAt(x: 30, y: 15)!.usingColorSpace(.deviceRGB)!
        try expect(color.blueComponent > 0.9 && color.redComponent < 0.1, "Upper crop did not contain the blue upper half")
    }
    try check("All drawing and obscuring tools produce exported pixels") {
        let image = annotationFixture()
        for tool in AnnotationTool.allCases where tool != .select && tool != .crop {
            let mark = Annotation(tool: tool, points: [CGPoint(x: 15, y: 15), CGPoint(x: 70, y: 45)], color: .green, width: 4, text: "NOTE", number: 3)
            let result = AnnotationRenderer.render(image: image, annotations: [mark])
            let original = try annotationBitmap(image), modified = try annotationBitmap(result)
            // Compare decoded pixels rather than compressed bytes or metadata.
            var differences = 0
            for x in stride(from: 0, to: 200, by: 4) { for y in stride(from: 0, to: 120, by: 4) {
                if original.colorAt(x: x, y: y) != modified.colorAt(x: x, y: y) { differences += 1 }
            } }
            try expect(differences > 0, "\(tool.rawValue) had no visible effect")
        }
    }
    try check("Obscuring effects clip to their selected region") {
        let image = annotationFixture()
        let original = try annotationBitmap(image)
        for tool in [AnnotationTool.blur, .pixelate] {
            let mark = Annotation(tool: tool, points: [CGPoint(x: 20, y: 15), CGPoint(x: 65, y: 45)])
            let output = try annotationBitmap(AnnotationRenderer.render(image: image, annotations: [mark]))
            for point in [(0, 0), (180, 110), (180, 55), (20, 50)] {
                try expectEqual(output.colorAt(x: point.0, y: point.1), original.colorAt(x: point.0, y: point.1), "Effect changed pixels outside the selected region")
            }
        }
    }
    try check("Blur and pixelation honor preceding solid redactions") {
        let image = annotationFixture()
        let redact = Annotation(tool: .redact, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60)])
        for effect in [AnnotationTool.blur, .pixelate] {
            let conceal = Annotation(tool: effect, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 50)], width: 4)
            let rep = try annotationBitmap(AnnotationRenderer.render(image: image, annotations: [redact, conceal]))
            let pixel = rep.colorAt(x: 100, y: 60)!.usingColorSpace(.deviceRGB)!
            try expect(pixel.redComponent < 0.01 && pixel.greenComponent < 0.01 && pixel.blueComponent < 0.01, "\(effect.rawValue) resurrected source pixels under a redaction")
        }
    }
    try check("Moved obscuring regions clip at the image edge without stretching") {
        let image = annotationFixture()
        for effect in [AnnotationTool.blur, .pixelate] {
            let offEdge = Annotation(tool: effect, points: [CGPoint(x: -20, y: 10), CGPoint(x: 40, y: 50)], width: 4)
            let clipped = Annotation(tool: effect, points: [CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 50)], width: 4)
            let first = AnnotationRenderer.data(for: AnnotationRenderer.render(image: image, annotations: [offEdge]), format: "png")
            let second = AnnotationRenderer.data(for: AnnotationRenderer.render(image: image, annotations: [clipped]), format: "png")
            try expect(first != nil, "Missing edge effect output")
            try expectEqual(first, second, "\(effect.rawValue) distorted a partially clipped region")
        }
    }
}

private struct AnnotationCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func annotationFixture() -> NSImage {
    let context = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
    context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 60, width: 200, height: 60))
    // Fine contrast detail makes pixelation observable even on otherwise flat halves.
    context.setFillColor(NSColor.white.cgColor)
    for x in stride(from: 40, to: 140, by: 8) { context.fill(CGRect(x: x, y: 35, width: 3, height: 12)) }
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 100, height: 60))
}
private func annotationBitmap(_ image: NSImage) throws -> NSBitmapImageRep {
    guard let data = AnnotationRenderer.data(for: image, format: "png"), let rep = NSBitmapImageRep(data: data) else { throw AnnotationCheckError("Unable to encode test image") }
    return rep
}

import AppKit
import Accelerate

public enum AnnotationTool: String, CaseIterable {
    case select, arrow, line, rectangle, ellipse, pen, text, step, highlight, blur, pixelate, redact, crop
    public var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .text: return "Text"
        case .step: return "Step"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .redact: return "Redact"
        case .crop: return "Crop"
        }
    }
    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .highlight: return "highlighter"
        case .blur: return "drop.halffull"
        case .pixelate: return "square.grid.3x3.fill"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
}

public struct Annotation: Identifiable {
    public let id: UUID
    public var tool: AnnotationTool
    public var points: [CGPoint]
    public var color: NSColor
    public var width: CGFloat
    public var text: String
    public var number: Int
    public init(tool: AnnotationTool, points: [CGPoint], color: NSColor = .systemRed, width: CGFloat = 4, text: String = "", number: Int = 1, id: UUID = UUID()) {
        self.id = id; self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text; self.number = number
    }
    public var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(16, width * 6), weight: .semibold)])
            return CGRect(origin: first, size: size)
        }
        if tool == .step { let radius = max(14, width * 4.5); return CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
    public func contains(_ point: CGPoint, tolerance: CGFloat = 8) -> Bool {
        let padding = max(tolerance, width / 2)
        guard bounds.insetBy(dx: -padding, dy: -padding).contains(point) else { return false }
        if tool == .line || tool == .arrow || tool == .pen {
            for (start, end) in zip(points, points.dropFirst()) {
                let dx = end.x - start.x, dy = end.y - start.y, lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared == 0 ? 0 : min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
                let nearest = CGPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
                if hypot(point.x - nearest.x, point.y - nearest.y) <= padding { return true }
            }
            return false
        }
        return true
    }
    public func resized(to target: CGRect) -> Annotation {
        var copy = self
        let old = bounds
        if tool == .step {
            copy.points = [CGPoint(x: target.midX, y: target.midY)]
            copy.width = max(2, min(target.width, target.height) / 9)
        } else if tool == .text {
            copy.points = [target.origin]
            copy.width = max(2, width * target.height / max(1, old.height))
        } else {
            copy.points = points.map { point in
                CGPoint(x: target.minX + (old.width > 0 ? (point.x - old.minX) / old.width * target.width : 0),
                        y: target.minY + (old.height > 0 ? (point.y - old.minY) / old.height * target.height : 0))
            }
        }
        return copy
    }

    public func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }
}

/// Stores document-space annotations and reversible crops; coordinates are AppKit bottom-left points.
public final class AnnotationDocument {
    public let image: NSImage
    public private(set) var annotations: [Annotation] = []
    public private(set) var cropRect: CGRect
    private struct Snapshot { var annotations: [Annotation]; var cropRect: CGRect }
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    public init(image: NSImage) { self.image = image; cropRect = CGRect(origin: .zero, size: image.size) }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    private var snapshot: Snapshot { Snapshot(annotations: annotations, cropRect: cropRect) }
    private func record() { past.append(snapshot); future.removeAll() }
    public func add(_ annotation: Annotation) { record(); annotations.append(annotation) }
    public func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        record(); annotations[index] = annotation
    }
    public func remove(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        record(); annotations.removeAll { $0.id == id }
    }
    @discardableResult public func crop(to rect: CGRect) -> Bool {
        let clipped = cropRect.intersection(rect.standardized)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return false }
        record(); cropRect = clipped; return true
    }
    public func undo() { guard let state = past.popLast() else { return }; future.append(snapshot); annotations = state.annotations; cropRect = state.cropRect }
    public func redo() { guard let state = future.popLast() else { return }; past.append(snapshot); annotations = state.annotations; cropRect = state.cropRect }
    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 8) -> Annotation? {
        annotations.reversed().first { $0.contains(point, tolerance: tolerance) }
    }
    public func renderedImage() -> NSImage { AnnotationRenderer.render(image: image, annotations: annotations, cropRect: cropRect) }
}

public enum AnnotationRenderer {
    public static func render(image: NSImage, annotations: [Annotation], cropRect: CGRect? = nil) -> NSImage {
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let sx = CGFloat(original.width) / image.size.width, sy = CGFloat(original.height) / image.size.height
        context.scaleBy(x: sx, y: sy)
        context.draw(original, in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in annotations {
            // Effects see all preceding edits. A blur over a solid redaction can never restore source pixels.
            let composite = (annotation.tool == .blur || annotation.tool == .pixelate) ? context.makeImage().map { NSImage(cgImage: $0, size: image.size) } : nil
            draw(annotation, source: composite ?? image)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let full = context.makeImage() else { return image }
        let crop = (cropRect ?? CGRect(origin: .zero, size: image.size)).intersection(CGRect(origin: .zero, size: image.size))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return NSImage(cgImage: full, size: image.size) }
        // CGImage cropping uses a top-left origin; annotation coordinates use bottom-left.
        let pixels = CGRect(x: crop.minX * sx, y: (image.size.height - crop.maxY) * sy, width: crop.width * sx, height: crop.height * sy).integral
        guard let cropped = full.cropping(to: pixels) else { return NSImage(cgImage: full, size: image.size) }
        return NSImage(cgImage: cropped, size: crop.size)
    }
    public static func draw(_ annotation: Annotation, source: NSImage) {
        guard let start = annotation.points.first else { return }
        let end = annotation.points.last ?? start
        let rect = annotation.bounds
        annotation.color.setStroke(); annotation.color.setFill()
        let path = NSBezierPath(); path.lineWidth = annotation.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch annotation.tool {
        case .select, .crop: break
        case .line, .arrow:
            path.move(to: start); path.line(to: end); path.stroke()
            if annotation.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x), head = max(14, annotation.width * 4)
                let headPath = NSBezierPath()
                headPath.move(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
                headPath.line(to: end)
                headPath.line(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
                headPath.lineWidth = annotation.width; headPath.lineCapStyle = .round; headPath.lineJoinStyle = .round; headPath.stroke()
            }
        case .rectangle: NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).withWidth(annotation.width).stroke()
        case .ellipse: NSBezierPath(ovalIn: rect).withWidth(annotation.width).stroke()
        case .pen:
            path.move(to: start); for point in annotation.points.dropFirst() { path.line(to: point) }; path.stroke()
        case .text:
            (annotation.text as NSString).draw(at: start, withAttributes: [.font: NSFont.systemFont(ofSize: max(16, annotation.width * 6), weight: .semibold), .foregroundColor: annotation.color])
        case .step:
            NSBezierPath(ovalIn: rect).fill()
            let label = "\(annotation.number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(15, annotation.width * 4.75), weight: .bold), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), withAttributes: attributes)
        case .highlight: annotation.color.withAlphaComponent(0.28).setFill(); NSBezierPath(rect: rect).fill()
        case .redact: NSColor.black.setFill(); NSBezierPath(rect: rect).fill()
        case .blur, .pixelate:
            guard rect.width > 0, rect.height > 0, let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let sx = CGFloat(sourceCG.width) / source.size.width, sy = CGFloat(sourceCG.height) / source.size.height
            let pixels = CGRect(x: rect.minX * sx, y: (source.size.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy).integral.intersection(CGRect(x: 0, y: 0, width: sourceCG.width, height: sourceCG.height))
            guard !pixels.isNull, pixels.width > 0, pixels.height > 0 else { return }
            let destination = CGRect(x: pixels.minX / sx, y: source.size.height - pixels.maxY / sy, width: pixels.width / sx, height: pixels.height / sy)
            if let cg = obscuredImage(sourceCG, region: pixels, pixelate: annotation.tool == .pixelate, strength: max(12, annotation.width * 5) * sx) {
                NSImage(cgImage: cg, size: destination.size).draw(in: destination)
            } else {
                // Keep private pixels concealed even if an effect cannot allocate its working buffers.
                NSColor.black.setFill(); NSBezierPath(rect: destination).fill()
            }

        }
    }
    /// CPU rendering avoids depending on a Metal/Core Image device, including on headless Macs.
    private static func obscuredImage(_ source: CGImage, region: CGRect, pixelate: Bool, strength: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let padding = pixelate ? 0 : ceil(strength * 2)
        let workRect = region.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral
        guard let section = source.cropping(to: workRect),
              let input = CGContext(data: nil, width: section.width, height: section.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGContext(data: nil, width: section.width, height: section.height, bitsPerComponent: 8, bytesPerRow: input.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let inputData = input.data, let outputData = output.data else { return nil }
        input.draw(section, in: CGRect(x: 0, y: 0, width: section.width, height: section.height))
        if pixelate {
            let block = max(4, Int(strength))
            let src = inputData.assumingMemoryBound(to: UInt8.self), dst = outputData.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: 0, to: section.height, by: block) {
                for x in stride(from: 0, to: section.width, by: block) {
                    let maxX = min(x + block, section.width), maxY = min(y + block, section.height)
                    var sum = [Int](repeating: 0, count: 4)
                    for py in y..<maxY { for px in x..<maxX {
                        let index = py * input.bytesPerRow + px * 4
                        for channel in 0..<4 { sum[channel] += Int(src[index + channel]) }
                    } }
                    let count = (maxX - x) * (maxY - y)
                    for py in y..<maxY { for px in x..<maxX {
                        let index = py * output.bytesPerRow + px * 4
                        for channel in 0..<4 { dst[index + channel] = UInt8(sum[channel] / count) }
                    } }
                }
            }
        } else {
            var src = vImage_Buffer(data: inputData, height: vImagePixelCount(section.height), width: vImagePixelCount(section.width), rowBytes: input.bytesPerRow)
            var dst = vImage_Buffer(data: outputData, height: vImagePixelCount(section.height), width: vImagePixelCount(section.width), rowBytes: output.bytesPerRow)
            let limit = max(1, min(section.width, section.height))
            let kernel = UInt32(max(1, min(Int(strength), limit) / 2 * 2 - 1))
            // Three box passes approximate a Gaussian while preserving alpha and running in linear time.
            for pass in 0..<3 {
                guard vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return nil }
                if pass < 2 { swap(&src, &dst) }
            }
        }
        guard let result = output.makeImage() else { return nil }
        let local = CGRect(x: region.minX - workRect.minX, y: region.minY - workRect.minY, width: region.width, height: region.height).intersection(CGRect(x: 0, y: 0, width: section.width, height: section.height))
        return result.cropping(to: local)
    }
    public static func data(for image: NSImage, format: String) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: format == "jpeg" ? .jpeg : .png, properties: format == "jpeg" ? [.compressionFactor: 0.92] : [:])
    }
}

private extension NSBezierPath {
    func withWidth(_ width: CGFloat) -> NSBezierPath { lineWidth = width; return self }
}

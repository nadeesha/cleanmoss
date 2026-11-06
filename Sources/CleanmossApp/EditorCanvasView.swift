import AppKit
import CleanmossCore

@MainActor
final class EditorCanvasView: NSView {
    let document: AnnotationDocument
    var tool: AnnotationTool = .arrow { didSet { draft = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var color: NSColor = .systemRed
    var strokeWidth: CGFloat = 4
    var zoom: CGFloat = 1
    var onChange: (() -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var onText: ((String?) -> String)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    private var selectedID: UUID?
    private var dragStart: CGPoint?
    private var originalSelection: Annotation?
    private var resizeAnchor: CGPoint?
    private var draft: Annotation?
    private var cached: NSImage
    private var didDrag = false
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    private var imageOrigin: CGPoint {
        CGPoint(x: max(24, (bounds.width - document.cropRect.width * zoom) / 2), y: max(24, (bounds.height - document.cropRect.height * zoom) / 2))
    }
    init(document: AnnotationDocument) {
        self.document = document; cached = document.image
        super.init(frame: CGRect(origin: .zero, size: document.image.size))
        setAccessibilityLabel("Capture annotation canvas")
        setAccessibilityHelp("Use the toolbar to choose a drawing tool. Drag on the image to annotate. Select a mark to move it or press Delete to remove it.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() { cached = AnnotationRenderer.render(image: document.image, annotations: document.annotations); needsDisplay = true }
    func clearSelection() { selectedID = nil; draft = nil; originalSelection = nil; dragStart = nil; resizeAnchor = nil }
    func applyStyleToSelection() {
        if let id = selectedID, var annotation = document.annotations.first(where: { $0.id == id }) {
            annotation.color = color; annotation.width = strokeWidth; document.replace(annotation); onChange?()
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .select ? .arrow : .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.12, green: 0.15, blue: 0.14, alpha: 1).setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = imageOrigin, crop = document.cropRect
        let imageRect = CGRect(origin: origin, size: CGSize(width: crop.width * zoom, height: crop.height * zoom))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        NSColor.white.setFill(); imageRect.fill()
        context.restoreGState()
        context.saveGState(); context.clip(to: imageRect)
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: zoom, y: zoom); context.translateBy(x: -crop.minX, y: -crop.minY)
        cached.draw(in: CGRect(origin: .zero, size: document.image.size))
        if let draft {
            if draft.tool == .crop {
                let region = draft.bounds.intersection(crop)
                NSColor.black.withAlphaComponent(0.4).setFill()
                let outside = NSBezierPath(rect: crop); outside.append(NSBezierPath(rect: region)); outside.windingRule = .evenOdd; outside.fill()
                NSColor.white.setStroke(); let border = NSBezierPath(rect: region); border.lineWidth = 1 / zoom; border.setLineDash([6 / zoom, 4 / zoom], count: 2, phase: 0); border.stroke()
                let label = "\(Int(region.width)) × \(Int(region.height))" as NSString
                label.draw(at: CGPoint(x: region.minX + 8 / zoom, y: region.minY + 8 / zoom), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12 / zoom, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)])
            } else { AnnotationRenderer.draw(draft, source: cached) }
        }
        if let id = selectedID, let annotation = draft ?? document.annotations.first(where: { $0.id == id }) {
            let selection = annotation.bounds
            let moss = NSColor(srgbRed: 0.29, green: 0.43, blue: 0.31, alpha: 1)
            let border = NSBezierPath(rect: selection)
            NSColor.white.setStroke(); border.lineWidth = 3.5 / zoom; border.stroke()
            moss.setStroke(); border.lineWidth = 1.5 / zoom; border.setLineDash([5 / zoom, 4 / zoom], count: 2, phase: 0); border.stroke()
            for point in [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)] {
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 4 / zoom, y: point.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom))
                moss.setFill(); handle.fill(); NSColor.white.setStroke(); handle.lineWidth = 1.5 / zoom; handle.stroke()
            }
        }
        context.restoreGState()
    }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), origin = imageOrigin
        return CGPoint(x: (point.x - origin.x) / zoom + document.cropRect.minX, y: (point.y - origin.y) / zoom + document.cropRect.minY)
    }
    private func clamped(_ point: CGPoint) -> CGPoint {
        let rect = document.cropRect
        return CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        guard document.cropRect.contains(point) else { clearSelection(); needsDisplay = true; return }
        dragStart = point; didDrag = false; resizeAnchor = nil
        switch tool {
        case .select:
            if let selectedID, let selected = document.annotations.first(where: { $0.id == selectedID }) {
                let bounds = selected.bounds
                let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                if let corner = corners.first(where: { hypot($0.x - point.x, $0.y - point.y) < 10 / zoom }) {
                    resizeAnchor = CGPoint(x: corner.x == bounds.minX ? bounds.maxX : bounds.minX, y: corner.y == bounds.minY ? bounds.maxY : bounds.minY)
                }
            }
            if resizeAnchor == nil { selectedID = document.hitTest(point, tolerance: 8 / zoom)?.id }
            originalSelection = document.annotations.first { $0.id == selectedID }
            if event.clickCount == 2, var annotation = originalSelection, annotation.tool == .text {
                annotation.text = onText?(annotation.text) ?? annotation.text
                document.replace(annotation); originalSelection = nil; onChange?()
            }
        case .text:
            let text = onText?(nil) ?? ""
            if !text.isEmpty { document.add(Annotation(tool: .text, points: [point], color: color, width: strokeWidth, text: text)); onChange?() }
            dragStart = nil
        case .step:
            let number = (document.annotations.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1
            document.add(Annotation(tool: .step, points: [point], color: color, width: strokeWidth, number: number)); onChange?(); dragStart = nil
        default:
            selectedID = nil; draft = Annotation(tool: tool, points: [point, point], color: color, width: strokeWidth)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var point = clamped(imagePoint(event)); didDrag = true
        if tool == .select, let originalSelection {
            cached = AnnotationRenderer.render(image: document.image, annotations: document.annotations.filter { $0.id != originalSelection.id })
            if let resizeAnchor {
                let target = CGRect(x: min(point.x, resizeAnchor.x), y: min(point.y, resizeAnchor.y), width: max(2, abs(point.x - resizeAnchor.x)), height: max(2, abs(point.y - resizeAnchor.y)))
                draft = originalSelection.resized(to: target)
            } else { draft = originalSelection.translated(by: CGPoint(x: point.x - start.x, y: point.y - start.y)) }
        } else if var annotation = draft {
            if event.modifierFlags.contains(.shift), [.arrow, .line, .rectangle, .ellipse, .crop].contains(tool) {
                let dx = point.x - start.x, dy = point.y - start.y
                if tool == .line || tool == .arrow {
                    let length = hypot(dx, dy), angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                    point = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
                } else {
                    let length = max(abs(dx), abs(dy)); point = CGPoint(x: start.x + (dx < 0 ? -length : length), y: start.y + (dy < 0 ? -length : length))
                }
                point = clamped(point)
            }
            if tool == .pen { annotation.points.append(point) } else { annotation.points = [start, point] }
            draft = annotation
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; originalSelection = nil; resizeAnchor = nil; draft = nil; needsDisplay = true }
        guard let annotation = draft, didDrag else { return }
        if tool == .select { document.replace(annotation) }
        else if tool == .crop { _ = document.crop(to: annotation.bounds) }
        else if annotation.points.count > 2 || hypot((annotation.points.last?.x ?? 0) - (annotation.points.first?.x ?? 0), (annotation.points.last?.y ?? 0) - (annotation.points.first?.y ?? 0)) >= 2 { document.add(annotation) }
        onChange?()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": onCopy?()
        case "s": onSave?()
        case "z": if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }; clearSelection(); onChange?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode),
           let selectedID, let selected = document.annotations.first(where: { $0.id == selectedID }) {
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -amount : (event.keyCode == 124 ? amount : 0), y: event.keyCode == 125 ? -amount : (event.keyCode == 126 ? amount : 0))
            document.replace(selected.translated(by: delta)); onChange?(); return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if let selectedID { document.remove(selectedID); clearSelection(); onChange?() }; return
        }
        if event.keyCode == 53 { clearSelection(); refresh(); return }
        let tools: [String: AnnotationTool] = ["v": .select, "a": .arrow, "l": .line, "r": .rectangle, "e": .ellipse, "p": .pen, "t": .text, "n": .step, "h": .highlight, "b": .blur, "x": .pixelate, "d": .redact, "c": .crop]
        if let key = event.charactersIgnoringModifiers?.lowercased(), let next = tools[key] { onToolChange?(next) } else { super.keyDown(with: event) }
    }
    @objc func undo(_ sender: Any?) { document.undo(); clearSelection(); onChange?() }
    @objc func redo(_ sender: Any?) { document.redo(); clearSelection(); onChange?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
}

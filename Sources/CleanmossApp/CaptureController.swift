import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class CaptureController {
    private var overlays: [CaptureOverlayWindow] = []
    private var completion: ((Result<NSImage, Error>) -> Void)?
    private var captureTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    func capture(completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        generation &+= 1
        let request = generation
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            finish(.failure(CaptureError.permissionDenied))
            return
        }
        let screens = NSScreen.screens
        captureTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var frames: [(NSScreen, CGImage)] = []
                for screen in screens {
                    try Task.checkCancellation()
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
                    configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    frames.append((screen, image))
                }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                guard !frames.isEmpty else { throw CaptureError.noDisplays }
                self.present(frames)
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.finish(.failure(CaptureError.captureFailed(error.localizedDescription)))
            }
        }
    }

    func cancel() {
        guard completion != nil else { return }
        finish(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "Capture cancelled."])))
    }

    private func present(_ frames: [(NSScreen, CGImage)]) {
        // All displays are frozen before any overlay appears, keeping our own UI out of the capture.
        overlays = frames.map { screen, image in
            let window = CaptureOverlayWindow(screen: screen)
            let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelect = { [weak self] rect in
                let scaleX = CGFloat(image.width) / screen.frame.width
                let scaleY = CGFloat(image.height) / screen.frame.height
                let pixels = CGRect(x: floor(rect.minX * scaleX), y: floor(rect.minY * scaleY), width: ceil(rect.maxX * scaleX) - floor(rect.minX * scaleX), height: ceil(rect.maxY * scaleY) - floor(rect.minY * scaleY)).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let cropped = image.cropping(to: pixels) else { self?.finish(.failure(CaptureError.invalidSelection)); return }
                self?.finish(.success(NSImage(cgImage: cropped, size: NSSize(width: pixels.width / scaleX, height: pixels.height / scaleY))))
            }
            window.contentView = view
            window.makeFirstResponder(view)
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in overlays { window.orderFrontRegardless() }
        let point = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(point) } ?? overlays.first)?.makeKey()
    }

    private func finish(_ result: Result<NSImage, Error>) {
        generation &+= 1
        captureTask?.cancel()
        captureTask = nil
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays.removeAll()
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private enum CaptureError: LocalizedError {
    case permissionDenied, noDisplays, invalidSelection, captureFailed(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Allow Cleanmoss in System Settings → Privacy & Security → Screen Recording (or Screen & System Audio Recording), then quit and reopen Cleanmoss. You can open this setting with cleanmoss permissions."
        case .noDisplays: return "No available display was found. Connect or wake a display and try again."
        case .invalidSelection: return "The selected area could not be captured. Drag a larger rectangle and try again."
        case .captureFailed(let detail): return "macOS could not capture the display. Check Cleanmoss’s Screen Recording permission, then quit and reopen it. \(detail)"
        }
    }
}

@MainActor
private final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        isExcludedFromWindowsMenu = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureOverlayView: NSView {
    private let frozen: NSImage
    private var anchor: NSPoint?
    private var selection = NSRect.zero
    private var tracking: NSTrackingArea?
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, image: CGImage) {
        frozen = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture area. Drag a rectangle on this display. Press Escape to cancel.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); NSCursor.crosshair.set() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        anchor = constrained(convert(event.locationInWindow, from: nil))
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let end = constrained(convert(event.locationInWindow, from: nil))
        selection = NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: abs(anchor.x - end.x), height: abs(anchor.y - end.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
        if selection.width >= 2, selection.height >= 2 { onSelect?(selection) }
        else { selection = .zero; needsDisplay = true }
    }
    private func constrained(_ point: NSPoint) -> NSPoint {
        NSPoint(x: max(bounds.minX, min(bounds.maxX, point.x)), y: max(bounds.minY, min(bounds.maxY, point.y)))
    }
    override func draw(_ dirtyRect: NSRect) {
        frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        if selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1.5; outline.stroke()
            NSColor(calibratedRed: 0.60, green: 0.87, blue: 0.66, alpha: 1).setStroke()
            let accent = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1)); accent.lineWidth = 1; accent.stroke()
            badge("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))", near: NSPoint(x: selection.midX, y: selection.maxY + 14))
        } else {
            badge("Drag to capture an area  ·  Esc to cancel", near: NSPoint(x: bounds.midX, y: 52))
        }
    }
    private func badge(_ text: String, near point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = size.width + 26
        let rect = NSRect(x: min(max(12, point.x - width / 2), bounds.width - width - 12), y: min(max(12, point.y), bounds.height - size.height - 28), width: width, height: size.height + 16)
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.12, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 13, y: rect.minY + 8), withAttributes: attributes)
    }
}

import AppKit
import CleanmossCore
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let captureDocument: AnnotationDocument
    private var configuration: Configuration
    private var hasUnsavedChanges = false
    private var canvas: EditorCanvasView!
    private var scroll: NSScrollView!
    private var toolButtons: [NSButton] = []
    private let hint = NSTextField(labelWithString: "")
    private let dimensions = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var widthLabel = NSTextField(labelWithString: "4 pt")
    private var fitMode = true
    private var resizeObserver: NSObjectProtocol?
    private var zoom: CGFloat = 1
    private static let moss = NSColor(srgbRed: 0.29, green: 0.43, blue: 0.31, alpha: 1)
    private static let cream = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1)

    init(image: NSImage, configuration: Configuration) {
        captureDocument = AnnotationDocument(image: image)
        self.configuration = configuration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Cleanmoss — Capture"
        window.subtitle = "A little clarity goes a long way."
        window.minSize = NSSize(width: 870, height: 700)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.cream
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        window.center()
        resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.fitMode == true { self?.fitCanvas() } }
        }
        scroll.contentView.postsFrameChangedNotifications = true
        DispatchQueue.main.async { [weak self] in self?.fitCanvas(); self?.window?.makeFirstResponder(self?.canvas) }
        if configuration.copyOnCapture { copyImage(nil) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 10; header.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        let brand = NSTextField(labelWithString: "CLEANMOSS"); brand.font = .systemFont(ofSize: 13, weight: .bold); brand.textColor = Self.moss
        header.addArrangedSubview(brand)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); dimensions.textColor = .secondaryLabelColor
        header.addArrangedSubview(dimensions); header.addArrangedSubview(spacer())
        undoButton = actionButton("Undo", symbol: "arrow.uturn.backward", action: #selector(undoEdit(_:))); undoButton.keyEquivalent = "z"; undoButton.keyEquivalentModifierMask = [.command]
        redoButton = actionButton("Redo", symbol: "arrow.uturn.forward", action: #selector(redoEdit(_:))); redoButton.keyEquivalent = "z"; redoButton.keyEquivalentModifierMask = [.command, .shift]
        header.addArrangedSubview(undoButton); header.addArrangedSubview(redoButton)
        header.addArrangedSubview(actionButton("Fit", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(fitAction(_:))))
        header.addArrangedSubview(actionButton("100%", symbol: "1.magnifyingglass", action: #selector(actualSize(_:))))
        let copy = actionButton("Copy", symbol: "doc.on.doc", action: #selector(copyImage(_:))); copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = [.command]; header.addArrangedSubview(copy)
        let save = actionButton("Save…", symbol: "square.and.arrow.down", action: #selector(saveImage(_:))); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]; save.bezelColor = Self.moss; save.contentTintColor = .white; header.addArrangedSubview(save)
        root.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(separator())

        let work = NSStackView(); work.orientation = .horizontal; work.spacing = 0
        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.spacing = 3; sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let button = NSButton(title: tool.title, target: self, action: #selector(chooseTool(_:)))
            button.tag = index; button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title); button.imagePosition = .imageLeading
            button.alignment = .left; button.font = .systemFont(ofSize: 12, weight: .medium); button.bezelStyle = .regularSquare; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            button.setAccessibilityLabel("\(tool.title) tool"); button.toolTip = tool.title
            button.heightAnchor.constraint(equalToConstant: 33).isActive = true; button.widthAnchor.constraint(equalToConstant: 110).isActive = true
            sidebar.addArrangedSubview(button); toolButtons.append(button)
        }
        sidebar.addArrangedSubview(spacer())
        work.addArrangedSubview(sidebar)
        scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.14, alpha: 1)
        canvas = EditorCanvasView(document: captureDocument)
        canvas.onChange = { [weak self] in self?.documentChanged() }
        canvas.onToolChange = { [weak self] tool in self?.selectTool(tool) }
        canvas.onText = { [weak self] existing in self?.requestText(existing: existing) ?? "" }
        canvas.onCopy = { [weak self] in self?.copyImage(nil) }
        canvas.onSave = { [weak self] in self?.saveImage(nil) }
        scroll.documentView = canvas
        work.addArrangedSubview(scroll)
        root.addArrangedSubview(work)
        work.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        sidebar.widthAnchor.constraint(equalToConstant: 134).isActive = true
        sidebar.heightAnchor.constraint(equalTo: work.heightAnchor).isActive = true
        scroll.heightAnchor.constraint(equalTo: work.heightAnchor).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        root.addArrangedSubview(separator())

        let inspector = NSStackView(); inspector.orientation = .horizontal; inspector.spacing = 10; inspector.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        let colorLabel = NSTextField(labelWithString: "INK"); colorLabel.font = .systemFont(ofSize: 10, weight: .bold); colorLabel.textColor = .secondaryLabelColor; inspector.addArrangedSubview(colorLabel)
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, Self.moss, .systemBlue, .systemPurple, .white, .black]
        for (index, color) in colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(chooseColor(_:)))
            button.tag = index; button.bezelStyle = .regularSquare; button.isBordered = false; button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor; button.layer?.cornerRadius = 10; button.layer?.borderWidth = 1; button.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true; button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            button.setAccessibilityLabel(["Red", "Orange", "Yellow", "Moss", "Blue", "Purple", "White", "Black"][index] + " ink")
            inspector.addArrangedSubview(button)
        }
        let well = NSColorWell(); well.color = .systemRed; well.target = self; well.action = #selector(customColor(_:)); well.colorWellStyle = .minimal
        well.widthAnchor.constraint(equalToConstant: 28).isActive = true; well.heightAnchor.constraint(equalToConstant: 24).isActive = true; well.setAccessibilityLabel("Custom annotation color"); inspector.addArrangedSubview(well)
        let thickness = NSTextField(labelWithString: "SIZE"); thickness.font = .systemFont(ofSize: 10, weight: .bold); thickness.textColor = .secondaryLabelColor; inspector.addArrangedSubview(thickness)
        let slider = NSSlider(value: 4, minValue: 2, maxValue: 12, target: self, action: #selector(changeWidth(_:))); slider.widthAnchor.constraint(equalToConstant: 100).isActive = true; slider.setAccessibilityLabel("Annotation thickness"); inspector.addArrangedSubview(slider)
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); widthLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true; inspector.addArrangedSubview(widthLabel)
        inspector.addArrangedSubview(spacer()); zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); zoomLabel.textColor = .secondaryLabelColor; inspector.addArrangedSubview(zoomLabel)
        root.addArrangedSubview(inspector); inspector.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let footer = NSStackView(); footer.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 12, right: 20)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; footer.addArrangedSubview(hint); footer.addArrangedSubview(spacer())
        root.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        selectTool(.arrow); documentChanged(markDirty: false)
    }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); view.setContentHuggingPriority(.defaultLow, for: .vertical); return view }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading; button.font = .systemFont(ofSize: 11, weight: .medium); button.setAccessibilityLabel(title); return button
    }
    private func selectTool(_ tool: AnnotationTool) {
        canvas.tool = tool
        for (index, button) in toolButtons.enumerated() {
            let active = AnnotationTool.allCases[index] == tool
            button.layer?.backgroundColor = (active ? Self.moss.withAlphaComponent(0.12) : .clear).cgColor
            button.contentTintColor = active ? Self.moss : .labelColor
        }
        switch tool {
        case .select: hint.stringValue = "Drag to move • Drag corners to resize • Arrow keys to nudge • Delete to remove • Double-click text to edit"
        case .text: hint.stringValue = "Click anywhere to add text • Choose ink and size below"
        case .step: hint.stringValue = "Click to add numbered steps • Numbers advance automatically"
        case .crop: hint.stringValue = "Drag to crop • Undo restores the full capture"
        case .blur, .pixelate: hint.stringValue = "Drag over an area to obscure it • For sensitive information, use Redact"
        case .redact: hint.stringValue = "Drag over private information to cover it with solid black"
        default: hint.stringValue = "Drag to draw \(tool.title.lowercased()) • Hold Shift for straight lines or square shapes • ⌘Z undo"
        }
        window?.makeFirstResponder(canvas)
    }
    @objc private func chooseTool(_ sender: NSButton) { selectTool(AnnotationTool.allCases[sender.tag]) }
    @objc private func chooseColor(_ sender: NSButton) {
        canvas.color = [.systemRed, .systemOrange, .systemYellow, Self.moss, .systemBlue, .systemPurple, .white, .black][sender.tag]
        canvas.applyStyleToSelection()
    }
    @objc private func customColor(_ sender: NSColorWell) { canvas.color = sender.color; canvas.applyStyleToSelection() }
    @objc private func changeWidth(_ sender: NSSlider) { canvas.strokeWidth = CGFloat(sender.intValue); widthLabel.stringValue = "\(sender.intValue) pt"; canvas.applyStyleToSelection() }
    @objc private func undoEdit(_ sender: Any?) { captureDocument.undo(); canvas.clearSelection(); documentChanged() }
    @objc private func redoEdit(_ sender: Any?) { captureDocument.redo(); canvas.clearSelection(); documentChanged() }
    @objc private func fitAction(_ sender: Any?) { fitMode = true; fitCanvas() }
    @objc private func actualSize(_ sender: Any?) { fitMode = false; applyZoom(1) }
    private func fitCanvas() {
        let available = scroll.contentView.bounds.size, size = captureDocument.cropRect.size
        guard available.width > 0, available.height > 0 else { return }
        applyZoom(min(1, min((available.width - 50) / size.width, (available.height - 50) / size.height)))
    }
    private func applyZoom(_ value: CGFloat) {
        zoom = max(0.05, value); canvas.zoom = zoom
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: max(scroll.contentView.bounds.width, captureDocument.cropRect.width * zoom + 48), height: max(scroll.contentView.bounds.height, captureDocument.cropRect.height * zoom + 48)))
        zoomLabel.stringValue = "\(Int(zoom * 100))%"; canvas.needsDisplay = true
    }
    private func documentChanged(markDirty: Bool = true) {
        if markDirty { hasUnsavedChanges = true; window?.isDocumentEdited = true }
        canvas.refresh(); undoButton.isEnabled = captureDocument.canUndo; redoButton.isEnabled = captureDocument.canRedo
        if let source = captureDocument.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let imageSize = captureDocument.image.size, crop = captureDocument.cropRect
            let sx = CGFloat(source.width) / imageSize.width, sy = CGFloat(source.height) / imageSize.height
            let pixels = CGRect(x: crop.minX * sx, y: (imageSize.height - crop.maxY) * sy, width: crop.width * sx, height: crop.height * sy).integral
            dimensions.stringValue = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
        }
        if fitMode { fitCanvas() } else { applyZoom(zoom) }
    }
    private func requestText(existing: String?) -> String {
        let alert = NSAlert(); alert.messageText = existing == nil ? "Add a note" : "Edit your note"; alert.informativeText = "Keep it short, make it clear."
        let input = NSTextField(string: existing ?? ""); input.frame = CGRect(x: 0, y: 0, width: 360, height: 64); input.lineBreakMode = .byWordWrapping; input.maximumNumberOfLines = 3
        alert.accessoryView = input; alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : (existing ?? "")
    }
    @objc private func copyImage(_ sender: Any?) {
        copyToClipboard()
    }
    @discardableResult
    private func copyToClipboard() -> Bool {
        guard ImageClipboard.write(captureDocument.renderedImage()) else {
            showEditorError(EditorError.clipboard)
            return false
        }
        hint.stringValue = "Copied to clipboard. Ready to paste."
        markClean()
        return true
    }
    @objc private func saveImage(_ sender: Any?) {
        let exportFormat = configuration.format
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.timeZone = .current; dateFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Cleanmoss \(dateFormatter.string(from: Date()))"
        panel.allowedContentTypes = exportFormat == "jpeg" ? [.jpeg] : [.png]
        let directory = URL(fileURLWithPath: configuration.outputDirectory)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); panel.directoryURL = directory }
        catch { showEditorError(error); return }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                guard let data = AnnotationRenderer.data(for: self.captureDocument.renderedImage(), format: exportFormat) else { throw EditorError.encoding }
                try data.write(to: url, options: .atomic); self.hint.stringValue = "Saved \(url.lastPathComponent)."; self.markClean()
            } catch { self.showEditorError(error) }
        }
    }
    func updateConfiguration(_ configuration: Configuration) { self.configuration = configuration }
    private func markClean() { hasUnsavedChanges = false; window?.isDocumentEdited = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.messageText = "Keep your annotations?"; alert.informativeText = "Copy the capture before closing, or discard these edits. You can also cancel and save a file."
        alert.addButton(withTitle: "Copy & Close"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return copyToClipboard()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    private func showEditorError(_ error: Error) { let alert = NSAlert(error: error); if let window { alert.beginSheetModal(for: window) } }
}
private enum EditorError: LocalizedError {
    case encoding, clipboard
    var errorDescription: String? {
        switch self {
        case .encoding: return "The capture could not be encoded. Try copying it to the clipboard."
        case .clipboard: return "The capture could not be copied. Try saving it to a file."
        }
    }
}

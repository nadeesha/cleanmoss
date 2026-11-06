import AppKit
import CleanmossCore
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKeyController?
    private let captureController = CaptureController()
    private var editors: [EditorWindowController] = []
    private var welcomeWindow: NSWindow?
    private var configuration = Configuration()
    private var shortcutError: String?
    private var captureItem: NSMenuItem?
    private var configurationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Cleanmoss area capture")
        statusItem.button?.toolTip = "Cleanmoss · Capture, clarify, share"
        buildStatusMenu()
        reloadConfiguration()
        configurationObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.cleanmoss.configurationChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadConfiguration() }
        }
        if CommandLine.arguments.contains("--demo") {
            openEditor(image: makeDemoImage())
        } else if CommandLine.arguments.contains("--capture") {
            capture()
        } else if !CommandLine.arguments.contains("--background") {
            showWelcome()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for editor in editors where editor.window?.isVisible == true {
            if let window = editor.window, !editor.windowShouldClose(window) { return .terminateCancel }
        }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "cleanmoss" {
                if url.host == "capture" { capture() }
            } else if let image = NSImage(contentsOf: url) {
                openEditor(image: image)
            } else {
                showError("This file could not be opened as an image.")
            }
        }
    }

    private func buildApplicationMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cleanmoss", action: #selector(showWelcome), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cleanmoss", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let fileMenu = NSMenu(title: "File")
        let captureMenu = fileMenu.addItem(withTitle: "Capture area", action: #selector(capture), keyEquivalent: "")
        captureMenu.target = self
        let openMenu = fileMenu.addItem(withTitle: "Open image…", action: #selector(openImage), keyEquivalent: "o")
        openMenu.target = self
        let exampleMenu = fileMenu.addItem(withTitle: "Try the editor with an example", action: #selector(openExample), keyEquivalent: "")
        exampleMenu.target = self
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undo.target = nil
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = editMenu; menu.addItem(editItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    private func buildStatusMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "CLEANMOSS", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let item = NSMenuItem(title: "Capture area", action: #selector(capture), keyEquivalent: "")
        item.target = self; menu.addItem(item); captureItem = item
        let open = NSMenuItem(title: "Open image…", action: #selector(openImage), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "Getting started", action: #selector(showWelcome), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let folder = NSMenuItem(title: "Show saved captures", action: #selector(showOutputFolder), keyEquivalent: "")
        folder.target = self; menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cleanmoss", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func reloadConfiguration() {
        do {
            configuration = try ConfigurationStore.load()
            for editor in editors { editor.updateConfiguration(configuration) }
            hotKey = nil
            if !CommandLine.arguments.contains("--demo") {
                hotKey = try HotKeyController(shortcut: configuration.shortcut) { [weak self] in self?.capture() }
            }
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
            // The menu-bar capture remains available even if a shortcut is occupied.
            showError("Cleanmoss needs attention", detail: error.localizedDescription + "\n\nCapture is still available from the menu bar. Run cleanmoss doctor to check the installation.")
        }
        let display = (try? Shortcut.parse(configuration.shortcut).display) ?? configuration.shortcut
        captureItem?.title = "Capture area    \(display)"
        statusItem.button?.toolTip = "Cleanmoss · \(display) to capture an area"
    }

    @objc private func capture() {
        welcomeWindow?.orderOut(nil)
        captureController.capture { [weak self] result in
            switch result {
            case .success(let image): self?.openEditor(image: image)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { self?.showError("Couldn’t capture this area", detail: error.localizedDescription) }
            }
        }
    }

    private func openEditor(image: NSImage) {
        editors.removeAll { $0.window?.isVisible == false }
        let editor = EditorWindowController(image: image, configuration: configuration)
        editors.append(editor)
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) { openEditor(image: image) }
    }

    @objc private func openExample() {
        welcomeWindow?.orderOut(nil)
        openEditor(image: makeDemoImage())
    }

    @objc private func showOutputFolder() {
        let url = URL(fileURLWithPath: configuration.outputDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func showWelcome() {
        if let window = welcomeWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cleanmoss"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.94, alpha: 1)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 40), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -40), stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)])
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color; return label
        }
        stack.addArrangedSubview(label("◈  CLEANMOSS", size: 13, weight: .bold, color: NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.24, alpha: 1)))
        stack.addArrangedSubview(label("A little clarity.\nOne shortcut away.", size: 35, weight: .bold))
        stack.addArrangedSubview(label("Drag around what matters. Blur the private bits, add a little context, and share a beautifully clear capture.", size: 15, weight: .regular, color: .secondaryLabelColor))
        let shortcut = (try? Shortcut.parse(configuration.shortcut).display) ?? "⇧⌘4"
        stack.addArrangedSubview(label("\(shortcut)    Capture an area      ·      Esc to cancel", size: 16, weight: .semibold))
        let captureButton = NSButton(title: "Capture your first area", target: self, action: #selector(capture)); captureButton.bezelStyle = .rounded; captureButton.controlSize = .large; captureButton.keyEquivalent = "\r"
        stack.addArrangedSubview(captureButton)
        let exampleButton = NSButton(title: "Try the editor with an example", target: self, action: #selector(openExample)); exampleButton.bezelStyle = .rounded
        stack.addArrangedSubview(exampleButton)
        stack.addArrangedSubview(label("macOS will ask for Screen Recording access the first time.\nConfigure everything in Terminal: cleanmoss config show", size: 12, weight: .regular, color: .secondaryLabelColor))
        if let error = shortcutError { stack.addArrangedSubview(label(error, size: 12, weight: .regular, color: .systemRed)) }
        welcomeWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ message: String, detail: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail; alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeDemoImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1120, height: 720))
        image.lockFocus()
        NSColor(calibratedRed: 0.965, green: 0.97, blue: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1120, height: 720).fill()
        NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.17, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 240, height: 720).fill()
        func text(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        text("◈  moss studio", x: 26, y: 660, size: 21, color: .white, weight: .bold)
        for (index, title) in ["Overview", "Projects", "Your team", "Settings"].enumerated() { text(title, x: 32, y: CGFloat(574 - index * 55), size: 16, color: index == 0 ? .white : .lightGray) }
        text("Workspace overview", x: 285, y: 650, size: 30, color: .darkGray, weight: .bold)
        text("A good day to make something clear.", x: 285, y: 615, size: 17, color: .gray)
        for (index, pair) in [("Active projects", "12"), ("Team members", "8"), ("This week", "94%")].enumerated() {
            let rect = NSRect(x: 285 + index * 267, y: 420, width: 243, height: 145)
            NSColor.white.setFill(); NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()
            text(pair.0, x: rect.minX + 20, y: 517, size: 14, color: .gray)
            text(pair.1, x: rect.minX + 20, y: 452, size: 36, color: NSColor(calibratedRed: 0.19, green: 0.36, blue: 0.24, alpha: 1), weight: .bold)
        }
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 285, y: 86, width: 777, height: 297), xRadius: 15, yRadius: 15).fill()
        text("Recent activity", x: 309, y: 332, size: 20, color: .darkGray, weight: .semibold)
        for (index, row) in ["Website refresh                         Ready for review", "alex@example.com                     Invite accepted", "Design system                            Updated just now", "Launch checklist                         6 of 8 complete"].enumerated() { text(row, x: 309, y: CGFloat(273 - index * 47), size: 17, color: .darkGray) }
        image.unlockFocus()
        return image
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

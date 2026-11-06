import AppKit
import Carbon
import CleanmossCore

/// Carbon hotkeys do not require Accessibility or Input Monitoring permission.
@MainActor
final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(shortcut: String, action: @escaping () -> Void) throws {
        self.action = action
        let parsed = try Shortcut.parse(shortcut)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x434D4F53, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak controller] in controller?.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard handlerStatus == noErr else { throw HotKeyError.registration(shortcut: parsed.display, status: handlerStatus) }
        let identifier = EventHotKeyID(signature: 0x434D4F53, id: 1)
        let status = RegisterEventHotKey(parsed.keyCode, parsed.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
            throw HotKeyError.registration(shortcut: parsed.display, status: status)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

private enum HotKeyError: LocalizedError {
    case registration(shortcut: String, status: OSStatus)
    var errorDescription: String? {
        switch self {
        case .registration(let shortcut, let status):
            return "The shortcut \(shortcut) could not be registered (macOS error \(status)). Disable the matching shortcut in System Settings → Keyboard → Keyboard Shortcuts → Screenshots, then restart Cleanmoss. Or choose another shortcut with cleanmoss config set shortcut ctrl+shift+4."
        }
    }
}

import AppKit

public enum ImageClipboard {
    /// Publish only lossless PNG, avoiding NSImage's bulky TIFF representation.
    @discardableResult
    public static func write(_ image: NSImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        // Keep Retina resolution and its logical size when another app pastes it.
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

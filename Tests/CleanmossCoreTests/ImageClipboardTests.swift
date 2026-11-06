import AppKit
import CleanmossCore

func runImageClipboardChecks() throws {
    try check("Clipboard PNG is smaller than NSImage TIFF and preserves Retina pixels and size") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 50, y: 50, width: 300, height: 200))
        let source = context.makeImage()!
        let image = NSImage(cgImage: source, size: NSSize(width: 600, height: 400))
        try expect(pasteboard.writeObjects([image]), "Could not write the old NSImage representation")
        guard let tiff = pasteboard.data(forType: .tiff) else { throw CheckFailure(message: "Missing baseline TIFF") }

        try expect(ImageClipboard.write(image, to: pasteboard), "PNG copy failed")
        try expectEqual(pasteboard.pasteboardItems?.first?.types, [.png], "Stored clipboard item should offer only PNG")
        guard let png = pasteboard.data(forType: .png), let bitmap = NSBitmapImageRep(data: png),
              let pasted = NSImage(pasteboard: pasteboard) else { throw CheckFailure(message: "Copied PNG cannot be pasted as an image") }
        try expect(png.count < tiff.count / 10, "Flat screenshot PNG was not substantially smaller than TIFF")
        try expectEqual(bitmap.pixelsWide, source.width)
        try expectEqual(bitmap.pixelsHigh, source.height)
        try expect(abs(pasted.size.width - image.size.width) < 0.5 && abs(pasted.size.height - image.size.height) < 0.5, "Retina logical size changed when pasted")
        let original = NSBitmapImageRep(cgImage: source)
        try expectEqual(bitmap.samplesPerPixel, original.samplesPerPixel)
        for x in stride(from: 0, to: 1200, by: 100) {
            for y in stride(from: 0, to: 800, by: 100) {
                var actual = [Int](repeating: 0, count: bitmap.samplesPerPixel)
                var expected = [Int](repeating: 0, count: original.samplesPerPixel)
                bitmap.getPixel(&actual, atX: x, y: y)
                original.getPixel(&expected, atX: x, y: y)
                try expectEqual(actual, expected, "Copy changed pixels or transparency")
            }
        }
        print("Clipboard fixture: TIFF \(tiff.count) bytes → PNG \(png.count) bytes")
    }
    try check("Clipboard encoding failure preserves existing content") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep this", forType: .string)
        try expect(!ImageClipboard.write(NSImage(size: .zero), to: pasteboard), "Empty image unexpectedly copied")
        try expectEqual(pasteboard.string(forType: .string), "Keep this")
    }
}

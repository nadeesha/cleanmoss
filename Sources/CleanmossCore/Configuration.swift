import Foundation
import Carbon

public struct Configuration: Codable, Equatable {
    public var shortcut: String = "cmd+shift+4"
    public var outputDirectory: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cleanmoss").path
    public var format: String = "png"
    public var copyOnCapture: Bool = false
    public var launchAtLogin: Bool = true
    public init() {}

    public func validate() throws {
        _ = try Shortcut.parse(shortcut)
        guard ["png", "jpeg"].contains(format) else { throw ConfigurationError.invalid("Format must be png or jpeg.") }
        guard outputDirectory.hasPrefix("/"), !outputDirectory.contains("\0") else {
            throw ConfigurationError.invalid("Output directory must be an absolute path.")
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum ConfigurationStore {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cleanmoss/config.json")
    }
    public static func load(from url: URL = ConfigurationStore.fileURL) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    public static func save(_ configuration: Configuration, to url: URL = ConfigurationStore.fileURL) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}

public struct Shortcut: Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let display: String

    public static func parse(_ value: String) throws -> Shortcut {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last else { throw ConfigurationError.invalid("Use a shortcut such as cmd+shift+4.") }
        let keys: [String: UInt32] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"space":49,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111]
        guard let code = keys[key] else { throw ConfigurationError.invalid("Unsupported shortcut key: \(key).") }
        var flags: UInt32 = 0
        var used = Set<String>()
        for part in parts.dropLast() {
            let canonical: String
            let flag: UInt32
            switch part {
            case "cmd", "command": canonical = "cmd"; flag = UInt32(cmdKey)
            case "shift": canonical = "shift"; flag = UInt32(shiftKey)
            case "ctrl", "control": canonical = "ctrl"; flag = UInt32(controlKey)
            case "alt", "option", "opt": canonical = "alt"; flag = UInt32(optionKey)
            default: throw ConfigurationError.invalid("Unsupported modifier: \(part).")
            }
            guard used.insert(canonical).inserted else { throw ConfigurationError.invalid("Duplicate shortcut modifier: \(part).") }
            flags |= flag
        }
        guard flags & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0 else {
            throw ConfigurationError.invalid("A global shortcut must include cmd, ctrl, or option.")
        }
        let display = (used.contains("ctrl") ? "⌃" : "") + (used.contains("alt") ? "⌥" : "") + (used.contains("shift") ? "⇧" : "") + (used.contains("cmd") ? "⌘" : "") + key.uppercased()
        return Shortcut(keyCode: code, carbonModifiers: flags, display: display)
    }
}

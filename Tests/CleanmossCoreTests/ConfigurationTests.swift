import Foundation
import CleanmossCore

func runConfigurationChecks() throws {
    try check("Default shortcut and aliases") {
        let shortcut = try Shortcut.parse("cmd+shift+4")
        try expectEqual(shortcut.keyCode, 21)
        try expectEqual(shortcut.display, "⇧⌘4")
        try expectEqual(shortcut, try Shortcut.parse("shift+command+4"))
    }
    try check("Reject ambiguous and unsafe shortcuts") {
        for value in ["4", "shift+4", "cmd+cmd+4", "cmd++4", "cmd+unknown", "cmd+shift+"] {
            try expectThrows(value) { _ = try Shortcut.parse(value) }
        }
    }
    try check("Configuration round trip and validation") {
        var config = Configuration()
        try expectEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)), config)
        config.format = "gif"
        try expectThrows { try config.validate() }
        config.format = "png"; config.outputDirectory = "relative/path"
        try expectThrows { try config.validate() }
    }
    try check("Atomic persistence and corrupt configuration") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/config.json")
        try expectEqual(try ConfigurationStore.load(from: url), Configuration())
        var config = Configuration(); config.shortcut = "ctrl+shift+4"; config.format = "jpeg"
        try ConfigurationStore.save(config, to: url)
        try expectEqual(try ConfigurationStore.load(from: url), config)
        config.format = "broken"
        try expectThrows { try ConfigurationStore.save(config, to: url) }
        try expectEqual(try ConfigurationStore.load(from: url).format, "jpeg")
        try Data("invalid".utf8).write(to: url)
        try expectThrows { _ = try ConfigurationStore.load(from: url) }
    }
}

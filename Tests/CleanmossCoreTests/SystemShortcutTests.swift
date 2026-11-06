import Foundation
import CleanmossCore

func runSystemShortcutChecks() throws {
    let factory: [String: Any] = ["enabled": true, "value": ["parameters": [36, 21, 1179648], "type": "standard"], "customMetadata": "preserve"]
    func plan(_ original: [String: Any]?) throws -> (entry: [String: Any], backup: [String: Any]) {
        guard case .disable(let entry, let backup) = SystemShortcutPolicy.takeover(original: original) else {
            throw CheckFailure(message: "Expected a factory shortcut takeover")
        }
        return (entry, backup)
    }
    try check("Already disabled screenshot binding stays user-owned") {
        var disabled = factory; disabled["enabled"] = false
        guard case .alreadyDisabled = SystemShortcutPolicy.takeover(original: disabled) else {
            throw CheckFailure(message: "Disabled binding must not produce a takeover backup")
        }
    }
    try check("Rebound and unrecognized screenshot entries stay untouched") {
        for parameters in [[36, 22, 1179648], [36, 21, 262144]] {
            let rebound: [String: Any] = ["enabled": true, "value": ["parameters": parameters, "type": "standard"]]
            guard case .rebound = SystemShortcutPolicy.takeover(original: rebound) else {
                throw CheckFailure(message: "A different key or modifier must not be disabled")
            }
        }
        guard case .rebound = SystemShortcutPolicy.takeover(original: ["enabled": true]) else {
            throw CheckFailure(message: "Unrecognized existing entry must not be overwritten")
        }
    }
    try check("Factory shortcut preserves its complete original entry") {
        let planned = try plan(factory)
        try expectEqual(planned.entry["enabled"] as? Bool, false)
        try expectEqual(planned.backup["hadOriginal"] as? Bool, true)
        let restored = SystemShortcutPolicy.restore(in: ["30": planned.entry], backup: planned.backup)
        try expect(NSDictionary(dictionary: restored?["30"] as? [String: Any] ?? [:]).isEqual(to: factory))
    }
    try check("Absent factory preference restores by removing only the owned entry") {
        let planned = try plan(nil)
        try expectEqual(planned.backup["hadOriginal"] as? Bool, false)
        let restored = SystemShortcutPolicy.restore(in: ["30": planned.entry, "28": "unrelated"], backup: planned.backup)
        try expect(restored != nil)
        try expect(restored?["30"] == nil)
        try expectEqual(restored?["28"] as? String, "unrelated")
    }
    try check("Uninstall preserves unrelated preferences changed since install") {
        let planned = try plan(factory)
        let other: [String: Any] = ["enabled": true, "value": ["parameters": [40, 40, 262144]]]
        let current: [String: Any] = ["30": planned.entry, "28": other, "new-user-key": ["enabled": false]]
        let restored = SystemShortcutPolicy.restore(in: current, backup: planned.backup)
        try expect(NSDictionary(dictionary: restored?["28"] as? [String: Any] ?? [:]).isEqual(to: other))
        try expectEqual((restored?["new-user-key"] as? [String: Any])?["enabled"] as? Bool, false)
    }
    try check("User edits to the owned shortcut prevent restoration") {
        let planned = try plan(factory)
        var enabled = planned.entry; enabled["enabled"] = true
        var rebound = planned.entry; rebound["value"] = ["parameters": [36, 22, 1179648], "type": "standard"]
        for changed in [enabled, rebound] {
            try expect(!SystemShortcutPolicy.owns(current: changed, backup: planned.backup))
            try expect(SystemShortcutPolicy.restore(in: ["30": changed], backup: planned.backup) == nil)
        }
        try expect(SystemShortcutPolicy.restore(in: [:], backup: planned.backup) == nil)
    }
    try check("Malformed restoration backups cannot erase an original shortcut") {
        let planned = try plan(factory)
        var broken = planned.backup; broken.removeValue(forKey: "original")
        try expect(SystemShortcutPolicy.restore(in: ["30": planned.entry], backup: broken) == nil)
        broken = planned.backup; broken.removeValue(forKey: "hadOriginal")
        try expect(SystemShortcutPolicy.restore(in: ["30": planned.entry], backup: broken) == nil)
    }
}

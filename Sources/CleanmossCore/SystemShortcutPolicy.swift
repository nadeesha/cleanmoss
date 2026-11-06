import Foundation

/// Pure decisions for taking over only the factory area screenshot binding.
/// Persistence and preference refreshes remain the CLI's responsibility.
public enum SystemShortcutPolicy {
    public enum Takeover {
        case alreadyDisabled
        case rebound
        case disable(entry: [String: Any], backup: [String: Any])
    }

    public static func takeover(original: [String: Any]?) -> Takeover {
        if let original {
            if (original["enabled"] as? Bool) == false { return .alreadyDisabled }
            guard let value = original["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any], parameters.count >= 3,
                  (parameters[1] as? NSNumber)?.intValue == 21,
                  (parameters[2] as? NSNumber)?.intValue == 1179648 else {
                return .rebound
            }
        }
        var entry = original ?? ["value": ["parameters": [36, 21, 1179648], "type": "standard"]]
        entry["enabled"] = false
        var backup: [String: Any] = ["hadOriginal": original != nil, "installed": entry]
        if let original { backup["original"] = original }
        return .disable(entry: entry, backup: backup)
    }

    public static func owns(current: [String: Any]?, backup: [String: Any]) -> Bool {
        guard let current, let installed = backup["installed"] as? [String: Any] else { return false }
        return NSDictionary(dictionary: current).isEqual(to: installed)
    }

    /// Returns nil when the owned entry changed, or when a backup is malformed.
    /// Restoring starts from current preferences so unrelated changes survive.
    public static func restore(in current: [String: Any], backup: [String: Any]) -> [String: Any]? {
        guard owns(current: current["30"] as? [String: Any], backup: backup),
              let hadOriginal = backup["hadOriginal"] as? Bool else { return nil }
        var restored = current
        if hadOriginal {
            guard let original = backup["original"] as? [String: Any] else { return nil }
            restored["30"] = original
        } else {
            restored.removeValue(forKey: "30")
        }
        return restored
    }
}

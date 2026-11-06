import Foundation
import AppKit
import CoreGraphics
import CleanmossCore
import Darwin

private enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser
private let installedApp = home.appendingPathComponent("Applications/Cleanmoss.app")
private let installedCLI = home.appendingPathComponent(".local/bin/cleanmoss")
private let agentURL = home.appendingPathComponent("Library/LaunchAgents/com.cleanmoss.mac.plist")
private let backupURL = ConfigurationStore.fileURL.deletingLastPathComponent().appendingPathComponent("system-shortcut-backup.plist")
private let preferencesDomain = "com.apple.symbolichotkeys" as CFString
private let preferencesKey = "AppleSymbolicHotKeys" as CFString
private let appIdentifier = "com.cleanmoss.mac"

private func warning(_ message: String) {
    FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
}

@discardableResult private func run(_ executable: String, _ arguments: [String], tolerateFailure: Bool = false) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 && !tolerateFailure {
        let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CLIError.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(detail)")
    }
    return process.terminationStatus
}

private func symbolicHotkeys() -> [String: Any] {
    (CFPreferencesCopyValue(preferencesKey, preferencesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]) ?? [:]
}

private func saveSymbolicHotkeys(_ values: [String: Any]) throws {
    CFPreferencesSetValue(preferencesKey, values as CFDictionary, preferencesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard CFPreferencesSynchronize(preferencesDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
        throw CLIError.message("Could not save macOS keyboard shortcut preferences.")
    }
    let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    if fm.isExecutableFile(atPath: activate) {
        _ = try run(activate, ["-u"], tolerateFailure: true)
    }
}

private func takeSystemShortcut() throws {
    var values = symbolicHotkeys()
    let original = values["30"] as? [String: Any]
    let disabled: [String: Any]
    let backup: [String: Any]
    switch SystemShortcutPolicy.takeover(original: original) {
    case .alreadyDisabled: return
    case .rebound:
        warning("The macOS area screenshot action uses a custom shortcut. Preserving it; Cleanmoss will register ⌘⇧4 without changing that setting.")
        return
    case .disable(let entry, let saved):
        disabled = entry; backup = saved
    }
    if !fm.fileExists(atPath: backupURL.path) {
        try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: backup, format: .xml, options: 0).write(to: backupURL, options: .atomic)
    } else {
        let backup = try readShortcutBackup()
        if let previous = backup["installed"] as? NSDictionary,
           let original, !previous.isEqual(to: original) {
            throw CLIError.message("The system screenshot shortcut changed since installation. Restore it with cleanmoss uninstall before installing again, or use --keep-system-shortcut.")
        }
    }
    values["30"] = disabled
    try saveSymbolicHotkeys(values)
}

private func readShortcutBackup() throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: backupURL), options: [], format: nil) as? [String: Any] else {
        throw CLIError.message("Invalid system shortcut backup at \(backupURL.path).")
    }
    return value
}

private func restoreSystemShortcut() throws {
    guard fm.fileExists(atPath: backupURL.path) else { return }
    let backup = try readShortcutBackup()
    let values = symbolicHotkeys()
    if let restored = SystemShortcutPolicy.restore(in: values, backup: backup) {
        try saveSymbolicHotkeys(restored)
        print("Restored the macOS area screenshot shortcut.")
    } else {
        if SystemShortcutPolicy.owns(current: values["30"] as? [String: Any], backup: backup) {
            throw CLIError.message("The shortcut restoration backup is incomplete. Preserving the current shortcut and backup at \(backupURL.path).")
        }
        warning("The macOS area screenshot shortcut was changed after installation; preserving your current setting.")
    }
    try fm.removeItem(at: backupURL)
}

private func executableURL() -> URL {
    if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath() }
    return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
}

private func appSource() throws -> URL {
    let directory = executableURL().deletingLastPathComponent()
    let candidates = [directory.appendingPathComponent("Cleanmoss.app"), directory.deletingLastPathComponent().appendingPathComponent("Cleanmoss.app"), installedApp]
    for candidate in candidates where fm.isExecutableFile(atPath: candidate.appendingPathComponent("Contents/MacOS/Cleanmoss").path) {
        return candidate
    }
    throw CLIError.message("Cleanmoss.app is missing. Run scripts/build.sh, then install using dist/cleanmoss install. Keep the CLI and Cleanmoss.app together when distributing them.")
}

private func copyReplacing(_ source: URL, _ destination: URL) throws {
    if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL { return }
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cleanmoss-install-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: temporary) }
    try fm.copyItem(at: source, to: temporary)
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.moveItem(at: temporary, to: destination)
}

private func requireApp() throws {
    guard fm.isExecutableFile(atPath: installedApp.appendingPathComponent("Contents/MacOS/Cleanmoss").path) else {
        throw CLIError.message("Cleanmoss is not installed. Run cleanmoss install first.")
    }
}

private func notifyConfigurationChanged() {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.cleanmoss.configurationChanged"), object: nil)
}

private func configureLogin(_ enabled: Bool, launchNow: Bool) throws {
    let service = "gui/\(getuid())/\(appIdentifier)"
    if launchNow {
        _ = try run("/bin/launchctl", ["bootout", service], tolerateFailure: true)
    }
    if enabled {
        let plist: [String: Any] = [
            "Label": appIdentifier,
            "ProgramArguments": [installedApp.appendingPathComponent("Contents/MacOS/Cleanmoss").path, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        if launchNow { try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentURL.path]) }
    } else if fm.fileExists(atPath: agentURL.path) {
        try fm.removeItem(at: agentURL)
    }
}

private func stop() throws {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier)
    for app in applications where !app.isTerminated {
        guard app.terminate() else { throw CLIError.message("Cleanmoss could not quit. Close its open editors, then try again.") }
    }
    let deadline = Date().addingTimeInterval(15)
    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard applications.allSatisfy(\.isTerminated) else {
        throw CLIError.message("Cleanmoss is waiting for an editor to close, or quitting was cancelled. Resolve its unsaved edits and try again.")
    }
    _ = try run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(appIdentifier)"], tolerateFailure: true)
}

private func start() throws {
    try requireApp()
    if !NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier).isEmpty { return }
    try run("/usr/bin/open", ["-g", installedApp.path, "--args", "--background"])
}

private func install(_ arguments: [String]) throws {
    let allowed = Set(["--no-launch", "--no-login", "--keep-system-shortcut"])
    guard arguments.allSatisfy({ allowed.contains($0) }) else { throw CLIError.message("Install accepts --no-launch, --no-login, and --keep-system-shortcut.") }
    let source = try appSource()
    let cliSource = executableURL()
    try stop()
    try copyReplacing(source, installedApp)
    try copyReplacing(cliSource, installedCLI)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedCLI.path)
    var configuration = try ConfigurationStore.load()
    if arguments.contains("--no-login") { configuration.launchAtLogin = false }
    try ConfigurationStore.save(configuration)
    if arguments.contains("--keep-system-shortcut") {
        try restoreSystemShortcut()
        warning("The macOS area screenshot shortcut is preserved. If it is enabled, choose another Cleanmoss shortcut with cleanmoss config set shortcut ctrl+shift+4, or disable the macOS shortcut in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.")
    } else if try Shortcut.parse(configuration.shortcut) == Shortcut.parse("cmd+shift+4") {
        try takeSystemShortcut()
    }
    let launchNow = !arguments.contains("--no-launch")
    try configureLogin(configuration.launchAtLogin, launchNow: launchNow)
    if launchNow && !configuration.launchAtLogin { try start() }
    print("Installed \(installedApp.path)")
    print("CLI: \(installedCLI.path)")
    print("Capture shortcut: \(try Shortcut.parse(configuration.shortcut).display)")
    if !((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(installedCLI.deletingLastPathComponent().path))) {
        print("Add the CLI to your shell: export PATH=\"$HOME/.local/bin:$PATH\"")
    }
    print("On first capture, allow Cleanmoss in System Settings → Privacy & Security → Screen Recording, then restart Cleanmoss if macOS requests it.")
}

private func uninstall() throws {
    try stop()
    try configureLogin(false, launchNow: false)
    try restoreSystemShortcut()
    for url in [installedApp, installedCLI] where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    print("Uninstalled Cleanmoss. Captures and configuration were preserved.")
}

private func boolean(_ value: String) throws -> Bool {
    switch value.lowercased() {
    case "true", "yes", "1", "on": return true
    case "false", "no", "0", "off": return false
    default: throw CLIError.message("Expected true or false.")
    }
}

private func configValue(_ configuration: Configuration, _ key: String) throws -> String {
    switch key {
    case "shortcut": return configuration.shortcut
    case "outputDirectory", "output-directory": return configuration.outputDirectory
    case "format": return configuration.format
    case "copyOnCapture", "copy-on-capture": return String(configuration.copyOnCapture)
    case "launchAtLogin", "launch-at-login": return String(configuration.launchAtLogin)
    default: throw CLIError.message("Unknown configuration key: \(key).")
    }
}

private func config(_ arguments: [String]) throws {
    guard let action = arguments.first else { throw CLIError.message("Use config show, get KEY, set KEY VALUE, or reset.") }
    var configuration = action == "reset" ? Configuration() : try ConfigurationStore.load()
    var shortcutChanged = false
    switch action {
    case "show" where arguments.count == 1:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(configuration), as: UTF8.self))
        return
    case "get" where arguments.count == 2:
        print(try configValue(configuration, arguments[1]))
        return
    case "set" where arguments.count == 3:
        let key = arguments[1], value = arguments[2]
        switch key {
        case "shortcut":
            _ = try Shortcut.parse(value)
            configuration.shortcut = value.lowercased()
            shortcutChanged = true
        case "outputDirectory", "output-directory":
            configuration.outputDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
        case "format": configuration.format = value.lowercased() == "jpg" ? "jpeg" : value.lowercased()
        case "copyOnCapture", "copy-on-capture": configuration.copyOnCapture = try boolean(value)
        case "launchAtLogin", "launch-at-login": configuration.launchAtLogin = try boolean(value)
        default: throw CLIError.message("Unknown configuration key: \(key).")
        }
        try configuration.validate()
        if ["launchAtLogin", "launch-at-login"].contains(key), fm.fileExists(atPath: installedApp.path) {
            try configureLogin(configuration.launchAtLogin, launchNow: false)
        }
    case "reset" where arguments.count == 1:
        configuration = Configuration()
        shortcutChanged = true
        if fm.fileExists(atPath: installedApp.path) {
            try configureLogin(configuration.launchAtLogin, launchNow: false)
        }
    default: throw CLIError.message("Use config show, get KEY, set KEY VALUE, or reset.")
    }
    if shortcutChanged && fm.fileExists(atPath: installedApp.path) {
        if try Shortcut.parse(configuration.shortcut) == Shortcut.parse("cmd+shift+4") {
            try takeSystemShortcut()
        } else {
            try restoreSystemShortcut()
        }
    }
    try ConfigurationStore.save(configuration)
    notifyConfigurationChanged()
    print("Saved \(ConfigurationStore.fileURL.path)")
}

private func doctor() throws {
    let configuration = try ConfigurationStore.load()
    print("Cleanmoss 1.0.0")
    print("App: \(fm.fileExists(atPath: installedApp.path) ? "installed" : "missing; run cleanmoss install")")
    print("CLI: \(installedCLI.path)")
    print("Configuration: \(ConfigurationStore.fileURL.path)")
    print("Shortcut: \(try Shortcut.parse(configuration.shortcut).display)")
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier).isEmpty
    print("Background app: \(running ? "running" : "stopped; run cleanmoss start")")
    print("Launch at login: \(fm.fileExists(atPath: agentURL.path) ? "enabled" : "disabled")")
    if try Shortcut.parse(configuration.shortcut) == Shortcut.parse("cmd+shift+4") {
        switch SystemShortcutPolicy.takeover(original: symbolicHotkeys()["30"] as? [String: Any]) {
        case .alreadyDisabled: print("macOS area shortcut: disabled")
        case .rebound: print("macOS area shortcut: custom binding; Cleanmoss preserves this setting")
        case .disable: print("macOS area shortcut: ⌘⇧4 enabled; run cleanmoss install or disable it in Keyboard Shortcuts → Screenshots")
        }
        if fm.fileExists(atPath: backupURL.path) {
            let backup = try readShortcutBackup()
            let owned = SystemShortcutPolicy.owns(current: symbolicHotkeys()["30"] as? [String: Any], backup: backup)
            print("Shortcut ownership: \(owned ? "Cleanmoss; uninstall restores the previous setting" : "changed externally; uninstall will preserve the current setting")")
        } else {
            print("Shortcut ownership: user/macOS (no Cleanmoss restoration backup)")
        }
    }
    let permission = CGPreflightScreenCaptureAccess()
    print("Screen recording (CLI process): \(permission ? "allowed" : "not granted")")
    print("The app has a separate permission identity. If capture is blocked, allow Cleanmoss in System Settings → Privacy & Security → Screen Recording, then run cleanmoss stop && cleanmoss start.")
    print("Capture output: \(configuration.outputDirectory) (\(configuration.format))")
}

private let help = """
Cleanmoss — area screenshots with a native annotation editor

Usage: cleanmoss COMMAND [OPTIONS]

  install [--no-launch] [--no-login] [--keep-system-shortcut]
                    Install the app and CLI; default capture shortcut is ⌘⇧4.
  uninstall         Remove the app/CLI and restore the owned macOS shortcut.
  start | stop      Start or stop the background screenshot app.
  capture           Select an area and open the annotation editor.
  edit PATH         Open an existing image in the editor.
  config show       Print all settings as JSON.
  config get KEY    Print one setting.
  config set KEY VALUE
                    Save a setting and notify the running app.
  config reset      Restore default settings.
  doctor            Check installation, shortcut, and capture permissions.
  permissions       Open macOS Screen Recording privacy settings.
  version           Print the version.

Settings: shortcut, outputDirectory, format (png/jpeg), copyOnCapture,
          launchAtLogin. Boolean values: true/false.

Examples:
  cleanmoss config set shortcut cmd+shift+4
  cleanmoss config set outputDirectory ~/Pictures/Cleanmoss
  cleanmoss config set copyOnCapture true

Installation disables only macOS's area screenshot hotkey (⌘⇧4), preserving
its previous setting for uninstall. Use --keep-system-shortcut to opt out.
"""

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "help"
    let remaining = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h": print(help)
    case "version", "--version", "-v": print("Cleanmoss 1.0.0")
    case "install": try install(remaining)
    case "uninstall" where remaining.isEmpty: try uninstall()
    case "start" where remaining.isEmpty: try start(); print("Cleanmoss started.")
    case "stop" where remaining.isEmpty: try stop(); print("Cleanmoss stopped.")
    case "capture" where remaining.isEmpty:
        try requireApp()
        try run("/usr/bin/open", ["-a", installedApp.path, "cleanmoss://capture"])
    case "edit" where remaining.count == 1:
        try requireApp()
        let image = URL(fileURLWithPath: (remaining[0] as NSString).expandingTildeInPath).standardizedFileURL
        guard fm.fileExists(atPath: image.path) else { throw CLIError.message("Image does not exist: \(image.path)") }
        try run("/usr/bin/open", ["-a", installedApp.path, image.path])
    case "config": try config(remaining)
    case "doctor" where remaining.isEmpty: try doctor()
    case "permissions" where remaining.isEmpty:
        try run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"])
    default: throw CLIError.message("Unknown command or invalid arguments: \(command). Run cleanmoss help.")
    }
} catch {
    FileHandle.standardError.write(Data("cleanmoss: \(error.localizedDescription)\n".utf8))
    exit(1)
}

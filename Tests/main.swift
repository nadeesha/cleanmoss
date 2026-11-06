import Foundation
import AppKit
import CleanmossCore

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
var passedChecks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Expectation failed") throws {
    if !condition() { throw CheckFailure(message: message) }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    try expect(actual == expected, "\(message) Expected \(expected), got \(actual)")
}
func expectThrows(_ message: String = "", _ block: () throws -> Void) throws {
    do { try block() } catch { return }
    throw CheckFailure(message: "\(message) Expected an error")
}
func check(_ name: String, _ block: () throws -> Void) throws {
    do { try block(); passedChecks += 1; print("PASS \(name)") }
    catch { throw CheckFailure(message: "\(name): \(error.localizedDescription)") }
}

_ = NSApplication.shared

do {
    try runConfigurationChecks()
    try runSystemShortcutChecks()
    try runAnnotationChecks()
    try runImageClipboardChecks()
    print("\(passedChecks) checks passed.")
} catch {
    FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
    exit(1)
}

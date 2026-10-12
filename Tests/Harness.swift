// Harness.swift — a tiny test runner (XCTest is not available without full Xcode).
//
// A test file defines one function, e.g. `func runEngineTests(_ t: TestRunner)`, and
// `scripts/test.sh Engine <sources...>` compiles and runs it.

import Foundation

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var current = ""
    private var failures: [String] = []

    /// Runs one named test. A thrown error counts as a failure.
    func test(_ name: String, _ body: () throws -> Void) {
        current = name
        let before = failed
        do { try body() } catch { record("threw \(error)", file: #file, line: #line) }
        print((failed == before ? "  ok   " : "  FAIL ") + name)
    }

    // The value closures may throw (like XCTest's asserts): a thrown error is recorded as a failure.

    func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #file, line: UInt = #line) {
        do {
            if try condition() { passed += 1 } else { record(message(), file: file, line: line) }
        } catch { record("\(message()) — threw \(error)", file: file, line: line) }
    }

    func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
                                   _ message: @autoclosure () -> String = "",
                                   file: StaticString = #file, line: UInt = #line) {
        do {
            let a = try actual(), e = try expected()
            if a == e { passed += 1 } else { record("\(message()) — got \(a), expected \(e)", file: file, line: line) }
        } catch { record("\(message()) — threw \(error)", file: file, line: line) }
    }

    func expectNil<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                      file: StaticString = #file, line: UInt = #line) {
        do {
            if let v = try value() { record("\(message()) — expected nil, got \(v)", file: file, line: line) } else { passed += 1 }
        } catch { record("\(message()) — threw \(error)", file: file, line: line) }
    }

    /// Unwraps or records a failure and throws, ending the current test.
    func unwrap<T>(_ value: T?, _ message: String = "unexpected nil",
                   file: StaticString = #file, line: UInt = #line) throws -> T {
        if let v = value { passed += 1; return v }
        record(message, file: file, line: line)
        throw TestFailure.unwrapFailed
    }

    /// Spins the main run loop until `condition` is true or `timeout` seconds pass. For async code.
    @discardableResult
    func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// The project root (set by the scripts through PERCH_ROOT).
    static var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERCH_ROOT"] ?? FileManager.default.currentDirectoryPath)
    }

    /// A file under Fixtures/, e.g. `fixture("claude/hooks/PreToolUse.json")`.
    static func fixture(_ relativePath: String) -> URL { root.appendingPathComponent("Fixtures").appendingPathComponent(relativePath) }

    static func fixtureText(_ relativePath: String) -> String {
        (try? String(contentsOf: fixture(relativePath), encoding: .utf8)) ?? ""
    }

    /// A fresh empty directory under the system temp folder.
    static func tempDir(_ label: String = "perch-test") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func finish() -> Never {
        print("\n\(passed) checks passed, \(failed) failed")
        for f in failures { print("  - " + f) }
        exit(failed == 0 ? 0 : 1)
    }

    private func record(_ message: String, file: StaticString, line: UInt) {
        failed += 1
        let name = ("\(file)" as NSString).lastPathComponent
        failures.append("[\(current)] \(name):\(line) \(message)")
    }

    enum TestFailure: Error { case unwrapFailed }
}

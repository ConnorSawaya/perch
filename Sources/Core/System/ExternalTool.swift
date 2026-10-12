// ExternalTool.swift — runs one short-lived command-line tool and collects what it printed.
//
// The terminal jumper needs a few outside tools: `osascript` for AppleScript, and the control
// commands of tmux, kitty and WezTerm. Each run gets a hard time limit; a tool that hangs is
// terminated and then killed, so nothing we start can outlive its welcome. Output is read on
// separate threads so a chatty tool can never stall on a full pipe.

import Foundation

struct ExternalToolResult: Equatable {
    /// The tool's exit code; -1 when it could not be started or was cut off.
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    /// True when the tool could not be started at all (missing file, not executable).
    var launchFailed = false

    var succeeded: Bool { exitCode == 0 && !timedOut && !launchFailed }
    /// Standard output without the trailing newline tools usually add.
    var trimmedOutput: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ExternalTool {

    /// Runs `executable` with `arguments` and waits for it, at most `timeout` seconds.
    /// Blocks the calling thread, so call it from a background queue.
    /// `environment` entries are added on top of our own environment.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                    timeout: TimeInterval) -> ExternalToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ExternalToolResult(exitCode: -1, stdout: "", stderr: error.localizedDescription, launchFailed: true)
        }

        // Drain both pipes while the tool runs.
        let readers = DispatchGroup()
        let outData = Guarded(Data()), errData = Guarded(Data())
        let drainQueue = DispatchQueue(label: "local.perch.command.drain", attributes: .concurrent)
        drainQueue.async(group: readers) { outData.set(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        drainQueue.async(group: readers) { errData.set(errPipe.fileHandleForReading.readDataToEndOfFile()) }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // A grandchild could keep the pipes open; do not wait for it forever.
        _ = readers.wait(timeout: .now() + killGrace)

        return ExternalToolResult(exitCode: timedOut ? -1 : process.terminationStatus,
                             stdout: String(decoding: outData.get(), as: UTF8.self),
                             stderr: String(decoding: errData.get(), as: UTF8.self),
                             timedOut: timedOut)
    }

    /// The first of `candidates` that exists and can be executed, or nil.
    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// How long a tool gets to exit after being asked politely, before it is killed.
    private static let killGrace: TimeInterval = 0.5
}

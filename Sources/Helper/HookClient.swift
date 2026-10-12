// HookClient.swift — everything the `perch-hook` helper does, written as plain functions.
//
// A coding agent runs `perch-hook` on every event. The helper's whole job is:
//   1. connect to the Perch app's Unix socket (app not running? stop here, quietly),
//   2. read the event the agent wrote to stdin,
//   3. wrap it in a HookEnvelope together with a few facts about where it came from (the agent's
//      process id, its terminal, the folder) and send that as one line of JSON,
//   4. with `--wait`: stay connected until the app answers with one HookReply line, print the
//      reply's text and exit with its exit code.
//
// The golden rule is "fail open": whatever goes wrong, print nothing and exit 0, so the agent
// behaves exactly as if Perch were not installed. (`--fallback` exists for the rare agent that
// treats "printed nothing" as a refusal: the hook command can say what to print instead.)
//
// This file has no top-level code so the tests can compile it; `main.swift` holds the entry
// point. The helper is built from Foundation and Sources/Contract/Wire.swift only, which is why
// a few small socket routines live here instead of being shared with the app's HookServer.

import Foundation

enum HookClient {

    // MARK: - What the command line asked for

    /// Filled in by `parseOptions` in main.swift.
    struct Options: Equatable {
        /// Which agent ran the hook: "claude", "codex", "antigravity", "gemini".
        var agent = ""
        /// "hook", "statusline" or "notify".
        var channel = "hook"
        /// `--event`: the event name, for agents that do not put it in the payload.
        var event: String?
        /// `--wait`: stay connected until the app replies.
        var wait = false
        /// `--timeout`: stop waiting after this many seconds. Nil waits for as long as the agent lets us.
        var timeout: TimeInterval?
        /// `--pid`: the agent's process id, when the hook command knows it better than we can guess.
        var pidOverride: Int32?
        /// `--fallback`: text to print when Perch has nothing to say (not running, no opinion, timed out).
        var fallback: String?
        /// Everything after `--`.
        var extraArgs: [String] = []

        /// The status line channel never prints, so there is nothing for it to wait for.
        var expectsReply: Bool { wait && channel != "statusline" }
        /// The text to print when there is no reply text. Always empty for the status line channel.
        var fallbackOutput: String { channel == "statusline" ? "" : (fallback ?? "") }
    }

    // MARK: - Limits

    /// Longest message, in bytes, that may be sent. HookServer.maxLineBytes is the same number.
    static let maxLineBytes = 8 * 1024 * 1024
    /// If the agent leaves stdin open, stop waiting for more once it has been quiet this long.
    static let stdinIdleTimeout: TimeInterval = 3
    /// How long the app may take to accept the message before the helper gives up on it.
    static let sendTimeout: TimeInterval = 2
    /// How much of a message the system will hold for the app while the helper moves on.
    static let sendBufferBytes: Int32 = 512 * 1024
    /// How many parent processes to look through when searching for the agent.
    static let maxParentHops = 12
    /// Hook commands are usually started through one of these; the agent is the first parent that is not.
    static let shellWrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "ksh", "csh", "tcsh"]

    // MARK: - The whole job

    /// Runs the helper from start to finish and returns its exit status. The descriptors and the
    /// socket path are parameters only so that tests can stand in for the real ones.
    static func run(_ options: Options, socketPath: String = PerchPaths.socketURL.path,
                    input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) -> Int32 {
        // Checked before anything is opened: if stdin or stdout was closed by whoever started us,
        // its number can be handed to the socket, and must not then be mistaken for the real thing.
        // A terminal on stdin means a person ran the helper by hand: there is no payload to read.
        let canRead = fcntl(input, F_GETFD) != -1 && isatty(input) == 0
        let canPrint = fcntl(output, F_GETFD) != -1
        func emit(_ text: Data) {
            if canPrint { writeAll(text, to: output, timeout: nil) }
        }
        let fallback = Data(options.fallbackOutput.utf8)
        // An agent that needs an answer on stdout gets the fallback straight away when we are only
        // reporting, so nothing that happens afterwards can leave it without one.
        if !options.expectsReply { emit(fallback) }

        let reply = options.agent.isEmpty ? nil : exchange(options, socketPath: socketPath, input: canRead ? input : nil)

        guard options.expectsReply else { return 0 }
        guard let reply else {
            emit(fallback)
            return 0
        }
        emit(reply.stdout.isEmpty ? fallback : Data(reply.stdout.utf8))
        return reply.exitCode
    }

    /// Sends the event to the app. Returns the app's reply when one was asked for and arrived;
    /// nil in every other case (including "the app is not running").
    private static func exchange(_ options: Options, socketPath: String, input: Int32?) -> HookReply? {
        // Process 1 (launchd) adopts a program whose parent has died. Remember whether we started
        // out with a real parent, so that losing it later can be noticed (see `readReply`).
        let startedWithParent = getppid() != 1
        // Connect first: when Perch is not running this is where the helper stops, having done almost nothing.
        guard let socket = openConnection(to: socketPath) else { return nil }
        defer { close(socket) }

        var payload = Data()
        if let input {
            guard let text = readAll(from: input, idleTimeout: stdinIdleTimeout, limit: maxLineBytes) else { return nil }
            payload = text
        }
        let envelope = makeEnvelope(options, payload: String(decoding: payload, as: UTF8.self))
        guard let line = encodeLine(envelope), line.count <= maxLineBytes,
              writeAll(line, to: socket, timeout: sendTimeout), envelope.wantsReply else { return nil }
        return readReply(from: socket, timeout: options.timeout, giveUpIfOrphaned: startedWithParent)
    }

    // MARK: - The envelope

    static func makeEnvelope(_ options: Options, payload: String) -> HookEnvelope {
        var envelope = HookEnvelope(agent: options.agent)
        envelope.channel = options.channel
        envelope.event = options.event
        envelope.payload = payload
        envelope.args = options.extraArgs
        envelope.env = forwardedEnvironment()
        // CLAUDE_PID is Claude Code's own variable. Another agent only has it when it was started
        // from inside a Claude session, and then it names the wrong process.
        let claudePID = options.agent == "claude" ? envelope.env["CLAUDE_PID"] : nil
        envelope.pid = agentProcessID(override: options.pidOverride, claudePID: claudePID)
        envelope.tty = terminalPath(of: envelope.pid)
        envelope.cwd = FileManager.default.currentDirectoryPath
        envelope.wantsReply = options.expectsReply
        envelope.sentAt = Date().timeIntervalSince1970
        return envelope
    }

    /// The whitelisted environment variables that are set (and not empty) in this process.
    static func forwardedEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        for key in HookEnvelope.forwardedEnvKeys {
            guard let value = getenv(key), value.pointee != 0 else { continue }
            result[key] = String(cString: value)
        }
        return result
    }

    /// The envelope as one line of JSON, ending in a newline. (JSON escapes any newline inside the text.)
    static func encodeLine(_ envelope: HookEnvelope) -> Data? {
        guard var line = try? JSONEncoder().encode(envelope) else { return nil }
        line.append(0x0A)
        return line
    }

    // MARK: - Finding the agent process and its terminal (sysctl only: starting `ps` would be far too slow)

    struct ProcessFacts: Equatable {
        var parent: Int32
        /// The executable's name, at most 16 characters ("zsh", "node", "codex"...).
        var name: String
        /// The controlling terminal's device number, or -1 when the process has none.
        var terminalDevice: dev_t
    }

    /// Asks the kernel about one process. Nil when it does not exist.
    static func processFacts(_ pid: Int32) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // The call succeeds with nothing filled in when there is no such process.
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessFacts(parent: info.kp_eproc.e_ppid, name: name, terminalDevice: info.kp_eproc.e_tdev)
    }

    /// The process id of the agent that ran this hook, or 0 when it cannot be worked out.
    /// Order of preference: `--pid`, then `$CLAUDE_PID` (for Claude Code), then the nearest parent
    /// that is not a shell wrapper (agents usually start hooks through `sh -c`, so the direct parent
    /// is often a short-lived shell that says nothing about the agent).
    static func agentProcessID(override: Int32?, claudePID: String?, parent: Int32 = getppid()) -> Int32 {
        if let override, override > 0 { return override }
        if let text = claudePID, let pid = Int32(text), pid > 1 { return pid }
        var candidate = parent
        for _ in 0..<maxParentHops {
            guard candidate > 1, let facts = processFacts(candidate) else { break }
            if !shellWrappers.contains(facts.name) { return candidate }
            candidate = facts.parent
        }
        // Shells all the way up (or the parent has already gone): the direct parent is the best guess.
        return parent > 1 ? parent : 0
    }

    /// The controlling terminal of a process, e.g. "/dev/ttys003". Nil when it has none.
    static func terminalPath(of pid: Int32) -> String? {
        guard let facts = processFacts(pid), facts.terminalDevice != -1 else { return nil }
        return devicePath(forTerminal: facts.terminalDevice)
    }

    /// The /dev path of a terminal, given its device number.
    static func devicePath(forTerminal device: dev_t) -> String? {
        // Terminal tabs are pseudo-terminals called ttys000, ttys001... after the low part of the
        // device number. Checking that guess is one quick call; asking the system to search /dev
        // (devname) is right for every kind of device but takes about a millisecond.
        let number = String(device & 0xFF_FFFF)
        let guess = "/dev/ttys" + String(repeating: "0", count: max(0, 3 - number.count)) + number
        var info = stat()
        if stat(guess, &info) == 0, info.st_mode & S_IFMT == S_IFCHR, info.st_rdev == device { return guess }

        guard let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text.hasPrefix("?") ? nil : "/dev/" + text
    }

    // MARK: - Socket and pipe plumbing

    /// Connects to the app's socket. Nil when nothing is listening there.
    static func openConnection(to path: String) -> Int32? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        // The address has a fixed-size field for the path (104 bytes including the ending zero).
        guard !pathBytes.isEmpty, pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        var descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        if descriptor <= STDERR_FILENO {
            // stdin, stdout or stderr was closed and the socket took its number. Move it out of the
            // way so the reply is never written into the socket by mistake.
            let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            close(descriptor)
            guard moved >= 0 else { return nil }
            descriptor = moved
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Room for a large event (the default is 8 KB), so it can be handed to the system in one go
        // and the helper can leave without waiting for the app to read it.
        var room = sendBufferBytes
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking, so that a frozen app can never leave the helper stuck inside a call.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Reads until end-of-file. Returns what arrived so far if the writer goes quiet for
    /// `idleTimeout` without closing, and nil if there is more than `limit` bytes.
    static func readAll(from descriptor: Int32, idleTimeout: TimeInterval, limit: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard waitUntil(descriptor, isReady: POLLIN, forUpTo: idleTimeout) == .ready else { break }
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                data.append(chunk, count: count)
                if data.count > limit { return nil }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                break
            }
        }
        return data
    }

    /// Writes all of `data`, waiting whenever the receiver is not ready for more. Gives up (false)
    /// on an error, or when a `timeout` is given and that many seconds pass.
    @discardableResult
    static func writeAll(_ data: Data, to descriptor: Int32, timeout: TimeInterval?) -> Bool {
        let deadline = timeout.map { monotonicSeconds() + $0 }
        return data.withUnsafeBytes { bytes -> Bool in
            guard let start = bytes.baseAddress else { return true }   // nothing to write
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, start + sent, bytes.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0 && errno == EAGAIN {
                    let remaining = deadline.map { $0 - monotonicSeconds() }
                    if let remaining, remaining <= 0 { return false }
                    if waitUntil(descriptor, isReady: POLLOUT, forUpTo: min(remaining ?? 1, 1)) == .failed { return false }
                } else if !(count < 0 && errno == EINTR) {
                    return false
                }
            }
            return true
        }
    }

    /// Waits for the app's one-line answer. Nil when the connection closes first, the timeout
    /// passes or the answer makes no sense. With `giveUpIfOrphaned`, also when the process that
    /// started this helper dies: an agent that ends a hook often kills only the shell around it,
    /// and then nobody is left to collect the answer.
    static func readReply(from socket: Int32, timeout: TimeInterval?, giveUpIfOrphaned: Bool = false) -> HookReply? {
        let deadline = timeout.map { monotonicSeconds() + $0 }
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // Wake up once a second even with no timeout, to notice being orphaned (below).
            var patience: TimeInterval = 1
            if let deadline {
                let remaining = deadline - monotonicSeconds()
                if remaining <= 0 { return nil }
                patience = min(patience, remaining)
            }
            switch waitUntil(socket, isReady: POLLIN, forUpTo: patience) {
            case .failed:
                return nil
            case .timedOut:
                // Leaving closes the connection, which makes the request's card in the app disappear.
                if giveUpIfOrphaned && getppid() == 1 { return nil }
                continue
            case .ready:
                break
            }
            let count = read(socket, &chunk, chunk.count)
            if count > 0 {
                if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                    line.append(chunk, count: newline)
                    return try? JSONDecoder().decode(HookReply.self, from: line)
                }
                line.append(chunk, count: count)
                if line.count > maxLineBytes { return nil }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                return nil   // closed without an answer
            }
        }
    }

    private enum Readiness { case ready, timedOut, failed }

    /// Blocks until the descriptor can be read (POLLIN) or written (POLLOUT), or the time is up.
    /// "Ready" includes end-of-file and errors on the descriptor: the read or write that follows reports those.
    private static func waitUntil(_ descriptor: Int32, isReady events: Int32, forUpTo seconds: TimeInterval) -> Readiness {
        let deadline = monotonicSeconds() + max(0, seconds)
        while true {
            let remaining = max(0, deadline - monotonicSeconds())
            var watch = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&watch, 1, Int32(min(remaining * 1000, 3_600_000).rounded(.up)))
            if result > 0 { return .ready }
            if result == 0 { return .timedOut }
            if errno != EINTR { return .failed }
        }
    }

    /// A clock that only moves forward, for measuring timeouts.
    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

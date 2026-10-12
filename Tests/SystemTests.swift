// SystemTests.swift — tests for Sources/Core/System (process lookups, terminal jump, sounds,
// notifications, launch at login).
//
// Nothing here brings another app forward, shows a permission prompt, or makes a sound: the parts
// that touch macOS (scripts, app activation, the speaker, the notification centre, the login-item
// service) are replaced by fakes. Sounds are generated and inspected as numbers, never played.
// The few real child processes (echo, sleep, sh, ps, osascript running scripts that talk to no
// app, and osacompile / osadecompile for a compile-only check) are short-lived and have exited
// before the tests finish.
// Run with: scripts/test.sh System Sources/Core/System

import AppKit

func runSystemTests(_ t: TestRunner) {
    // Send Perch's log file to a temporary folder instead of the real support folder.
    let home = TestRunner.tempDir("perch-system")
    setenv("PERCH_HOME", home.path, 1)
    defer { try? FileManager.default.removeItem(at: home) }

    runProcessProbeTests(t)
    runExternalToolTests(t)
    runLoginItemTests(t)
    runScriptTests(t, home)
    runTerminalFactsTests(t)
    runTerminalToolsTests(t)
    runBriefCacheTests(t)
    runJumpTests(t)
    runFrontmostTests(t)
    runLiveSystemTests(t)
    runSoundSynthTests(t)
    runSoundPolicyTests(t)
    runSoundEngineTests(t)
    runNotifierTests(t)
}

// MARK: - ProcessProbe

private func runProcessProbeTests(_ t: TestRunner) {
    let me = getpid()
    let myParent = getppid()

    t.test("ProcessProbe: this test process is alive and has the expected name and parent") {
        t.expect(ProcessProbe.isAlive(me), "own pid is alive")
        t.expectEqual(ProcessProbe.parent(of: me), myParent, "parent matches getppid()")
        t.expectEqual(ProcessProbe.name(of: me), "tests", "name is the executable's file name")
        let path = try t.unwrap(ProcessProbe.executablePath(of: me), "own executable path")
        t.expect(path.hasSuffix("/.build/tests/System/tests"), "path points at the test binary: \(path)")
        let started = try t.unwrap(ProcessProbe.startTime(of: me), "own start time")
        t.expect(started <= Date() && started > Date().addingTimeInterval(-600), "started recently: \(started)")
    }

    t.test("ProcessProbe: the parent process is alive and named") {
        t.expect(ProcessProbe.isAlive(myParent), "parent is alive")
        let name = try t.unwrap(ProcessProbe.name(of: myParent), "parent has a name")
        t.expect(!name.isEmpty, "parent name is not empty")
        t.expect(ProcessProbe.startTime(of: myParent) != nil, "parent has a start time")
    }

    t.test("ProcessProbe: tty agrees with the system's own answer") {
        // ttyname() only works when stdin is a terminal; otherwise just check the shape.
        if isatty(STDIN_FILENO) == 1, let system = ttyname(STDIN_FILENO).map({ String(cString: $0) }) {
            t.expectEqual(ProcessProbe.tty(of: me), system, "matches ttyname(stdin)")
        } else if let tty = ProcessProbe.tty(of: me) {
            t.expect(tty.hasPrefix("/dev/"), "tty is a device path: \(tty)")
            t.expect(FileManager.default.fileExists(atPath: tty), "tty device exists: \(tty)")
        } else {
            t.expectNil(ProcessProbe.tty(of: me), "no controlling terminal")
        }
        // launchd never has a terminal.
        t.expectNil(ProcessProbe.tty(of: 1), "launchd has no tty")
    }

    t.test("ProcessProbe: tty and parent agree with `ps` for the processes running right now") {
        let listing = ExternalTool.run("/bin/ps", ["-axo", "pid=,ppid=,tty="], timeout: 10)
        t.expect(listing.succeeded, "ps ran")
        var compared = 0, withTerminal = 0
        var mismatches: [String] = []
        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            let expectedTTY: String? = fields[2].contains("?") ? nil : "/dev/" + fields[2]
            let foundTTY = ProcessProbe.tty(of: pid), foundParent = ProcessProbe.parent(of: pid)
            // Processes come and go while we look; only compare those that are still there afterwards.
            guard ProcessProbe.isAlive(pid) else { continue }
            compared += 1
            if expectedTTY != nil { withTerminal += 1 }
            if foundTTY != expectedTTY { mismatches.append("pid \(pid): tty \(foundTTY ?? "nil") vs ps \(expectedTTY ?? "nil")") }
            if pid != 1, foundParent != parent { mismatches.append("pid \(pid): parent \(foundParent ?? -1) vs ps \(parent)") }
        }
        t.expect(compared > 20, "compared \(compared) processes (\(withTerminal) with a terminal)")
        // A process may change parent (its parent exits) between the two looks; allow a stray one.
        t.expect(mismatches.count <= 2, "disagreements with ps: \(mismatches.prefix(5))")
    }

    t.test("ProcessProbe: ancestors run from the parent up to launchd") {
        let chain = ProcessProbe.ancestors(of: me)
        t.expectEqual(chain.first, myParent, "nearest ancestor is the parent")
        t.expectEqual(chain.last, 1, "the chain ends at launchd")
        t.expectEqual(Set(chain).count, chain.count, "no pid appears twice")
        t.expect(!chain.contains(me), "a process is not its own ancestor")
    }

    t.test("ProcessProbe: missing and nonsense pids are handled quietly") {
        for pid: Int32 in [0, -1, -4242, 99_999_999, Int32.max] {
            t.expect(!ProcessProbe.isAlive(pid), "pid \(pid) is not alive")
            t.expectNil(ProcessProbe.tty(of: pid), "pid \(pid) has no tty")
            t.expectNil(ProcessProbe.parent(of: pid), "pid \(pid) has no parent")
            t.expectNil(ProcessProbe.name(of: pid), "pid \(pid) has no name")
            t.expectNil(ProcessProbe.startTime(of: pid), "pid \(pid) has no start time")
            t.expect(ProcessProbe.ancestors(of: pid).isEmpty, "pid \(pid) has no ancestors")
            t.expectNil(ProcessProbe.hostApp(of: pid), "pid \(pid) has no host app")
        }
    }

    t.test("ProcessProbe: the ancestor walk survives loops and very deep trees") {
        let loop: [Int32: Int32] = [10: 11, 11: 12, 12: 10]
        t.expectEqual(ProcessProbe.ancestors(of: 10, parentOf: { loop[$0] }), [11, 12, 10], "a cycle stops after one lap")
        t.expectEqual(ProcessProbe.ancestors(of: 5, parentOf: { _ in 5 }), [], "a process that is its own parent")
        let deep = ProcessProbe.ancestors(of: 1_000, parentOf: { $0 + 1 })
        t.expectEqual(deep.count, 64, "depth is capped")
    }

    t.test("ProcessProbe: the host app is the nearest ordinary app, skipping background helpers") {
        // agent(50) -> shell(40) -> editor helper(30) -> editor(20) -> launchd(1)
        let parents: [Int32: Int32] = [50: 40, 40: 30, 30: 20, 20: 1]
        let apps: [Int32: ProcessProbe.AppFacts] = [
            30: .init(bundleID: "com.microsoft.VSCode.helper", isRegular: false),
            20: .init(bundleID: "com.microsoft.VSCode", isRegular: true),
        ]
        let host = ProcessProbe.hostApp(of: 50, parentOf: { parents[$0] }, appAt: { apps[$0] })
        t.expectEqual(host, HostApp(pid: 20, bundleID: "com.microsoft.VSCode"), "regular app wins over its helper")

        let helperOnly = ProcessProbe.hostApp(of: 50, parentOf: { parents[$0] }, appAt: { $0 == 30 ? apps[30] : nil })
        t.expectEqual(helperOnly, HostApp(pid: 30, bundleID: "com.microsoft.VSCode.helper"), "a helper is better than nothing")

        let none = ProcessProbe.hostApp(of: 50, parentOf: { parents[$0] }, appAt: { _ in nil })
        t.expectNil(none, "no app anywhere in the tree")

        let unnamed = ProcessProbe.hostApp(of: 50, parentOf: { parents[$0] },
                                           appAt: { _ in .init(bundleID: nil, isRegular: true) })
        t.expectNil(unnamed, "apps without a bundle id are ignored")

        let itself = ProcessProbe.hostApp(of: 20, parentOf: { parents[$0] }, appAt: { apps[$0] })
        t.expectEqual(itself?.pid, 20, "an app hosts itself")
    }

    t.test("ProcessProbe: live host lookup and frontmost app do not crash") {
        // The answers depend on where the tests run, so only their shape is checked.
        if let host = ProcessProbe.hostApp(of: me) {
            t.expect(!host.bundleID.isEmpty, "host bundle id is not empty")
            t.expect(ProcessProbe.isAlive(host.pid), "host app is alive")
            t.expectEqual(ProcessProbe.hostBundleID(of: me), host.bundleID, "hostBundleID agrees with hostApp")
        } else {
            t.expectNil(ProcessProbe.hostBundleID(of: me), "no host app, so no bundle id")
        }
        if let front = ProcessProbe.frontmostBundleID { t.expect(!front.isEmpty, "frontmost bundle id is not empty") }
    }
}

// MARK: - ExternalTool

private func runExternalToolTests(_ t: TestRunner) {
    t.test("ExternalTool: collects output and the exit code") {
        let echo = ExternalTool.run("/bin/echo", ["hello", "world"], timeout: 5)
        t.expect(echo.succeeded, "echo succeeds")
        t.expectEqual(echo.stdout, "hello world\n")
        t.expectEqual(echo.trimmedOutput, "hello world")

        let failing = ExternalTool.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 5)
        t.expectEqual(failing.exitCode, 3)
        t.expectEqual(failing.trimmedOutput, "out")
        t.expectEqual(failing.stderr, "err\n")
        t.expect(!failing.succeeded, "non-zero exit is not success")
    }

    t.test("ExternalTool: passes extra environment and survives large output") {
        let env = ExternalTool.run("/bin/sh", ["-c", "printf %s \"$PERCH_TEST_VALUE\""],
                                    environment: ["PERCH_TEST_VALUE": "a b\"c"], timeout: 5)
        t.expectEqual(env.stdout, "a b\"c")
        // Far more than a pipe buffer holds: would deadlock if output were not drained while waiting.
        let big = ExternalTool.run("/bin/sh", ["-c", "head -c 400000 /dev/zero | tr '\\0' 'x'"], timeout: 10)
        t.expectEqual(big.stdout.count, 400_000, "all output arrives")
    }

    t.test("ExternalTool: a hung tool is stopped at the time limit") {
        let started = Date()
        let hung = ExternalTool.run("/bin/sleep", ["30"], timeout: 0.2)
        t.expect(hung.timedOut, "reported as timed out")
        t.expect(!hung.succeeded, "a timeout is not success")
        t.expect(Date().timeIntervalSince(started) < 3, "returned promptly")
    }

    t.test("ExternalTool: a missing tool is an ordinary failure") {
        let missing = ExternalTool.run("/nonexistent/perch-no-such-tool", [], timeout: 1)
        t.expect(missing.launchFailed, "launch failure is reported")
        t.expect(!missing.succeeded)
        t.expectNil(ExternalTool.firstExecutable(["/nonexistent/a", "/nonexistent/b"]))
        t.expectEqual(ExternalTool.firstExecutable(["/nonexistent/a", "/bin/echo"]), "/bin/echo")
    }
}

// MARK: - LoginItem

private final class FakeLoginService: LoginItemService {
    var isRegistered = false
    var failNext = false
    /// When false, register/unregister "succeed" without changing anything (the system refused quietly).
    var takesEffect = true
    var calls: [String] = []

    struct Refused: Error {}

    func register() throws {
        calls.append("register")
        if failNext { throw Refused() }
        if takesEffect { isRegistered = true }
    }

    func unregister() throws {
        calls.append("unregister")
        if failNext { throw Refused() }
        if takesEffect { isRegistered = false }
    }
}

private func runLoginItemTests(_ t: TestRunner) {
    t.test("LoginItem: turning on and off talks to the service only when something must change") {
        let service = FakeLoginService()
        t.expect(LoginItem.setEnabled(true, using: service), "enable succeeds")
        t.expect(service.isRegistered)
        t.expect(LoginItem.setEnabled(true, using: service), "enabling twice is fine")
        t.expectEqual(service.calls, ["register"], "no second registration")
        t.expect(LoginItem.setEnabled(false, using: service), "disable succeeds")
        t.expect(!service.isRegistered)
        t.expect(LoginItem.setEnabled(false, using: service), "disabling twice is fine")
        t.expectEqual(service.calls, ["register", "unregister"])
    }

    t.test("LoginItem: failures answer false instead of crashing") {
        let service = FakeLoginService()
        service.failNext = true
        t.expect(!LoginItem.setEnabled(true, using: service), "a thrown error means false")
        t.expect(!service.isRegistered)
        service.failNext = false
        service.takesEffect = false
        t.expect(!LoginItem.setEnabled(true, using: service), "no error but no effect is still false")
        t.expect(!LoginItem.setEnabled(true, using: nil), "no service at all means false")
        t.expect(!LoginItem.setEnabled(false, using: nil), "no service: cannot confirm either way")
    }

    t.test("LoginItem: following the setting applies it now and on every change") {
        let settings = makeSettings()
        let service = FakeLoginService()
        t.expect(settings.launchAtLogin, "on by default")
        var following: AnyObject? = LoginItem.follow(settings, using: service)
        t.expectEqual(service.calls, ["register"], "applied straight away")
        settings.launchAtLogin = false
        t.expectEqual(service.calls, ["register", "unregister"], "turned off with the setting")
        settings.launchAtLogin = false
        t.expectEqual(service.calls.count, 2, "no change, no call")
        settings.launchAtLogin = true
        t.expect(service.isRegistered, "and back on")
        following = nil
        settings.launchAtLogin = false
        t.expect(service.isRegistered, "after letting go, the setting is no longer followed")
        t.expectNil(following)
        // With no service (unbundled) following is harmless.
        let idle = LoginItem.follow(settings)
        settings.launchAtLogin = true
        idle.cancel()
    }

    t.test("LoginItem: outside an app bundle everything answers false without touching the system") {
        t.expect(!AppBundle.isRealApp, "the test binary is not a bundled app")
        t.expect(!LoginItem.isEnabled, "isEnabled is false when unbundled")
        t.expect(!LoginItem.setEnabled(true), "setEnabled(true) is refused when unbundled")
        t.expect(!LoginItem.setEnabled(false), "setEnabled(false) is refused when unbundled")
        let settings = makeSettings()
        t.expect(!LoginItem.apply(settings), "apply is refused when unbundled")
    }

    t.test("LoginItem: what counts as a bundled app") {
        t.expect(AppBundle.isRealApp(bundleIdentifier: "local.perch.app", bundlePath: "/Applications/Perch.app"))
        t.expect(AppBundle.isRealApp(bundleIdentifier: "local.perch.app", bundlePath: "/tmp/build/Perch.APP"))
        t.expect(!AppBundle.isRealApp(bundleIdentifier: nil, bundlePath: "/Applications/Perch.app"), "no identifier")
        t.expect(!AppBundle.isRealApp(bundleIdentifier: "", bundlePath: "/Applications/Perch.app"), "empty identifier")
        t.expect(!AppBundle.isRealApp(bundleIdentifier: "local.perch.app", bundlePath: "/tmp/.build/tests/System"), "bare binary")
    }
}

// MARK: - Shared helpers

/// Preferences that live only in memory, so tests never read or write ~/Library/Preferences.
private final class SystemTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// Fresh default settings that can be changed freely.
private func makeSettings() -> AppSettings { AppSettings(defaults: SystemTestDefaults()) }

// MARK: - AppleScript builders

private func runScriptTests(_ t: TestRunner, _ home: URL) {
    t.test("AppleScript text: quotes, backslashes and line breaks cannot end the string early") {
        t.expectEqual(AppleScriptText.literal("/dev/ttys003"), "\"/dev/ttys003\"")
        t.expectEqual(AppleScriptText.literal(""), "\"\"")
        t.expectEqual(AppleScriptText.literal("say \"hi\""), "\"say \\\"hi\\\"\"", "quotes are escaped")
        t.expectEqual(AppleScriptText.literal("C:\\dir"), "\"C:\\\\dir\"", "backslashes are doubled")
        t.expectEqual(AppleScriptText.literal("a\\\"b"), "\"a\\\\\\\"b\"", "a backslash before a quote escapes neither")
        t.expectEqual(AppleScriptText.literal("one\ntwo"), "\"one\\ntwo\"", "newline becomes \\n")
        t.expectEqual(AppleScriptText.literal("one\r\ntwo\tthree"), "\"one\\r\\ntwo\\tthree\"", "CR, LF and tab")
        t.expectEqual(AppleScriptText.literal("a\u{0}b\u{7}c\u{1B}d\u{7F}e"), "\"abcde\"", "other control characters are dropped")
        t.expectEqual(AppleScriptText.literal("~/Projets/café ☕️"), "\"~/Projets/café ☕️\"", "ordinary Unicode passes through")
    }

    t.test("AppleScript text: a hostile value stays one single string literal") {
        let hostile = "x\" \n end tell \n do shell script \"touch /tmp/pwned\" --"
        let literal = AppleScriptText.literal(hostile)
        t.expect(literal.hasPrefix("\"") && literal.hasSuffix("\""), "wrapped in quotes")
        t.expect(!literal.contains("\n"), "no raw line break survives")
        // Every quote inside the literal must be preceded by an odd number of backslashes.
        let inner = Array(literal.dropFirst().dropLast())
        var unescapedQuotes = 0
        for (i, ch) in inner.enumerated() where ch == "\"" {
            var slashes = 0
            var j = i - 1
            while j >= 0, inner[j] == "\\" { slashes += 1; j -= 1 }
            if slashes % 2 == 0 { unescapedQuotes += 1 }
        }
        t.expectEqual(unescapedQuotes, 0, "no quote can close the string")
    }

    t.test("Terminal jump script: exact source") {
        let expected = [
            "tell application id \"com.apple.Terminal\"",
            "\tset wantedDevice to \"/dev/ttys003\"",
            "\trepeat with w in windows",
            "\t\ttry",
            "\t\t\trepeat with t in tabs of w",
            "\t\t\t\tif (tty of t) is wantedDevice then",
            "\t\t\t\t\tif miniaturized of w then set miniaturized of w to false",
            "\t\t\t\t\tset selected tab of w to t",
            "\t\t\t\t\tset frontmost of w to true",
            "\t\t\t\t\tset index of w to 1",
            "\t\t\t\t\tactivate",
            "\t\t\t\t\treturn \"focused\"",
            "\t\t\t\tend if",
            "\t\t\tend repeat",
            "\t\tend try",
            "\tend repeat",
            "\treturn \"missing\"",
            "end tell",
        ].joined(separator: "\n")
        t.expectEqual(TerminalScripts.terminalJump(tty: "/dev/ttys003"), expected)
    }

    t.test("Terminal front-tab script: exact source") {
        let expected = [
            "tell application id \"com.apple.Terminal\"",
            "\ttry",
            "\t\treturn tty of selected tab of front window",
            "\tend try",
            "\treturn \"\"",
            "end tell",
        ].joined(separator: "\n")
        t.expectEqual(TerminalScripts.terminalFrontTTY(), expected)
    }

    t.test("iTerm2 jump script: exact source") {
        let expected = [
            "tell application id \"com.googlecode.iterm2\"",
            "\tset wantedID to \"6C5A0B1E-1111-2222-3333-444455556666\"",
            "\tset wantedDevice to \"/dev/ttys007\"",
            "\trepeat with w in windows",
            "\t\ttry",
            "\t\t\trepeat with t in tabs of w",
            "\t\t\t\trepeat with s in sessions of t",
            "\t\t\t\t\tset isMatch to false",
            "\t\t\t\t\tif wantedID is not \"\" and (unique ID of s) is wantedID then set isMatch to true",
            "\t\t\t\t\tif wantedDevice is not \"\" and (tty of s) is wantedDevice then set isMatch to true",
            "\t\t\t\t\tif isMatch then",
            "\t\t\t\t\t\tif miniaturized of w then set miniaturized of w to false",
            "\t\t\t\t\t\ttell w to select",
            "\t\t\t\t\t\ttell t to select",
            "\t\t\t\t\t\ttell s to select",
            "\t\t\t\t\t\tactivate",
            "\t\t\t\t\t\treturn \"focused\"",
            "\t\t\t\t\tend if",
            "\t\t\t\tend repeat",
            "\t\t\tend repeat",
            "\t\tend try",
            "\tend repeat",
            "\treturn \"missing\"",
            "end tell",
        ].joined(separator: "\n")
        t.expectEqual(TerminalScripts.iTermJump(sessionGUID: "6C5A0B1E-1111-2222-3333-444455556666", tty: "/dev/ttys007"), expected)

        let ttyOnly = TerminalScripts.iTermJump(sessionGUID: nil, tty: "/dev/ttys007")
        t.expect(ttyOnly.contains("set wantedID to \"\"\n"), "a missing id becomes an empty string, which the script skips")
        let idOnly = TerminalScripts.iTermJump(sessionGUID: "ABC-1", tty: nil)
        t.expect(idOnly.contains("set wantedDevice to \"\"\n"), "a missing TTY becomes an empty string")
    }

    t.test("iTerm2 front-tab and Ghostty scripts: exact source") {
        let front = [
            "tell application id \"com.googlecode.iterm2\"",
            "\ttry",
            "\t\treturn tty of current session of current window",
            "\tend try",
            "\treturn \"\"",
            "end tell",
        ].joined(separator: "\n")
        t.expectEqual(TerminalScripts.iTermFrontTTY(), front)

        let ghostty = [
            "tell application id \"com.mitchellh.ghostty\"",
            "\tset wantedFolder to \"/Users/me/my project\"",
            "\tset found to every terminal whose working directory is wantedFolder",
            "\tif (count of found) is 0 then return \"missing\"",
            "\tfocus (item 1 of found)",
            "\tactivate",
            "\tif (count of found) is 1 then return \"focused\"",
            "\treturn \"ambiguous\"",
            "end tell",
        ].joined(separator: "\n")
        t.expectEqual(TerminalScripts.ghosttyJump(folder: "/Users/me/my project"), ghostty)
    }

    t.test("Scripts: values are data — awkward TTYs, ids, folders and bundle ids are escaped in place") {
        let nasty = "/dev/tty\"s\\003\nactivate"
        let jump = TerminalScripts.terminalJump(tty: nasty)
        t.expect(jump.contains("set wantedDevice to \"/dev/tty\\\"s\\\\003\\nactivate\"\n"), "TTY is escaped")
        t.expectEqual(jump.components(separatedBy: "\n").count, 18, "the script has no extra lines")

        let iterm = TerminalScripts.iTermJump(sessionGUID: "id\"\n", tty: "t\\")
        t.expect(iterm.contains("set wantedID to \"id\\\"\\n\"\n"), "session id is escaped")
        t.expect(iterm.contains("set wantedDevice to \"t\\\\\"\n"), "a trailing backslash cannot swallow the closing quote")
        t.expectEqual(iterm.components(separatedBy: "\n").count, 24, "the script has no extra lines")

        let ghostty = TerminalScripts.ghosttyJump(folder: "/tmp/it's \"quoted\"\\dir")
        t.expect(ghostty.contains("set wantedFolder to \"/tmp/it's \\\"quoted\\\"\\\\dir\"\n"), "folder is escaped")

        let app = TerminalScripts.terminalFrontTTY(bundleID: "com.example\"\nquit")
        t.expect(app.hasPrefix("tell application id \"com.example\\\"\\nquit\"\n"), "bundle id is escaped too")
        t.expectEqual(app.components(separatedBy: "\n").count, 6)
    }

    t.test("Terminal scripts compile against Terminal's real scripting dictionary (compile only, never run)") {
        let compiler = "/usr/bin/osacompile"
        guard FileManager.default.isExecutableFile(atPath: compiler),
              FileManager.default.fileExists(atPath: "/System/Applications/Utilities/Terminal.app") else {
            t.expect(true, "osacompile or Terminal is unavailable; nothing to check")
            return
        }
        let sources = [
            "jump": TerminalScripts.terminalJump(tty: "/dev/ttys003"),
            "jump-escaped": TerminalScripts.terminalJump(tty: "/dev/tty\"s\\003\nactivate"),
            "front": TerminalScripts.terminalFrontTTY(),
        ]
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let out = home.appendingPathComponent("\(name).scpt").path
            let result = ExternalTool.run(compiler, ["-o", out, "-e", source], timeout: 20)
            t.expect(result.succeeded, "\(name) compiles: \(result.stderr)")
            t.expect(FileManager.default.fileExists(atPath: out), "\(name) produced a compiled script")
        }
        // Reading the compiled script back shows the awkward TTY survived as one string.
        let back = ExternalTool.run("/usr/bin/osadecompile", [home.appendingPathComponent("jump-escaped.scpt").path], timeout: 20)
        t.expect(back.stdout.contains("set wantedDevice to \"/dev/tty\\\"s\\\\003\\nactivate\"")
                 || back.stdout.contains("set wantedDevice to \"/dev/tty\\\"s\\\\003\nactivate\""),
                 "the value is still a single literal after compiling: \(back.stdout.prefix(160))")
    }

    t.test("Script results: output, permission refusal, timeout and other failures are told apart") {
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 0, stdout: "focused\n", stderr: "")), .output("focused"))
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 0, stdout: "", stderr: "")), .output(""))
        let refused = "36:63: execution error: Not authorized to send Apple events to Terminal. (-1743)\n"
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 1, stdout: "", stderr: refused)), .permissionDenied)
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 1, stdout: "", stderr: "execution error: Nicht autorisiert (-1743)")), .permissionDenied,
                      "recognised by the error number in any language")
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 1, stdout: "", stderr: "NOT AUTHORIZED TO SEND APPLE EVENTS to iTerm")), .permissionDenied)
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: -1, stdout: "", stderr: "", timedOut: true)), .timedOut)
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: 1, stdout: "", stderr: "syntax error: Expected end of line. (-2741)\n")),
                      .failed("syntax error: Expected end of line. (-2741)"))
        t.expectEqual(ScriptOutcome(ExternalToolResult(exitCode: -1, stdout: "", stderr: "no such file", launchFailed: true)), .failed("no such file"))
    }
}

// MARK: - Sorting sessions into terminal kinds

private func runTerminalFactsTests(_ t: TestRunner) {
    t.test("Terminal kind: known bundle ids") {
        let cases: [(String, TerminalKind)] = [
            ("com.apple.Terminal", .appleTerminal), ("com.googlecode.iterm2", .iTerm), ("com.mitchellh.ghostty", .ghostty),
            ("net.kovidgoyal.kitty", .kitty), ("com.github.wez.wezterm", .wezTerm), ("dev.warp.Warp-Stable", .warp),
            ("dev.warp.Warp-Preview", .warp), ("com.microsoft.VSCode", .editor), ("com.microsoft.VSCodeInsiders", .editor),
            ("com.vscodium", .editor), ("com.todesktop.230313mzl4w4u92", .editor), ("com.exafunction.windsurf", .editor),
            ("com.google.antigravity", .editor), ("dev.zed.Zed", .editor), ("dev.zed.Zed-Preview", .editor),
            ("com.anthropic.claudefordesktop", .claudeDesktop), ("org.alacritty", .otherApp), ("com.jetbrains.intellij", .otherApp),
            ("COM.APPLE.TERMINAL", .appleTerminal), ("", .unknown),
        ]
        for (bundleID, kind) in cases {
            t.expectEqual(TerminalKind.classify(bundleID: bundleID), kind, bundleID)
        }
    }

    t.test("Terminal kind: from TerminalInfo, the bundle id beats TERM_PROGRAM") {
        // Warp reporting itself as Apple_Terminal must still be Warp.
        let warp = TerminalKind.classify(TerminalInfo(bundleID: "dev.warp.Warp-Stable", termProgram: "Apple_Terminal"))
        t.expectEqual(warp.kind, .warp)
        t.expectEqual(warp.bundleID, "dev.warp.Warp-Stable")
        // Cursor shares TERM_PROGRAM=vscode with VS Code; the bundle id tells them apart.
        let cursor = TerminalKind.classify(TerminalInfo(bundleID: "com.todesktop.230313mzl4w4u92", termProgram: "vscode"))
        t.expectEqual(cursor.kind, .editor)
        t.expectEqual(cursor.bundleID, "com.todesktop.230313mzl4w4u92")
    }

    t.test("Terminal kind: from TerminalInfo without a bundle id") {
        let byProgram: [(String, TerminalKind, String)] = [
            ("Apple_Terminal", .appleTerminal, "com.apple.Terminal"), ("iTerm.app", .iTerm, "com.googlecode.iterm2"),
            ("ghostty", .ghostty, "com.mitchellh.ghostty"), ("WezTerm", .wezTerm, "com.github.wez.wezterm"),
            ("kitty", .kitty, "net.kovidgoyal.kitty"), ("WarpTerminal", .warp, "dev.warp.Warp-Stable"),
            ("vscode", .editor, "com.microsoft.VSCode"), ("zed", .editor, "dev.zed.Zed"),
        ]
        for (program, kind, bundleID) in byProgram {
            let sorted = TerminalKind.classify(TerminalInfo(termProgram: program))
            t.expectEqual(sorted.kind, kind, program)
            t.expectEqual(sorted.bundleID, bundleID, program)
        }
        t.expectEqual(TerminalKind.classify(TerminalInfo(itermSessionID: "w0t0p0:ABCDEF-12")).kind, .iTerm, "ITERM_SESSION_ID alone")
        t.expectEqual(TerminalKind.classify(TerminalInfo(kittyWindowID: "7")).kind, .kitty, "KITTY_WINDOW_ID alone")
        t.expectEqual(TerminalKind.classify(TerminalInfo(weztermPane: "12")).bundleID, "com.github.wez.wezterm", "WEZTERM_PANE alone")
        // Inside tmux TERM_PROGRAM is "tmux", which says nothing about the hosting app.
        let tmux = TerminalKind.classify(TerminalInfo(termProgram: "tmux", tty: "/dev/ttys004", tmuxPane: "%1"))
        t.expectEqual(tmux.kind, .unknown)
        t.expectNil(tmux.bundleID)
        t.expectEqual(TerminalKind.classify(TerminalInfo()).kind, .unknown, "nothing known")
        t.expectEqual(TerminalKind.classify(TerminalInfo(bundleID: "  ")).kind, .unknown, "blank bundle id")
    }

    t.test("Terminal kind: display names") {
        t.expectEqual(TerminalKind.displayName(bundleID: "com.apple.Terminal"), "Terminal")
        t.expectEqual(TerminalKind.displayName(bundleID: "com.googlecode.iterm2"), "iTerm2")
        t.expectEqual(TerminalKind.displayName(bundleID: "com.todesktop.230313mzl4w4u92"), "Cursor")
        t.expectNil(TerminalKind.displayName(bundleID: "com.example.unknown"))
    }

    t.test("Terminal facts: TTYs are tidied, and odd ones are refused") {
        t.expectEqual(TerminalFacts.ttyPath("/dev/ttys003"), "/dev/ttys003")
        t.expectEqual(TerminalFacts.ttyPath("ttys003"), "/dev/ttys003", "the short form `ps` prints")
        t.expectEqual(TerminalFacts.ttyPath("  /dev/ttys012\n"), "/dev/ttys012", "surrounding whitespace")
        for bad in [nil, "", "??", "/dev/", "/dev/ttys003\" & quit", "/dev/../etc/passwd", "ttys 3", "/dev/ttys003\nx",
                    "not a tty", String(repeating: "a", count: 40)] {
            t.expectNil(TerminalFacts.ttyPath(bad), "refused: \(bad ?? "nil")")
        }
    }

    t.test("Terminal facts: iTerm session ids, tmux panes and window numbers") {
        t.expectEqual(TerminalFacts.iTermSessionGUID("w0t1p0:6C5A0B1E-1111-2222-3333-444455556666"), "6C5A0B1E-1111-2222-3333-444455556666")
        t.expectEqual(TerminalFacts.iTermSessionGUID("6C5A0B1E-1111"), "6C5A0B1E-1111", "already just the id")
        for bad in [nil, "", "w0t0p0:", "w0t0p0:abc\"def", "w0t0p0:a b", "w0t0p0:" + String(repeating: "A", count: 80)] {
            t.expectNil(TerminalFacts.iTermSessionGUID(bad), "refused: \(bad ?? "nil")")
        }
        t.expectEqual(TerminalFacts.tmuxPane("%12"), "%12")
        t.expectEqual(TerminalFacts.tmuxPane(" %0 "), "%0")
        for bad in [nil, "", "12", "%", "%1;kill-server", "%-1", "%1 2", "$1"] {
            t.expectNil(TerminalFacts.tmuxPane(bad), "refused: \(bad ?? "nil")")
        }
        t.expectEqual(TerminalFacts.number("42"), "42")
        for bad in [nil, "", "-1", "4 2", "4;2", "1e3", "٣", "1234567890123"] {
            t.expectNil(TerminalFacts.number(bad), "refused: \(bad ?? "nil")")
        }
    }

    t.test("Jump target: built from a session, keeping only well-formed identifiers") {
        var info = TerminalInfo(bundleID: "com.googlecode.iterm2", termProgram: "iTerm.app", tty: "ttys005")
        info.itermSessionID = "w1t2p0:AAAA-BBBB"
        info.tmuxPane = "%3; rm -rf /"
        info.kittyWindowID = "9"
        info.weztermPane = "x"
        let target = JumpTarget(session: makeSession(info, cwd: "/Users/me/app", pid: 321))
        t.expectEqual(target.kind, .iTerm)
        t.expectEqual(target.bundleID, "com.googlecode.iterm2")
        t.expectEqual(target.tty, "/dev/ttys005")
        t.expectEqual(target.iTermSessionGUID, "AAAA-BBBB")
        t.expectNil(target.tmuxPane, "a malformed pane id is dropped")
        t.expectEqual(target.kittyWindowID, "9")
        t.expectNil(target.weztermPane, "a malformed pane number is dropped")
        t.expectEqual(target.folder, "/Users/me/app")
        t.expectEqual(target.pid, 321)
        t.expectNil(JumpTarget(session: makeSession(info, pid: 0)).pid, "pid 0 means unknown")
        t.expectNil(JumpTarget(session: makeSession(info, pid: nil)).pid)
    }
}

// MARK: - tmux / kitty / WezTerm command lines

private func runTerminalToolsTests(_ t: TestRunner) {
    t.test("tmux: command lines") {
        t.expectEqual(TmuxCommands.describePane("%4"),
                      ["display-message", "-p", "-t", "%4", "#{session_id}\t#{window_active}\t#{pane_active}"])
        t.expectEqual(TmuxCommands.selectPane("%4"), ["select-window", "-t", "%4", ";", "select-pane", "-t", "%4"])
        t.expectEqual(TmuxCommands.listClients(session: "$2"),
                      ["list-clients", "-t", "$2", "-F", "#{client_tty}\t#{client_pid}\t#{client_activity}"])
        t.expectEqual(TmuxCommands.listClients(session: nil), ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_activity}"])
        t.expectEqual(TmuxCommands.switchClient(tty: "/dev/ttys004", toPane: "%4"), ["switch-client", "-c", "/dev/ttys004", "-t", "%4"])
    }

    t.test("tmux: reading the pane description") {
        t.expectEqual(TmuxCommands.parsePaneState("$3\t1\t1\n"), TmuxPaneState(sessionID: "$3", isActive: true))
        t.expectEqual(TmuxCommands.parsePaneState("$3\t1\t0\n")?.isActive, false, "another pane is selected")
        t.expectEqual(TmuxCommands.parsePaneState("$3\t0\t1\n")?.isActive, false, "another window is selected")
        for bad in ["", "\n", "garbage", "$3\t1", "3\t1\t1", "$x\t1\t1", "$3\t1\t1\textra"] {
            t.expectNil(TmuxCommands.parsePaneState(bad), "refused: \(bad)")
        }
    }

    t.test("tmux: reading the client list, most recently used first") {
        let output = "/dev/ttys004\t501\t1700000100\n/dev/ttys009\t777\t1700000900\nnot-a-tty!\t1\t5\n/dev/ttys011\n"
        let clients = TmuxCommands.parseClients(output)
        t.expectEqual(clients.map(\.tty), ["/dev/ttys009", "/dev/ttys004", "/dev/ttys011"])
        t.expectEqual(clients.first?.pid, 777)
        t.expectEqual(clients.last, TmuxClient(tty: "/dev/ttys011", pid: nil, lastActivity: 0), "missing fields are tolerated")
        t.expect(TmuxCommands.parseClients("").isEmpty, "no clients = detached")
        t.expectNil(TmuxCommands.parseClients("/dev/ttys001\t-5\tabc").first?.pid, "nonsense pid is ignored")
    }

    t.test("kitty: command line and socket guesses") {
        t.expectEqual(KittyCommands.focusWindow(id: "7", socketPath: "/tmp/mykitty-4321"),
                      ["@", "--to", "unix:/tmp/mykitty-4321", "focus-window", "--match", "id:7"])
        let names = ["com.apple.launchd.x", "mykitty-4321", "kitty-99", "sock-4321", "notes.txt", "KittySocket"]
        t.expectEqual(KittyCommands.socketCandidates(fileNames: names, kittyPID: 4321), ["mykitty-4321", "sock-4321", "KittySocket", "kitty-99"],
                      "names ending in kitty's pid first, then anything mentioning kitty")
        t.expectEqual(KittyCommands.socketCandidates(fileNames: names, kittyPID: nil), ["KittySocket", "kitty-99", "mykitty-4321"])
        t.expect(KittyCommands.socketCandidates(fileNames: [], kittyPID: 1).isEmpty)
        t.expectEqual(KittyCommands.toolPaths(appBundlePath: "/Apps/kitty.app").first, "/Apps/kitty.app/Contents/MacOS/kitten")
    }

    t.test("WezTerm: command lines and reading the pane list") {
        t.expectEqual(WezTermCommands.listPanes, ["cli", "list", "--format", "json"])
        t.expectEqual(WezTermCommands.activateTab(3), ["cli", "activate-tab", "--tab-id", "3"])
        t.expectEqual(WezTermCommands.activatePane(12), ["cli", "activate-pane", "--pane-id", "12"])
        t.expectEqual(WezTermCommands.toolPaths(appBundlePath: "/Apps/WezTerm.app").first, "/Apps/WezTerm.app/Contents/MacOS/wezterm")

        let json = """
        [{"window_id":0,"tab_id":3,"pane_id":12,"workspace":"default","title":"zsh","cwd":"file:///Users/me/app","tty_name":"/dev/ttys006","future_field":{"a":1}},
         {"window_id":0,"tab_id":4,"pane_id":13,"tty_name":null},
         {"tab_id":9,"title":"no pane id"},
         "not an object"]
        """
        t.expect(WezTermCommands.parsePanes(json).isEmpty, "a list with a non-object entry is not trusted")
        let clean = """
        [{"window_id":0,"tab_id":3,"pane_id":12,"cwd":"file:///Users/me/app","tty_name":"/dev/ttys006","future_field":{"a":1}},
         {"window_id":0,"tab_id":4,"pane_id":13,"tty_name":null},
         {"tab_id":9,"title":"no pane id"}]
        """
        let panes = WezTermCommands.parsePanes(clean)
        t.expectEqual(panes, [WezTermPane(paneID: 12, tabID: 3, tty: "/dev/ttys006"), WezTermPane(paneID: 13, tabID: 4, tty: nil)])
        t.expectEqual(WezTermCommands.findPane(in: panes, paneID: "13", tty: "/dev/ttys006")?.paneID, 13, "the pane id wins")
        t.expectEqual(WezTermCommands.findPane(in: panes, paneID: "99", tty: "/dev/ttys006")?.paneID, 12, "a stale id falls back to the TTY")
        t.expectEqual(WezTermCommands.findPane(in: panes, paneID: nil, tty: "/dev/ttys006")?.tabID, 3)
        t.expectNil(WezTermCommands.findPane(in: panes, paneID: nil, tty: "/dev/ttys999"))
        t.expectNil(WezTermCommands.findPane(in: panes, paneID: nil, tty: nil))
        for bad in ["", "{}", "not json", "[1,2,3]", "null"] {
            t.expect(WezTermCommands.parsePanes(bad).isEmpty, "unreadable list: \(bad)")
        }
    }
}

// MARK: - BriefCache

private func runBriefCacheTests(_ t: TestRunner) {
    t.test("BriefCache: a fresh answer is reused without loading again") {
        let cache = BriefCache<String, Int>(freshFor: 5, usableFor: 10, waitLimit: 1)
        let loads = Guarded(0)
        let load: () -> Int = { loads.set(loads.get() + 1); return 7 }
        t.expectEqual(cache.value(for: "a", load: load), 7, "first call waits for the load")
        t.expectEqual(cache.value(for: "a", load: load), 7)
        t.expectEqual(cache.value(for: "a", load: load), 7)
        t.expectEqual(loads.get(), 1, "loaded once")
        t.expectEqual(cache.value(for: "b", load: { 9 }), 9, "keys are separate")
        cache.removeAll()
        t.expectEqual(cache.value(for: "a", load: load), 7)
        t.expectEqual(loads.get(), 2, "removeAll forgets")
    }

    t.test("BriefCache: an older answer is handed out at once while a new one is fetched") {
        let clock = Guarded(Date(timeIntervalSince1970: 1_000))
        let cache = BriefCache<String, Int>(freshFor: 1, usableFor: 10, waitLimit: 1, now: { clock.get() })
        let next = Guarded(1)
        let load: () -> Int = { let v = next.get(); next.set(v + 1); return v }
        t.expectEqual(cache.value(for: "k", load: load), 1)
        clock.set(Date(timeIntervalSince1970: 1_003))          // older than fresh, still usable
        t.expectEqual(cache.value(for: "k", load: load), 1, "the old answer comes back immediately")
        t.wait(2) { cache.value(for: "k", load: load) == 2 }    // until the background refresh has landed
        t.expectEqual(cache.value(for: "k", load: load), 2, "the refreshed answer is used next time")
        t.expectEqual(next.get(), 3, "exactly one refresh ran")
        clock.set(Date(timeIntervalSince1970: 1_100))          // far too old to use
        t.expectEqual(cache.value(for: "k", load: load), 3, "an expired answer is never handed out")
    }

    t.test("BriefCache: a slow load makes the caller give up after the wait limit, and the answer is kept") {
        let cache = BriefCache<String, String>(freshFor: 5, usableFor: 10, waitLimit: 0.05)
        let loads = Guarded(0)
        let slow: () -> String = { loads.set(loads.get() + 1); Thread.sleep(forTimeInterval: 0.3); return "late" }
        let started = Date()
        t.expectNil(cache.value(for: "k", load: slow), "no answer in time")
        t.expectNil(cache.value(for: "k", load: slow), "still loading: asks again without starting a second load")
        t.expect(Date().timeIntervalSince(started) < 0.25, "the caller was not kept waiting for the slow load")
        Thread.sleep(forTimeInterval: 0.45)
        t.expectEqual(cache.value(for: "k", load: slow), "late", "the answer that arrived later is there now")
        t.expectEqual(loads.get(), 1, "only one load ran")
    }
}

// MARK: - A pretend Mac for the terminal jumper

/// Stands in for macOS: remembers what the jumper asked for and answers from a script.
private final class FakeTerminalSystem: TerminalSystem {
    var front: String?
    var hosts: [Int32: String] = [:]
    var running: [String: RunningApp] = [:]
    var directories: Set<String> = []
    var executables: Set<String> = []
    var ancestorTools: [String: String] = [:]
    var files: [String: [String]] = [:]
    var permission = AutomationPermission.granted
    var activateSucceeds = true
    var scriptDelay: TimeInterval = 0
    var onScript: (String) -> ScriptOutcome = { _ in .output("missing") }
    var onTool: (String, [String]) -> ExternalToolResult = { _, _ in ExternalToolResult(exitCode: 1, stdout: "", stderr: "") }

    private let lock = NSLock()
    private var recorded: [String] = []

    /// Everything that was asked, in order, e.g. "activate com.apple.Terminal".
    var log: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var scripts: [String] { log.filter { $0.hasPrefix("script ") }.map { String($0.dropFirst(7)) } }
    var tools: [String] { log.filter { $0.hasPrefix("tool ") }.map { String($0.dropFirst(5)) } }
    var activations: [String] { log.filter { $0.hasPrefix("activate ") }.map { String($0.dropFirst(9)) } }
    var folderOpens: [String] { log.filter { $0.hasPrefix("open ") }.map { String($0.dropFirst(5)) } }
    var permissionChecks: Int { log.filter { $0.hasPrefix("permission ") }.count }
    private func record(_ line: String) { lock.lock(); recorded.append(line); lock.unlock() }

    func run(_ bundleID: String, pid: Int32 = 100, name: String? = nil, bundlePath: String? = nil) {
        running[bundleID] = RunningApp(pid: pid, name: name, bundlePath: bundlePath)
    }

    func frontmostBundleID() -> String? { front }
    func hostBundleID(of pid: Int32) -> String? { record("host \(pid)"); return hosts[pid] }
    func runningApp(bundleID: String) -> RunningApp? { running[bundleID] }
    func activate(bundleID: String) -> Bool { record("activate \(bundleID)"); return activateSucceeds && running[bundleID] != nil }
    func openFolder(_ path: String, inApp bundleID: String) -> Bool { record("open \(path) in \(bundleID)"); return running[bundleID] != nil }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func runAppleScript(_ source: String, timeout: TimeInterval) -> ScriptOutcome {
        record("script \(source)")
        if scriptDelay > 0 { Thread.sleep(forTimeInterval: scriptDelay) }
        return onScript(source)
    }
    func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) -> ExternalToolResult {
        record("tool \(path) \(arguments.joined(separator: " "))")
        return onTool(path, arguments)
    }
    func firstExecutable(_ candidates: [String]) -> String? { candidates.first(where: executables.contains) }
    func ancestorExecutable(named name: String, of pid: Int32) -> String? { ancestorTools[name] }
    func fileNames(in directory: String) -> [String] { files[directory] ?? [] }
    func automationPermission(for bundleID: String) -> AutomationPermission { record("permission \(bundleID)"); return permission }
}

private let terminalID = "com.apple.Terminal"
private let iTermID = "com.googlecode.iterm2"
private let ghosttyID = "com.mitchellh.ghostty"
private let kittyID = "net.kovidgoyal.kitty"
private let wezTermID = "com.github.wez.wezterm"
private let codeID = "com.microsoft.VSCode"
private let cursorID = "com.todesktop.230313mzl4w4u92"

private func makeSession(_ terminal: TerminalInfo, cwd: String = "/Users/me/project", pid: Int32? = 4242, demo: Bool = false) -> Session {
    var session = Session(id: Session.makeID(.claude, "abc"), agent: .claude, sessionID: "abc", cwd: cwd, title: "Test",
                          state: .working, stateSince: Date(), startedAt: Date(), lastEventAt: Date())
    session.terminal = terminal
    session.pid = pid
    session.isDemo = demo
    return session
}

private func ok(_ stdout: String = "") -> ExternalToolResult { ExternalToolResult(exitCode: 0, stdout: stdout, stderr: "") }
private let toolFailure = ExternalToolResult(exitCode: 1, stdout: "", stderr: "failed")

/// Short limits so a test that has to wait does not wait long.
private func quickTiming() -> TerminalJumper.Timing {
    var timing = TerminalJumper.Timing()
    timing.jumpWait = 2
    timing.frontWait = 1
    return timing
}

// MARK: - TerminalJumper.jump

private func runJumpTests(_ t: TestRunner) {
    func setUp(_ configure: (FakeTerminalSystem) -> Void = { _ in }) -> (FakeTerminalSystem, TerminalJumper) {
        let system = FakeTerminalSystem()
        configure(system)
        return (system, TerminalJumper(system: system, timing: quickTiming()))
    }

    t.test("Jump: Terminal tab found by TTY is reported as focused") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.onScript = { _ in .output("focused") } }
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, termProgram: "Apple_Terminal", tty: "/dev/ttys003")))
        t.expectEqual(result, .focused)
        t.expectEqual(system.scripts, [TerminalScripts.terminalJump(tty: "/dev/ttys003")], "exactly the Terminal jump script ran")
        t.expect(system.activations.isEmpty, "the script already brought Terminal forward")
    }

    t.test("Jump: Terminal tab not found falls back to bringing the app forward") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.onScript = { _ in .output("missing") } }
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "ttys003")))
        t.expectEqual(result, .activatedApp)
        t.expectEqual(system.scripts.count, 1)
        t.expectEqual(system.activations, [terminalID])
    }

    t.test("Jump: a failing or unexpected script answer also falls back to the app") {
        for outcome in [ScriptOutcome.failed("syntax error"), .timedOut, .output("something else"), .output("")] {
            let (system, jumper) = setUp { $0.run(terminalID); $0.onScript = { _ in outcome } }
            t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003"))), .activatedApp, "\(outcome)")
            t.expectEqual(system.activations, [terminalID], "\(outcome)")
        }
    }

    t.test("Jump: Automation permission denied brings the app forward and explains where to allow it") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.onScript = { _ in .permissionDenied } }
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003")))
        guard case .failed(let reason) = result else { t.expect(false, "expected .failed, got \(result)"); return }
        t.expect(reason.contains("System Settings → Privacy & Security → Automation"), "says where to allow it: \(reason)")
        t.expect(reason.contains("Terminal"), "names the app")
        t.expectEqual(reason, TerminalJumper.automationHelp(appName: "Terminal"))
        t.expectEqual(system.activations, [terminalID], "the app still came forward")
    }

    t.test("Jump: an app that is no longer open is an honest failure, and nothing is launched") {
        let (system, jumper) = setUp()
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003"), pid: nil))
        t.expectEqual(result, .failed("Terminal is not open any more."))
        t.expect(system.scripts.isEmpty && system.activations.isEmpty && system.tools.isEmpty, "nothing was run")
    }

    t.test("Jump: without a usable TTY only the app is raised, and no script is built from bad data") {
        for tty in [nil, "??", "/dev/ttys003\" & (do shell script \"id\") & \""] {
            let (system, jumper) = setUp { $0.run(terminalID) }
            t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: tty))), .activatedApp, tty ?? "nil")
            t.expect(system.scripts.isEmpty, "no script for tty \(tty ?? "nil")")
            t.expectEqual(system.activations, [terminalID])
        }
    }

    t.test("Jump: iTerm2 session found by its id, or by TTY") {
        let (system, jumper) = setUp { $0.run(iTermID); $0.onScript = { _ in .output("focused") } }
        var info = TerminalInfo(bundleID: iTermID, termProgram: "iTerm.app", tty: "/dev/ttys007")
        info.itermSessionID = "w0t2p0:6C5A-0B1E"
        t.expectEqual(jumper.jump(to: makeSession(info)), .focused)
        t.expectEqual(system.scripts, [TerminalScripts.iTermJump(sessionGUID: "6C5A-0B1E", tty: "/dev/ttys007")])

        let (ttySystem, ttyJumper) = setUp { $0.run(iTermID); $0.onScript = { _ in .output("focused") } }
        t.expectEqual(ttyJumper.jump(to: makeSession(TerminalInfo(bundleID: iTermID, tty: "/dev/ttys007"))), .focused)
        t.expectEqual(ttySystem.scripts, [TerminalScripts.iTermJump(sessionGUID: nil, tty: "/dev/ttys007")])

        let (bareSystem, bareJumper) = setUp { $0.run(iTermID) }
        t.expectEqual(bareJumper.jump(to: makeSession(TerminalInfo(bundleID: iTermID))), .activatedApp, "nothing to match on")
        t.expect(bareSystem.scripts.isEmpty)
    }

    t.test("Jump: Ghostty is matched by folder; an uncertain match is not called focused") {
        let info = TerminalInfo(bundleID: ghosttyID, termProgram: "ghostty", tty: "/dev/ttys002")
        let (one, oneJumper) = setUp { $0.run(ghosttyID); $0.onScript = { _ in .output("focused") } }
        t.expectEqual(oneJumper.jump(to: makeSession(info, cwd: "/Users/me/app")), .focused)
        t.expectEqual(one.scripts, [TerminalScripts.ghosttyJump(folder: "/Users/me/app")])

        let (several, severalJumper) = setUp { $0.run(ghosttyID); $0.onScript = { _ in .output("ambiguous") } }
        t.expectEqual(severalJumper.jump(to: makeSession(info)), .activatedApp, "several terminals share the folder")
        t.expect(several.activations.isEmpty, "the script already activated Ghostty; no second activation")

        let (none, noneJumper) = setUp { $0.run(ghosttyID); $0.onScript = { _ in .output("missing") } }
        t.expectEqual(noneJumper.jump(to: makeSession(info)), .activatedApp)
        t.expectEqual(none.activations, [ghosttyID])
    }

    t.test("Jump: kitty window focused through its remote control, then the app is raised") {
        let (system, jumper) = setUp {
            $0.run(kittyID, pid: 4321, bundlePath: "/Applications/kitty.app")
            $0.executables = ["/Applications/kitty.app/Contents/MacOS/kitten"]
            $0.files = ["/tmp": ["mykitty-4321", "unrelated"]]
            $0.onTool = { _, _ in ok() }
        }
        var info = TerminalInfo(bundleID: kittyID)
        info.kittyWindowID = "7"
        t.expectEqual(jumper.jump(to: makeSession(info)), .focused)
        t.expectEqual(system.tools, ["/Applications/kitty.app/Contents/MacOS/kitten @ --to unix:/tmp/mykitty-4321 focus-window --match id:7"])
        t.expectEqual(system.activations, [kittyID])

        let (noTool, noToolJumper) = setUp { $0.run(kittyID) }
        t.expectEqual(noToolJumper.jump(to: makeSession(info)), .activatedApp, "kitten not found")
        t.expect(noTool.tools.isEmpty)

        let (refused, refusedJumper) = setUp {
            $0.run(kittyID, pid: 4321, bundlePath: "/Applications/kitty.app")
            $0.executables = ["/Applications/kitty.app/Contents/MacOS/kitten"]
            $0.files = ["/tmp": ["mykitty-4321"]]
        }
        t.expectEqual(refusedJumper.jump(to: makeSession(info)), .activatedApp, "remote control is off")
        t.expectEqual(refused.activations, [kittyID])
    }

    t.test("Jump: WezTerm pane focused through its command-line tool") {
        let list = "[{\"tab_id\":3,\"pane_id\":12,\"tty_name\":\"/dev/ttys006\"},{\"tab_id\":4,\"pane_id\":13,\"tty_name\":\"/dev/ttys008\"}]"
        let configure: (FakeTerminalSystem) -> Void = {
            $0.run(wezTermID, bundlePath: "/Applications/WezTerm.app")
            $0.executables = ["/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            $0.onTool = { _, arguments in arguments.contains("list") ? ok(list) : ok() }
        }
        let (system, jumper) = setUp(configure)
        var info = TerminalInfo(bundleID: wezTermID, termProgram: "WezTerm", tty: "/dev/ttys006")
        info.weztermPane = "13"
        t.expectEqual(jumper.jump(to: makeSession(info)), .focused)
        let tool = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        t.expectEqual(system.tools, ["\(tool) cli list --format json", "\(tool) cli activate-tab --tab-id 4", "\(tool) cli activate-pane --pane-id 13"])
        t.expectEqual(system.activations, [wezTermID])

        let (byTTY, byTTYJumper) = setUp(configure)
        t.expectEqual(byTTYJumper.jump(to: makeSession(TerminalInfo(bundleID: wezTermID, tty: "/dev/ttys006"))), .focused)
        t.expectEqual(byTTY.tools.last, "\(tool) cli activate-pane --pane-id 12", "found by TTY when the pane id is unknown")

        let (gone, goneJumper) = setUp(configure)
        t.expectEqual(goneJumper.jump(to: makeSession(TerminalInfo(bundleID: wezTermID, tty: "/dev/ttys099"))), .activatedApp, "pane no longer exists")
        t.expectEqual(gone.tools.count, 1, "only the list ran")
    }

    t.test("Jump: apps without tab control (Warp, Claude desktop, others) are simply raised") {
        for bundleID in ["dev.warp.Warp-Stable", "com.anthropic.claudefordesktop", "org.alacritty", "com.jetbrains.intellij"] {
            let (system, jumper) = setUp { $0.run(bundleID, name: "Some App") }
            t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: bundleID, tty: "/dev/ttys001"))), .activatedApp, bundleID)
            t.expectEqual(system.activations, [bundleID])
            t.expect(system.scripts.isEmpty && system.tools.isEmpty, "no script or tool for \(bundleID)")
        }
        let (system, jumper) = setUp { $0.run("org.alacritty", name: "Alacritty"); $0.activateSucceeds = false }
        t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: "org.alacritty"))), .failed("Could not bring Alacritty to the front."))
        t.expectEqual(system.activations.count, 1)
    }

    t.test("Jump: editors get the session's folder reopened, which raises the window that has it") {
        for bundleID in [codeID, cursorID, "com.exafunction.windsurf", "com.google.antigravity", "dev.zed.Zed"] {
            let (system, jumper) = setUp { $0.run(bundleID); $0.directories = ["/Users/me/project"] }
            t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: bundleID, termProgram: "vscode"))), .activatedApp, bundleID)
            t.expectEqual(system.folderOpens, ["/Users/me/project in \(bundleID)"])
            t.expect(system.activations.isEmpty && system.scripts.isEmpty)
        }
        let (system, jumper) = setUp { $0.run(codeID) }
        t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: codeID), cwd: "/gone/folder")), .activatedApp)
        t.expect(system.folderOpens.isEmpty, "a folder that does not exist is not opened")
        t.expectEqual(system.activations, [codeID], "the editor is raised instead")
    }

    t.test("Jump: an unknown host is found by walking up from the session's process") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.hosts = [4242: terminalID]; $0.onScript = { _ in .output("focused") } }
        t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(tty: "/dev/ttys003"))), .focused)
        t.expectEqual(system.scripts, [TerminalScripts.terminalJump(tty: "/dev/ttys003")], "treated as Terminal once the host is known")

        let (lost, lostJumper) = setUp()
        t.expectEqual(lostJumper.jump(to: makeSession(TerminalInfo(tty: "/dev/ttys003"))),
                      .failed("Perch could not tell which app this session is running in."))
        t.expect(lost.activations.isEmpty)
        t.expectEqual(lostJumper.jump(to: makeSession(TerminalInfo(), pid: nil)),
                      .failed("Perch could not tell which app this session is running in."), "no pid either")
    }

    t.test("Jump: when the recorded app is not running, the process tree gets the final say") {
        // TERM_PROGRAM=vscode was recorded as VS Code, but the session really runs inside Cursor.
        let (system, jumper) = setUp { $0.run(cursorID); $0.hosts = [4242: cursorID]; $0.directories = ["/Users/me/project"] }
        t.expectEqual(jumper.jump(to: makeSession(TerminalInfo(bundleID: codeID, termProgram: "vscode"))), .activatedApp)
        t.expectEqual(system.folderOpens, ["/Users/me/project in \(cursorID)"])
        // The process lookup is remembered for the next jump.
        _ = jumper.jump(to: makeSession(TerminalInfo(bundleID: codeID, termProgram: "vscode")))
        t.expectEqual(system.log.filter { $0 == "host 4242" }.count, 1, "the process tree was only walked once")
    }

    t.test("Jump: demo sessions touch nothing") {
        let (system, jumper) = setUp { $0.run(terminalID) }
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003"), demo: true))
        guard case .failed = result else { t.expect(false, "expected .failed, got \(result)"); return }
        t.expect(system.log.isEmpty, "nothing was asked of the system")
    }

    t.test("Jump: tmux pane is selected first, then the tab showing tmux is focused by the client's TTY") {
        let (system, jumper) = setUp {
            $0.run(terminalID); $0.run(iTermID)
            $0.ancestorTools = ["tmux": "/opt/homebrew/bin/tmux"]
            $0.hosts = [777: iTermID]
            $0.onScript = { _ in .output("focused") }
            $0.onTool = { _, arguments in
                switch arguments.first {
                case "display-message": return ok("$1\t0\t1\n")
                case "list-clients": return ok("/dev/ttys004\t501\t100\n/dev/ttys009\t777\t900\n")
                default: return ok()
                }
            }
        }
        // Recorded facts date from when tmux was started in Terminal; it is now attached from iTerm2.
        var info = TerminalInfo(bundleID: terminalID, termProgram: "tmux", tty: "/dev/ttys050")
        info.tmuxPane = "%3"
        info.itermSessionID = "w0t0p0:STALE-ID"
        t.expectEqual(jumper.jump(to: makeSession(info)), .focused)
        let tmux = "/opt/homebrew/bin/tmux"
        t.expectEqual(system.tools, [
            "\(tmux) display-message -p -t %3 #{session_id}\t#{window_active}\t#{pane_active}",
            "\(tmux) select-window -t %3 ; select-pane -t %3",
            "\(tmux) list-clients -t $1 -F #{client_tty}\t#{client_pid}\t#{client_activity}",
        ])
        t.expectEqual(system.scripts, [TerminalScripts.iTermJump(sessionGUID: nil, tty: "/dev/ttys009")],
                      "the most recent client's TTY and app are used; tmux's inner TTY and the stale iTerm id are not")
    }

    t.test("Jump: tmux session nobody is attached to — another attached terminal is pointed at it") {
        let (system, jumper) = setUp {
            $0.run(terminalID)
            $0.executables = ["/usr/local/bin/tmux"]
            $0.onScript = { _ in .output("focused") }
            $0.onTool = { _, arguments in
                if arguments.first == "display-message" { return ok("$2\t1\t1\n") }
                if arguments.first == "list-clients" { return arguments.contains("-t") ? ok("") : ok("/dev/ttys004\t501\t100\n") }
                return ok()
            }
        }
        var info = TerminalInfo(bundleID: terminalID, tty: "/dev/ttys050")
        info.tmuxPane = "%8"
        t.expectEqual(jumper.jump(to: makeSession(info)), .focused)
        t.expectEqual(system.tools.last, "/usr/local/bin/tmux switch-client -c /dev/ttys004 -t %8")
        t.expectEqual(system.scripts, [TerminalScripts.terminalJump(tty: "/dev/ttys004")])
    }

    t.test("Jump: inside tmux the app is taken from where tmux is showing, even if none was recorded or it has quit") {
        let configure: (FakeTerminalSystem) -> Void = {
            $0.run(iTermID)
            $0.executables = ["/opt/homebrew/bin/tmux"]
            $0.hosts = [777: iTermID]
            $0.onScript = { _ in .output("focused") }
            $0.onTool = { _, arguments in
                arguments.first == "display-message" ? ok("$1\t1\t1\n") : ok("/dev/ttys009\t777\t900\n")
            }
        }
        // tmux was started from Terminal, which has since been quit; no app recorded at all in the second case.
        for recorded in [terminalID, nil] {
            let (system, jumper) = setUp(configure)
            var info = TerminalInfo(bundleID: recorded, termProgram: "tmux", tty: "/dev/ttys050")
            info.tmuxPane = "%3"
            t.expectEqual(jumper.jump(to: makeSession(info)), .focused, "recorded app: \(recorded ?? "none")")
            t.expectEqual(system.scripts, [TerminalScripts.iTermJump(sessionGUID: nil, tty: "/dev/ttys009")])
        }
        // tmux unreachable and the recorded app gone (or never known): an honest failure.
        var info = TerminalInfo(bundleID: terminalID, tty: "/dev/ttys050")
        info.tmuxPane = "%3"
        let (_, goneJumper) = setUp()
        t.expectEqual(goneJumper.jump(to: makeSession(info)), .failed("Terminal is not open any more."))
        info.bundleID = nil
        let (_, unknownJumper) = setUp()
        t.expectEqual(unknownJumper.jump(to: makeSession(info, pid: nil)), .failed(TerminalJumper.unknownAppMessage))
    }

    t.test("Jump: tmux detached, unreachable or missing only raises the app") {
        var info = TerminalInfo(bundleID: terminalID, tty: "/dev/ttys050")
        info.tmuxPane = "%8"
        // Detached: the pane exists but no terminal shows any tmux session.
        let (detached, detachedJumper) = setUp {
            $0.run(terminalID); $0.executables = ["/opt/homebrew/bin/tmux"]
            $0.onTool = { _, arguments in arguments.first == "display-message" ? ok("$2\t1\t1\n") : ok("") }
        }
        t.expectEqual(detachedJumper.jump(to: makeSession(info)), .activatedApp)
        t.expect(detached.scripts.isEmpty, "tmux's inner TTY is never used to look for a tab")
        t.expectEqual(detached.activations, [terminalID])
        // Unreachable: tmux answers with an error (different server, pane gone).
        let (broken, brokenJumper) = setUp { $0.run(terminalID); $0.executables = ["/opt/homebrew/bin/tmux"]; $0.onTool = { _, _ in toolFailure } }
        t.expectEqual(brokenJumper.jump(to: makeSession(info)), .activatedApp)
        t.expectEqual(broken.tools.count, 1, "gave up after the first failing command")
        // Missing: no tmux program found at all.
        let (missing, missingJumper) = setUp { $0.run(terminalID) }
        t.expectEqual(missingJumper.jump(to: makeSession(info)), .activatedApp)
        t.expect(missing.tools.isEmpty && missing.scripts.isEmpty)
    }

    t.test("Jump: a script that takes too long (a permission question on screen) does not freeze the caller") {
        let system = FakeTerminalSystem()
        system.run(terminalID)
        system.scriptDelay = 0.6
        system.onScript = { _ in .output("focused") }
        var timing = quickTiming()
        timing.jumpWait = 0.1
        let jumper = TerminalJumper(system: system, timing: timing)
        let started = Date()
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003")))
        t.expect(Date().timeIntervalSince(started) < 0.5, "returned at the wait limit")
        guard case .failed(let reason) = result else { t.expect(false, "expected .failed, got \(result)"); return }
        t.expect(reason.contains("did not answer in time") && reason.contains("Allow"), reason)
        Thread.sleep(forTimeInterval: 0.7)   // let the background script finish before the fake goes away
    }

    t.test("Jump: the live jumper can be created and refuses a demo session without touching anything") {
        let jumper = TerminalJumper()
        let result = jumper.jump(to: makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys003"), demo: true))
        t.expectEqual(result, .failed("This is a demo session, so there is no terminal to show."))
        t.expect(!jumper.isFrontmost(makeSession(TerminalInfo(bundleID: terminalID), demo: true)), "demo sessions are never frontmost")
    }
}

// MARK: - The real TerminalSystem (only the parts that are safe to run in a test)

private func runLiveSystemTests(_ t: TestRunner) {
    let system = LiveTerminalSystem()

    t.test("Live system: read-only lookups") {
        let finder = try t.unwrap(system.runningApp(bundleID: "com.apple.finder"), "Finder is always running")
        t.expect(finder.pid > 0 && ProcessProbe.isAlive(finder.pid), "Finder's pid is alive")
        t.expect(finder.bundlePath?.hasSuffix(".app") ?? false, "Finder's bundle path: \(finder.bundlePath ?? "nil")")
        t.expectNil(system.runningApp(bundleID: "local.perch.tests.no-such-app"), "an app that is not running")
        t.expect(system.isDirectory("/tmp") && !system.isDirectory("/bin/echo") && !system.isDirectory("/nonexistent"))
        t.expect(system.fileNames(in: "/System/Library/Sounds").contains("Glass.aiff"))
        t.expect(system.fileNames(in: "/nonexistent").isEmpty, "a missing folder is just empty")
        t.expectEqual(system.firstExecutable(["/nonexistent/x", "/bin/echo"]), "/bin/echo")
        t.expectEqual(system.frontmostBundleID(), ProcessProbe.frontmostBundleID)
        t.expectEqual(system.hostBundleID(of: getpid()), ProcessProbe.hostBundleID(of: getpid()))
        if let parentName = ProcessProbe.name(of: getppid()) {
            t.expectEqual(system.ancestorExecutable(named: parentName, of: getpid()), ProcessProbe.executablePath(of: getppid()),
                          "finds the parent by name")
        }
        t.expectNil(system.ancestorExecutable(named: "perch-no-such-process", of: getpid()))
    }

    t.test("Live system: raising or opening in an app that is not running does nothing and says so") {
        t.expect(!system.activate(bundleID: "local.perch.tests.no-such-app"))
        t.expect(!system.openFolder("/tmp", inApp: "local.perch.tests.no-such-app"))
        t.expectEqual(system.automationPermission(for: "local.perch.tests.no-such-app"), .unknown)
    }

    t.test("Live system: osascript runs scripts, reports errors and is stopped when it hangs") {
        // These scripts talk to no other app, so no Automation permission is involved.
        t.expectEqual(system.runAppleScript("return \"perch\" & \" ok\"", timeout: 10), .output("perch ok"))
        if case .failed(let message) = system.runAppleScript("this is not applescript (", timeout: 10) {
            t.expect(!message.isEmpty, "the syntax error is passed on")
        } else {
            t.expect(false, "a syntax error should be a failure")
        }
        let started = Date()
        t.expectEqual(system.runAppleScript("delay 30", timeout: 0.3), .timedOut)
        t.expect(Date().timeIntervalSince(started) < 3, "the hung script was stopped")
    }

    t.test("Live system: asking whether we may script an app never prompts and always answers") {
        // `askUserIfNeeded` is false inside, so this only looks the answer up.
        let answer = Guarded<AutomationPermission?>(nil)
        DispatchQueue.global().async { answer.set(system.automationPermission(for: "com.apple.finder")) }
        t.expect(t.wait(5) { answer.get() != nil }, "an answer arrived: \(String(describing: answer.get()))")
    }
}

// MARK: - TerminalJumper.isFrontmost

private func runFrontmostTests(_ t: TestRunner) {
    func setUp(_ configure: (FakeTerminalSystem) -> Void = { _ in }) -> (FakeTerminalSystem, TerminalJumper) {
        let system = FakeTerminalSystem()
        configure(system)
        return (system, TerminalJumper(system: system, timing: quickTiming()))
    }
    let terminalSession = makeSession(TerminalInfo(bundleID: terminalID, termProgram: "Apple_Terminal", tty: "/dev/ttys003"))

    t.test("Frontmost: a different app in front means no, without running anything") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.run(codeID); $0.front = codeID }
        t.expect(!jumper.isFrontmost(terminalSession))
        t.expect(system.scripts.isEmpty && system.permissionChecks == 0, "nothing was asked")
        let (nobody, nobodyJumper) = setUp { $0.run(terminalID) }
        t.expect(!nobodyJumper.isFrontmost(terminalSession), "no frontmost app at all")
        t.expect(nobody.scripts.isEmpty)
    }

    t.test("Frontmost: Terminal in front with the session's tab selected") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.front = terminalID; $0.onScript = { _ in .output("/dev/ttys003") } }
        t.expect(jumper.isFrontmost(terminalSession))
        t.expectEqual(system.scripts, [TerminalScripts.terminalFrontTTY()], "asked Terminal for the front tab's TTY")
    }

    t.test("Frontmost: Terminal in front but another tab selected, or no window at all") {
        let (_, other) = setUp { $0.run(terminalID); $0.front = terminalID; $0.onScript = { _ in .output("/dev/ttys099") } }
        t.expect(!other.isFrontmost(terminalSession), "a different tab is selected")
        let (_, none) = setUp { $0.run(terminalID); $0.front = terminalID; $0.onScript = { _ in .output("") } }
        t.expect(!none.isFrontmost(terminalSession), "no window open")
    }

    t.test("Frontmost: without Automation permission no script runs and the app-level answer is used") {
        for permission in [AutomationPermission.notAskedYet, .denied, .unknown] {
            let (system, jumper) = setUp { $0.run(terminalID); $0.front = terminalID; $0.permission = permission }
            t.expect(jumper.isFrontmost(terminalSession), "\(permission): the app is in front, which is all we can know")
            t.expect(system.scripts.isEmpty, "\(permission): no script, so no permission question can appear")
            t.expectEqual(system.permissionChecks, 1)
        }
    }

    t.test("Frontmost: a script failure also falls back to the app-level answer") {
        let (_, jumper) = setUp { $0.run(terminalID); $0.front = terminalID; $0.onScript = { _ in .permissionDenied } }
        t.expect(jumper.isFrontmost(terminalSession))
    }

    t.test("Frontmost: repeated questions are answered from memory") {
        let (system, jumper) = setUp { $0.run(terminalID); $0.front = terminalID; $0.onScript = { _ in .output("/dev/ttys003") } }
        let other = makeSession(TerminalInfo(bundleID: terminalID, tty: "/dev/ttys044"))
        for _ in 0..<25 {
            t.expect(jumper.isFrontmost(terminalSession))
            t.expect(!jumper.isFrontmost(other), "one answer serves every session in the same terminal")
        }
        t.expectEqual(system.scripts.count, 1, "one script run for 50 questions")
        t.expectEqual(system.permissionChecks, 1)
    }

    t.test("Frontmost: an answer that does not arrive in time counts as 'not in front', then is used once it lands") {
        let system = FakeTerminalSystem()
        system.run(terminalID)
        system.front = terminalID
        system.scriptDelay = 0.3
        system.onScript = { _ in .output("/dev/ttys003") }
        var timing = quickTiming()
        timing.frontWait = 0.05
        timing.frontFreshFor = 5
        let jumper = TerminalJumper(system: system, timing: timing)
        let started = Date()
        t.expect(!jumper.isFrontmost(terminalSession), "unsure, so say no")
        t.expect(Date().timeIntervalSince(started) < 0.25, "the caller was only held briefly")
        Thread.sleep(forTimeInterval: 0.45)
        t.expect(jumper.isFrontmost(terminalSession), "the late answer is remembered")
        t.expectEqual(system.scripts.count, 1)
    }

    t.test("Frontmost: iTerm2 uses its own front-session script") {
        let (system, jumper) = setUp { $0.run(iTermID); $0.front = iTermID; $0.onScript = { _ in .output("/dev/ttys007\n") } }
        t.expect(jumper.isFrontmost(makeSession(TerminalInfo(bundleID: iTermID, tty: "/dev/ttys007"))))
        t.expectEqual(system.scripts, [TerminalScripts.iTermFrontTTY()])
    }

    t.test("Frontmost: apps whose tabs cannot be checked count as in front when the app is") {
        for bundleID in [codeID, ghosttyID, kittyID, "com.anthropic.claudefordesktop", "dev.warp.Warp-Stable"] {
            let (system, jumper) = setUp { $0.run(bundleID); $0.front = bundleID }
            t.expect(jumper.isFrontmost(makeSession(TerminalInfo(bundleID: bundleID, tty: "/dev/ttys001"))), bundleID)
            t.expect(system.scripts.isEmpty && system.tools.isEmpty && system.permissionChecks == 0, "nothing was run for \(bundleID)")
        }
        let (system, jumper) = setUp { $0.run(terminalID); $0.front = terminalID }
        t.expect(jumper.isFrontmost(makeSession(TerminalInfo(bundleID: terminalID))), "Terminal without a known TTY: app level")
        t.expect(system.scripts.isEmpty)
    }

    t.test("Frontmost: the host app is found from the process when it was not recorded") {
        let (_, jumper) = setUp { $0.run("org.alacritty"); $0.front = "org.alacritty"; $0.hosts = [4242: "org.alacritty"] }
        t.expect(jumper.isFrontmost(makeSession(TerminalInfo(tty: "/dev/ttys003"))))
        let (_, elsewhere) = setUp { $0.run("org.alacritty"); $0.run(codeID); $0.front = codeID; $0.hosts = [4242: "org.alacritty"] }
        t.expect(!elsewhere.isFrontmost(makeSession(TerminalInfo(tty: "/dev/ttys003"))))
        let (_, headless) = setUp { $0.run(codeID); $0.front = codeID }
        t.expect(!headless.isFrontmost(makeSession(TerminalInfo(), pid: nil)), "a session with no terminal is never in front")
    }

    t.test("Frontmost: inside tmux the pane must be active and its terminal tab selected") {
        var info = TerminalInfo(bundleID: terminalID, termProgram: "tmux", tty: "/dev/ttys050")
        info.tmuxPane = "%3"
        let session = makeSession(info)
        func tmuxSystem(active: Bool, clients: String, frontTTY: String) -> (FakeTerminalSystem, TerminalJumper) {
            setUp {
                $0.run(terminalID); $0.front = terminalID
                $0.executables = ["/opt/homebrew/bin/tmux"]
                $0.onScript = { _ in .output(frontTTY) }
                $0.onTool = { _, arguments in arguments.first == "display-message" ? ok("$1\t1\t\(active ? 1 : 0)\n") : ok(clients) }
            }
        }
        let (shown, shownJumper) = tmuxSystem(active: true, clients: "/dev/ttys004\t501\t100\n", frontTTY: "/dev/ttys004")
        t.expect(shownJumper.isFrontmost(session), "active pane, and the tab showing tmux is selected")
        t.expectEqual(shown.tools.count, 2, "pane state and client list")
        let (_, otherTab) = tmuxSystem(active: true, clients: "/dev/ttys004\t501\t100\n", frontTTY: "/dev/ttys050")
        t.expect(!otherTab.isFrontmost(session), "tmux's inner TTY never matches a tab")
        let (hidden, hiddenJumper) = tmuxSystem(active: false, clients: "/dev/ttys004\t501\t100\n", frontTTY: "/dev/ttys004")
        t.expect(!hiddenJumper.isFrontmost(session), "another pane is selected")
        t.expect(hidden.scripts.isEmpty, "no need to ask the terminal")
        let (_, detached) = tmuxSystem(active: true, clients: "", frontTTY: "/dev/ttys004")
        t.expect(!detached.isFrontmost(session), "nothing is attached to the tmux session")
        let (noTmux, noTmuxJumper) = setUp { $0.run(terminalID); $0.front = terminalID }
        t.expect(noTmuxJumper.isFrontmost(session), "tmux cannot be reached: app-level answer")
        t.expect(noTmux.scripts.isEmpty)
    }

    t.test("Frontmost: a jump clears what was remembered about the front tab") {
        var frontTTY = "/dev/ttys099"
        let lock = NSLock()
        let (system, jumper) = setUp {
            $0.run(terminalID); $0.front = terminalID
            $0.onScript = { source in
                lock.lock(); defer { lock.unlock() }
                if source.contains("set wantedDevice") { frontTTY = "/dev/ttys003"; return .output("focused") }
                return .output(frontTTY)
            }
        }
        t.expect(!jumper.isFrontmost(terminalSession), "another tab is in front")
        t.expectEqual(jumper.jump(to: terminalSession), .focused)
        t.expect(jumper.isFrontmost(terminalSession), "asked again after the jump instead of trusting the old answer")
        t.expectEqual(system.scripts.count, 3)
    }
}

// MARK: - Sound synthesis

private let synthPacks: [SoundPack] = [.chime, .arcade, .soft]

/// Rough pitch of a stretch of samples, from how often the wave crosses zero going upwards.
private func estimatedFrequency(_ samples: [Float], from start: Double, to end: Double) -> Double {
    let first = max(0, Int(start * SoundSynth.sampleRate)), last = min(samples.count - 1, Int(end * SoundSynth.sampleRate))
    guard last > first + 1 else { return 0 }
    var crossings = 0
    for i in (first + 1)...last where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(last - first) / SoundSynth.sampleRate)
}

private func runSoundSynthTests(_ t: TestRunner) {
    t.test("Sound synth: every cue in every pack is a short, clean, non-silent buffer") {
        for pack in synthPacks {
            let style = try t.unwrap(SoundSynth.style(for: pack), "\(pack) has a style")
            for cue in SoundCue.allCases {
                let name = "\(pack.rawValue)/\(cue.rawValue)"
                let tune = SoundSynth.tune(for: cue)
                let samples = try t.unwrap(SoundSynth.samples(for: cue, pack: pack), "\(name) renders")
                let seconds = SoundSynth.duration(of: tune, style: style)
                t.expect(seconds >= 0.08 && seconds <= 1.2, "\(name) lasts \(seconds)s (short, but long enough to hear)")
                t.expectEqual(samples.count, Int((seconds * SoundSynth.sampleRate).rounded(.up)), "\(name) has the right number of samples")
                t.expect(samples.allSatisfy(\.isFinite), "\(name) has no NaN or infinity")
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                t.expect(peak <= SoundSynth.peakLimit + 0.0001, "\(name) never clips (peak \(peak))")
                t.expect(abs(Double(peak) - Double(SoundSynth.peakLimit) * tune.level) < 0.001, "\(name) is normalised to its level (peak \(peak))")
                let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
                t.expect(rms > 0.02, "\(name) is not silence (rms \(rms))")
                t.expect(abs(samples[0]) < 0.05, "\(name) starts from silence, so no click")
                t.expect(samples.suffix(200).allSatisfy { abs($0) < 0.01 }, "\(name) ends in silence, so no click")
            }
        }
    }

    t.test("Sound synth: all cues and packs sound different") {
        var seen: [[Float]: String] = [:]
        for pack in synthPacks {
            for cue in SoundCue.allCases {
                let samples = SoundSynth.samples(for: cue, pack: pack) ?? []
                let name = "\(pack.rawValue)/\(cue.rawValue)"
                if let twin = seen[samples] { t.expect(false, "\(name) is identical to \(twin)") } else { t.expect(true) }
                seen[samples] = name
            }
        }
        t.expectEqual(seen.count, synthPacks.count * SoundCue.allCases.count, "24 distinct buffers")
        // The same tune is clearly a different length in each pack.
        let lengths = synthPacks.map { SoundSynth.samples(for: .needsApproval, pack: $0)?.count ?? 0 }
        t.expectEqual(Set(lengths).count, 3, "pack tempos differ: \(lengths)")
        // Rendering is repeatable (the cache in the speaker output relies on it).
        t.expect(SoundSynth.samples(for: .done, pack: .chime) == SoundSynth.samples(for: .done, pack: .chime), "same input, same samples")
    }

    t.test("Sound synth: 'done' rises, 'failed' is low, 'needs approval' knocks three times") {
        // The soft pack plays pure tones, so pitch can be read off the waveform.
        let done = try t.unwrap(SoundSynth.samples(for: .done, pack: .soft))
        let firstNote = estimatedFrequency(done, from: 0.03, to: 0.15)
        let secondNote = estimatedFrequency(done, from: 0.40, to: 0.60)
        t.expect(abs(firstNote - 392) < 20, "first note is about G4 (\(firstNote) Hz)")
        t.expect(abs(secondNote - 587.3) < 30, "second note is about D5, a fifth higher (\(secondNote) Hz)")
        t.expect(secondNote > firstNote * 1.3, "the pair rises")

        for pack in synthPacks {
            let failed = try t.unwrap(SoundSynth.samples(for: .failed, pack: pack))
            let doneInPack = try t.unwrap(SoundSynth.samples(for: .done, pack: pack))
            let failedPitch = estimatedFrequency(failed, from: 0, to: Double(failed.count) / SoundSynth.sampleRate)
            let donePitch = estimatedFrequency(doneInPack, from: 0, to: Double(doneInPack.count) / SoundSynth.sampleRate)
            t.expect(failedPitch < 330, "\(pack.rawValue) failed cue is low (\(failedPitch) Hz)")
            t.expect(failedPitch < donePitch * 0.6, "\(pack.rawValue) failed cue is well below its done cue")
        }

        t.expectEqual(SoundSynth.tune(for: .needsApproval).notes.count, 3, "a triple")
        t.expectEqual(Set(SoundSynth.tune(for: .needsApproval).notes.map(\.semitones)).count, 1, "on one pitch")
        t.expectEqual(SoundSynth.tune(for: .done).notes.count, 2, "a pair")
        t.expect(SoundSynth.tune(for: .failed).isThud, "failed is a thud")
        // Feedback for the user's own clicks is quieter than a call for attention.
        t.expect(SoundSynth.tune(for: .approved).level < SoundSynth.tune(for: .needsApproval).level)
        t.expect(SoundSynth.tune(for: .denied).level < SoundSynth.tune(for: .needsAnswer).level)
    }

    t.test("Sound synth: the system pack maps every cue to a different built-in macOS sound") {
        t.expectNil(SoundSynth.style(for: .system), "the system pack is not synthesized")
        t.expectNil(SoundSynth.samples(for: .done, pack: .system))
        let names = SoundCue.allCases.map(SoundSynth.systemSoundName(for:))
        t.expectEqual(Set(names).count, SoundCue.allCases.count, "no two cues share a sound: \(names)")
        for name in names {
            t.expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"), "\(name) ships with macOS")
        }
        for name in names {
            t.expect(NSSound(named: name) != nil, "macOS can load \(name) by name (loaded, never played)")
        }
        t.expectEqual(SoundPolicy.source(for: .done, pack: .system), .system(name: "Glass", fallback: .done))
        t.expectEqual(SoundPolicy.source(for: .failed, pack: .system), .system(name: "Basso", fallback: .failed))
        t.expectEqual(SoundPolicy.source(for: .done, pack: .arcade), .synthesized(pack: .arcade, cue: .done))
    }

    t.test("Sound synth: WAV files are well-formed") {
        let wav = SoundSynth.wavFile([0, 1, -1, 0.5, 2, -3, .nan])
        t.expectEqual(wav.count, 44 + 7 * 2)
        func text(_ range: Range<Int>) -> String { String(decoding: wav.subdata(in: range), as: UTF8.self) }
        func u32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ at: Int) -> UInt16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        func sample(_ index: Int) -> Int16 { Int16(bitPattern: u16(44 + index * 2)) }
        t.expectEqual(text(0..<4), "RIFF")
        t.expectEqual(u32(4), UInt32(36 + 14), "RIFF size")
        t.expectEqual(text(8..<12), "WAVE")
        t.expectEqual(text(12..<16), "fmt ")
        t.expectEqual(u32(16), 16)
        t.expectEqual(u16(20), 1, "PCM")
        t.expectEqual(u16(22), 1, "mono")
        t.expectEqual(u32(24), 44_100, "sample rate")
        t.expectEqual(u32(28), 88_200, "bytes per second")
        t.expectEqual(u16(32), 2, "bytes per frame")
        t.expectEqual(u16(34), 16, "bits per sample")
        t.expectEqual(text(36..<40), "data")
        t.expectEqual(u32(40), 14, "data size")
        t.expectEqual([sample(0), sample(1), sample(2), sample(3)], [0, 32767, -32767, 16383])
        t.expectEqual([sample(4), sample(5), sample(6)], [32767, -32767, 0], "out-of-range values are clamped and NaN is silence")
        t.expectEqual(SoundSynth.wavFile([]).count, 44, "an empty sound is just a header")
    }

    t.test("Sound synth: macOS accepts a rendered cue as a sound (loaded, never played)") {
        let samples = try t.unwrap(SoundSynth.samples(for: .done, pack: .chime))
        let sound = try t.unwrap(NSSound(data: SoundSynth.wavFile(samples)), "NSSound can read our WAV")
        t.expect(abs(sound.duration - Double(samples.count) / SoundSynth.sampleRate) < 0.005, "duration matches: \(sound.duration)")
        t.expect(!sound.isPlaying, "nothing is playing")
    }
}

// MARK: - Sound rules

private func hour(_ hour: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date(timeIntervalSince1970: 1_780_000_000)) ?? Date()
}

private func runSoundPolicyTests(_ t: TestRunner) {
    t.test("Sound rules: defaults play everything except the session-start cue") {
        let settings = SoundSettings()
        for cue in SoundCue.allCases {
            let expected: SoundDecision = cue == .sessionStart ? .skip(.cueOff) : .play(gain: 0.6)
            t.expectEqual(SoundPolicy.decide(cue, settings: settings), expected, cue.rawValue)
        }
    }

    t.test("Sound rules: each switch silences exactly its own cues") {
        let table: [(String, (inout SoundSettings) -> Void, Set<SoundCue>)] = [
            ("soundOnDone", { $0.onDone = false }, [.done]),
            ("soundOnApproval", { $0.onApproval = false }, [.needsApproval, .approved, .denied]),
            ("soundOnQuestion", { $0.onQuestion = false }, [.needsAnswer]),
            ("soundOnError", { $0.onError = false }, [.failed]),
            ("soundOnStart", { $0.onStart = false }, [.sessionStart]),
        ]
        for (name, change, silenced) in table {
            var settings = SoundSettings()
            settings.onStart = true
            change(&settings)
            for cue in SoundCue.allCases {
                let decision = SoundPolicy.decide(cue, settings: settings)
                t.expectEqual(decision, silenced.contains(cue) ? .skip(.cueOff) : .play(gain: 0.6), "\(name) off → \(cue.rawValue)")
            }
        }
    }

    t.test("Sound rules: master switch, quiet hours and zero volume silence everything; previews ignore mutes") {
        var off = SoundSettings(); off.enabled = false; off.onStart = true
        var quiet = SoundSettings(); quiet.inQuietHours = true; quiet.onStart = true
        var silent = SoundSettings(); silent.volume = 0; silent.onStart = true
        var allOff = SoundSettings()
        allOff.enabled = false; allOff.inQuietHours = true
        allOff.onDone = false; allOff.onApproval = false; allOff.onQuestion = false; allOff.onError = false
        for cue in SoundCue.allCases {
            t.expectEqual(SoundPolicy.decide(cue, settings: off), .skip(.soundsOff), "master off → \(cue.rawValue)")
            t.expectEqual(SoundPolicy.decide(cue, settings: quiet), .skip(.quietHours), "quiet hours → \(cue.rawValue)")
            t.expectEqual(SoundPolicy.decide(cue, settings: silent), .skip(.volumeZero), "volume 0 → \(cue.rawValue)")
            t.expectEqual(SoundPolicy.decide(cue, settings: allOff, preview: true), .play(gain: 0.6), "preview ignores every mute → \(cue.rawValue)")
            t.expectEqual(SoundPolicy.decide(cue, settings: silent, preview: true), .skip(.volumeZero), "preview still follows the volume")
        }
        // Order of reasons: the master switch is reported before anything else.
        var both = SoundSettings(); both.enabled = false; both.inQuietHours = true; both.onDone = false
        t.expectEqual(SoundPolicy.decide(.done, settings: both), .skip(.soundsOff))
    }

    t.test("Sound rules: the volume slider is squared at the bottom and straight above") {
        t.expectEqual(SoundPolicy.gain(forVolume: 0), 0)
        t.expectEqual(SoundPolicy.gain(forVolume: 1), 1)
        t.expectEqual(SoundPolicy.gain(forVolume: 0.6), 0.6)
        t.expectEqual(SoundPolicy.gain(forVolume: 0.25), 0.25, "the two halves meet at the knee")
        t.expect(abs(SoundPolicy.gain(forVolume: 0.1) - 0.04) < 0.0001, "0.1 → 0.04")
        t.expect(abs(SoundPolicy.gain(forVolume: 0.05) - 0.01) < 0.0001, "0.05 → 0.01")
        t.expectEqual(SoundPolicy.gain(forVolume: -3), 0, "below range")
        t.expectEqual(SoundPolicy.gain(forVolume: 7), 1, "above range")
        t.expectEqual(SoundPolicy.gain(forVolume: .nan), 0, "nonsense")
        t.expectEqual(SoundPolicy.gain(forVolume: .infinity), 0, "nonsense")
        var previous: Float = -1
        var rising = true
        for step in 0...100 {
            let gain = SoundPolicy.gain(forVolume: Double(step) / 100)
            if gain < previous { rising = false }
            previous = gain
        }
        t.expect(rising, "louder slider never means quieter sound")
    }

    t.test("Sound rules: settings are read from AppSettings, including quiet hours across midnight") {
        let settings = makeSettings()
        var snapshot = SoundSettings(settings, at: hour(12))
        t.expectEqual(snapshot, SoundSettings(), "the snapshot's defaults mirror AppSettings' defaults")

        settings.soundsEnabled = false; settings.volume = 0.3; settings.soundPack = .arcade
        settings.soundOnDone = false; settings.soundOnApproval = false; settings.soundOnQuestion = false
        settings.soundOnError = false; settings.soundOnStart = true
        snapshot = SoundSettings(settings, at: hour(12))
        t.expect(!snapshot.enabled && snapshot.volume == 0.3 && snapshot.pack == .arcade, "master, volume and pack are copied")
        t.expect(!snapshot.onDone && !snapshot.onApproval && !snapshot.onQuestion && !snapshot.onError && snapshot.onStart, "switches are copied")

        settings.quietHoursEnabled = true
        settings.quietStartHour = 22; settings.quietEndHour = 8
        t.expect(SoundSettings(settings, at: hour(23)).inQuietHours, "23:30 is inside 22–8")
        t.expect(SoundSettings(settings, at: hour(3)).inQuietHours, "03:30 is inside 22–8")
        t.expect(SoundSettings(settings, at: hour(22)).inQuietHours, "22:30 is inside 22–8")
        t.expect(!SoundSettings(settings, at: hour(8)).inQuietHours, "08:30 is outside 22–8")
        t.expect(!SoundSettings(settings, at: hour(12)).inQuietHours, "12:30 is outside 22–8")
        settings.quietStartHour = 13; settings.quietEndHour = 15
        t.expect(SoundSettings(settings, at: hour(14)).inQuietHours, "14:30 is inside 13–15")
        t.expect(!SoundSettings(settings, at: hour(15)).inQuietHours, "15:30 is outside 13–15")
        t.expect(!SoundSettings(settings, at: hour(3)).inQuietHours, "03:30 is outside 13–15")
        settings.quietStartHour = 9; settings.quietEndHour = 9
        t.expect(!SoundSettings(settings, at: hour(9)).inQuietHours, "equal start and end means never")
        settings.quietStartHour = 22; settings.quietEndHour = 8; settings.quietHoursEnabled = false
        t.expect(!SoundSettings(settings, at: hour(23)).inQuietHours, "quiet hours switched off")
    }

    t.test("Rate limiter: the same cue does not repeat straight away") {
        var limiter = SoundRateLimiter()
        let start = Date(timeIntervalSince1970: 5_000)
        t.expect(limiter.admit(.needsApproval, at: start), "first approval chimes")
        t.expect(!limiter.admit(.needsApproval, at: start.addingTimeInterval(0.2)), "a queued second approval does not")
        t.expect(!limiter.admit(.needsApproval, at: start.addingTimeInterval(1.4)))
        t.expect(limiter.admit(.needsApproval, at: start.addingTimeInterval(1.6)), "after the interval it may again")
        t.expectEqual(SoundRateLimiter.repeatInterval(for: .failed), 20, "a session failing over and over thuds rarely")
        var failing = SoundRateLimiter()
        t.expect(failing.admit(.failed, at: start))
        t.expect(!failing.admit(.failed, at: start.addingTimeInterval(19)))
        t.expect(failing.admit(.failed, at: start.addingTimeInterval(21)))
    }

    t.test("Rate limiter: while a sound is fresh only a more important one may cut in") {
        let start = Date(timeIntervalSince1970: 5_000)
        var limiter = SoundRateLimiter()
        t.expect(limiter.admit(.done, at: start))
        t.expect(!limiter.admit(.approved, at: start.addingTimeInterval(0.1)), "feedback does not talk over news")
        t.expect(!limiter.admit(.reminder, at: start.addingTimeInterval(0.2)), "equal importance waits")
        t.expect(limiter.admit(.needsApproval, at: start.addingTimeInterval(0.3)), "a call for attention cuts in")
        t.expect(!limiter.admit(.needsAnswer, at: start.addingTimeInterval(0.5)), "but not a second one right behind it")
        t.expect(limiter.admit(.needsAnswer, at: start.addingTimeInterval(1.0)), "once the gap has passed it plays")
        t.expect(SoundRateLimiter.priority(of: .needsApproval) > SoundRateLimiter.priority(of: .done))
        t.expect(SoundRateLimiter.priority(of: .done) > SoundRateLimiter.priority(of: .approved))
        t.expect(SoundRateLimiter.priority(of: .approved) > SoundRateLimiter.priority(of: .sessionStart))
    }

    t.test("Rate limiter: a burst of events cannot stack ten sounds") {
        let start = Date(timeIntervalSince1970: 5_000)
        var limiter = SoundRateLimiter()
        var played = 0
        for i in 0..<10 where limiter.admit(.done, at: start.addingTimeInterval(Double(i) * 0.1)) { played += 1 }
        t.expectEqual(played, 1, "ten 'done' events in a second make one sound")

        // Even well-spaced, varied events are capped inside the burst window.
        var varied = SoundRateLimiter()
        let cues: [SoundCue] = [.needsApproval, .needsAnswer, .done, .failed, .reminder, .approved, .denied, .sessionStart, .needsApproval, .done]
        var admitted: [SoundCue] = []
        for (i, cue) in cues.enumerated() where varied.admit(cue, at: start.addingTimeInterval(Double(i) * 0.7)) { admitted.append(cue) }
        t.expectEqual(admitted, [.needsApproval, .needsAnswer, .done, .failed], "at most four sounds in ten seconds")
        t.expect(!varied.admit(.reminder, at: start.addingTimeInterval(9.9)), "still inside the window")
        t.expect(varied.admit(.reminder, at: start.addingTimeInterval(10.1)), "the window slides on")
        // A clock that jumps backwards must not jam the limiter.
        t.expect(varied.admit(.denied, at: start.addingTimeInterval(-3_600)), "an earlier time is treated as a fresh start")
    }
}

// MARK: - SoundEngine

/// Remembers what would have been played. No audio is involved.
private final class RecordingOutput: SoundOutput {
    private(set) var played: [(source: SoundSource, gain: Float)] = []
    func play(_ source: SoundSource, gain: Float) { played.append((source, gain)) }
    var sources: [SoundSource] { played.map(\.source) }
}

private func runSoundEngineTests(_ t: TestRunner) {
    func setUp(at start: Date = hour(12)) -> (AppSettings, RecordingOutput, Guarded<Date>, SoundEngine) {
        let settings = makeSettings()
        let output = RecordingOutput()
        let clock = Guarded(start)
        return (settings, output, clock, SoundEngine(settings: settings, output: output, now: { clock.get() }))
    }

    t.test("SoundEngine: plays the cue from the chosen pack at the chosen volume") {
        let (settings, output, clock, engine) = setUp()
        engine.play(.done)
        t.expectEqual(output.sources, [.synthesized(pack: .chime, cue: .done)])
        t.expectEqual(output.played.first?.gain, 0.6)

        clock.set(clock.get().addingTimeInterval(5))
        settings.soundPack = .soft
        settings.volume = 0.1
        engine.play(.needsApproval)
        t.expectEqual(output.sources.last, .synthesized(pack: .soft, cue: .needsApproval))
        t.expect(abs((output.played.last?.gain ?? 0) - 0.04) < 0.0001, "quiet end of the slider is squared")

        clock.set(clock.get().addingTimeInterval(5))
        settings.soundPack = .system
        engine.play(.failed)
        t.expectEqual(output.sources.last, .system(name: "Basso", fallback: .failed))
        t.expectEqual(output.played.count, 3)
    }

    t.test("SoundEngine: play honours every mute; preview ignores them") {
        let (settings, output, clock, engine) = setUp()
        func step() { clock.set(clock.get().addingTimeInterval(30)) }

        engine.play(.sessionStart)
        t.expect(output.played.isEmpty, "session-start is off by default")
        settings.soundOnStart = true
        engine.play(.sessionStart)
        t.expectEqual(output.played.count, 1, "and plays once switched on")

        step(); settings.soundOnDone = false; engine.play(.done)
        step(); settings.soundOnApproval = false; engine.play(.needsApproval); engine.play(.approved); engine.play(.denied)
        step(); settings.soundOnQuestion = false; engine.play(.needsAnswer)
        step(); settings.soundOnError = false; engine.play(.failed)
        t.expectEqual(output.played.count, 1, "each per-event switch silences its cue")
        step(); engine.play(.reminder)
        t.expectEqual(output.sources.last, .synthesized(pack: .chime, cue: .reminder), "reminders have no switch here")

        step(); settings.soundsEnabled = false
        for cue in SoundCue.allCases { engine.play(cue) }
        t.expectEqual(output.played.count, 2, "the master switch silences everything")
        t.expectEqual(engine.handle(.reminder, preview: false), .skip(.soundsOff))

        for cue in SoundCue.allCases { engine.preview(cue) }
        t.expectEqual(output.played.count, 2 + SoundCue.allCases.count, "previews play regardless, even in quick succession")
        t.expectEqual(Array(output.sources.suffix(SoundCue.allCases.count)), SoundCue.allCases.map { .synthesized(pack: .chime, cue: $0) })

        settings.volume = 0
        engine.preview(.done)
        t.expectEqual(output.played.count, 2 + SoundCue.allCases.count, "a preview at volume zero stays silent")
        t.expectEqual(engine.handle(.done, preview: true), .skip(.volumeZero))
    }

    t.test("SoundEngine: quiet hours follow the clock") {
        let (settings, output, clock, engine) = setUp(at: hour(23))
        settings.quietHoursEnabled = true     // defaults: 22:00 to 08:00
        engine.play(.done)
        t.expect(output.played.isEmpty, "23:30 is quiet")
        t.expectEqual(engine.handle(.needsApproval, preview: false), .skip(.quietHours))
        engine.preview(.done)
        t.expectEqual(output.played.count, 1, "a preview still plays during quiet hours")
        clock.set(hour(12))
        engine.play(.done)
        t.expectEqual(output.played.count, 2, "12:30 is not quiet")
    }

    t.test("SoundEngine: a burst of events makes one sound, not ten") {
        let (_, output, clock, engine) = setUp()
        for _ in 0..<10 {
            engine.play(.needsApproval)
            clock.set(clock.get().addingTimeInterval(0.05))
        }
        t.expectEqual(output.played.count, 1)
        t.expectEqual(engine.handle(.needsApproval, preview: false), .skip(.tooSoon))
        clock.set(clock.get().addingTimeInterval(3))
        engine.play(.needsApproval)
        t.expectEqual(output.played.count, 2, "later it may sound again")
        // A muted cue must not use up the limiter's allowance.
        let (settings, quietOutput, _, quietEngine) = setUp()
        settings.soundsEnabled = false
        quietEngine.play(.done)
        settings.soundsEnabled = true
        quietEngine.play(.done)
        t.expectEqual(quietOutput.played.count, 1, "the skipped attempt did not count as a play")
    }

    t.test("SoundEngine: calls from another thread are moved to the main thread, and never block") {
        let (_, output, _, engine) = setUp()
        let finished = Guarded(false)
        DispatchQueue.global().async {
            engine.play(.done)
            engine.preview(.failed)
            finished.set(true)
        }
        t.expect(t.wait(2) { output.played.count == 2 }, "both sounds arrived")
        t.expect(finished.get(), "the background caller returned")
        t.expectEqual(output.sources, [.synthesized(pack: .chime, cue: .done), .synthesized(pack: .chime, cue: .failed)])
    }

    t.test("SoundEngine: the real engine can be created without touching the audio hardware") {
        let settings = makeSettings()
        settings.soundsEnabled = false
        let engine = SoundEngine(settings: settings)
        engine.play(.done)   // muted, so nothing reaches the speaker
        settings.volume = 0
        engine.preview(.done)   // volume zero, so nothing reaches the speaker either
        t.expectEqual(engine.handle(.done, preview: false), .skip(.soundsOff))
    }
}

// MARK: - SystemNotifier

private final class FakeNotificationService: NotificationService {
    var onClick: ((String?) -> Void)?
    var allowed = true
    var permissionRequests = 0
    var posted: [NotificationPayload] = []

    func ensurePermission(_ completion: @escaping (Bool) -> Void) {
        permissionRequests += 1
        completion(allowed)
    }

    func post(_ payload: NotificationPayload) { posted.append(payload) }
}

private func runNotifierTests(_ t: TestRunner) {
    t.test("Notifier: payloads are tidied to fit a banner") {
        let plain = NotificationPayload(title: "Claude needs you", body: "Run `npm test`?", sessionID: "claude:abc")
        t.expectEqual(plain.title, "Claude needs you")
        t.expectEqual(plain.body, "Run `npm test`?")
        t.expectEqual(plain.sessionID, "claude:abc")
        t.expectEqual(plain.identifier, "perch.session.claude:abc", "one banner per session: a newer one replaces the older")

        let messy = NotificationPayload(title: "  Line one\nline two  ", body: "\n  hello  \n", sessionID: "", unique: { "X1" })
        t.expectEqual(messy.title, "Line one line two", "titles are a single line")
        t.expectEqual(messy.body, "hello")
        t.expectNil(messy.sessionID, "an empty session id means none")
        t.expectEqual(messy.identifier, "perch.note.X1")

        let long = NotificationPayload(title: String(repeating: "t", count: 500), body: String(repeating: "b", count: 5_000), sessionID: nil)
        t.expectEqual(long.title.count, NotificationPayload.maxTitleLength)
        t.expectEqual(long.body.count, NotificationPayload.maxBodyLength)
        t.expect(long.title.hasSuffix("…") && long.body.hasSuffix("…"), "cut text ends with an ellipsis")
        t.expectEqual(NotificationPayload(title: " \n ", body: "", sessionID: nil).title, "Perch", "an empty title falls back to the app name")
        t.expect(NotificationPayload(title: "a", body: "b", sessionID: nil).identifier != NotificationPayload(title: "a", body: "b", sessionID: nil).identifier,
                 "notes without a session never replace each other")
    }

    t.test("Notifier: nothing happens while the setting is off — not even a permission request") {
        let settings = makeSettings()
        let service = FakeNotificationService()
        let notifier = SystemNotifier(settings: settings, service: service)
        t.expect(!settings.systemNotifications, "off by default")
        notifier.notify(title: "Done", body: "All tests pass", sessionID: "claude:abc")
        t.expectEqual(service.permissionRequests, 0)
        t.expect(service.posted.isEmpty)
        t.expect(!notifier.isAvailable)
    }

    t.test("Notifier: when on, permission is checked and the notification is posted") {
        let settings = makeSettings()
        settings.systemNotifications = true
        let service = FakeNotificationService()
        let notifier = SystemNotifier(settings: settings, service: service)
        t.expect(notifier.isAvailable)
        notifier.notify(title: "Done", body: "All tests pass", sessionID: "claude:abc")
        t.expectEqual(service.permissionRequests, 1)
        t.expectEqual(service.posted, [NotificationPayload(title: "Done", body: "All tests pass", sessionID: "claude:abc")])
        notifier.notify(title: "Again", body: "", sessionID: nil)
        t.expectEqual(service.posted.count, 2)
        t.expectNil(service.posted.last?.sessionID)

        settings.systemNotifications = false
        notifier.notify(title: "Off again", body: "", sessionID: nil)
        t.expectEqual(service.posted.count, 2, "turning the setting off takes effect at once")
    }

    t.test("Notifier: a refused permission is silent, and is asked about again next time") {
        let settings = makeSettings()
        settings.systemNotifications = true
        let service = FakeNotificationService()
        service.allowed = false
        let notifier = SystemNotifier(settings: settings, service: service)
        notifier.notify(title: "Done", body: "", sessionID: "claude:abc")
        t.expect(service.posted.isEmpty, "nothing is posted without permission")
        service.allowed = true     // the user allowed notifications in System Settings
        notifier.notify(title: "Done", body: "", sessionID: "claude:abc")
        t.expectEqual(service.posted.count, 1, "picked up without restarting")
        t.expectEqual(service.permissionRequests, 2)
    }

    t.test("Notifier: clicking a notification hands the session id back on the main thread") {
        let settings = makeSettings()
        let service = FakeNotificationService()
        let notifier = SystemNotifier(settings: settings, service: service)
        var opened: [String] = []
        var wasMainThread = false
        notifier.onOpenSession = { opened.append($0); wasMainThread = Thread.isMainThread }
        DispatchQueue.global().async { service.onClick?("claude:abc") }     // the system calls back on its own thread
        t.expect(t.wait(2) { !opened.isEmpty }, "the click arrived")
        t.expectEqual(opened, ["claude:abc"])
        t.expect(wasMainThread, "delivered on the main thread")
        service.onClick?(nil)
        service.onClick?("")
        t.wait(0.1) { false }
        t.expectEqual(opened.count, 1, "clicks on notifications without a session are ignored")
    }

    t.test("Notifier: from a background thread, and with no service at all") {
        let settings = makeSettings()
        settings.systemNotifications = true
        let service = FakeNotificationService()
        let notifier = SystemNotifier(settings: settings, service: service)
        DispatchQueue.global().async { notifier.notify(title: "From elsewhere", body: "", sessionID: nil) }
        t.expect(t.wait(2) { service.posted.count == 1 }, "moved to the main thread and posted")

        let unavailable = SystemNotifier(settings: settings, service: nil)
        unavailable.notify(title: "Nobody hears this", body: "", sessionID: "claude:abc")
        t.expect(!unavailable.isAvailable, "no service: quietly unavailable")
    }

    t.test("Notifier: the real notifier is safe outside an app bundle") {
        // UNUserNotificationCenter aborts the process without a bundle; the notifier must not touch it here.
        let settings = makeSettings()
        settings.systemNotifications = true
        let notifier = SystemNotifier(settings: settings)
        notifier.notify(title: "Unbundled", body: "This must not crash", sessionID: "claude:abc")
        t.expect(!notifier.isAvailable, "unavailable when unbundled, even with the setting on")
        t.expect(!AppBundle.isRealApp)
    }
}

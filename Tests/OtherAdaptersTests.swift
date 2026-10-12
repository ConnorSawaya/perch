// OtherAdaptersTests.swift — tests for the Codex, Antigravity and Gemini CLI adapters and their shared helpers.
//
// Run with:
//   scripts/test.sh OtherAdapters Sources/Core/Adapters/Codex Sources/Core/Adapters/Antigravity \
//       Sources/Core/Adapters/Gemini Sources/Core/Adapters/Shared
//
// None of the three agents is installed where these tests were written, so everything runs against
// the fixtures under Fixtures/ and against config files in temporary folders. Nothing here reads or
// writes ~/.codex or ~/.gemini.

import Foundation

func runOtherAdaptersTests(_ t: TestRunner) {
    runSharedHelperTests(t)
    runCodexTests(t)
    runGeminiTests(t)
    runAntigravityTests(t)
}

// MARK: - Helpers for the tests themselves

/// A throwaway folder layout: a fake home, a backups folder and a fake helper path.
private struct Sandbox {
    let root = TestRunner.tempDir("perch-others")
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    /// Contains a space on purpose, like the real "Application Support" path.
    var helper: String { root.appendingPathComponent("App Support/bin/perch-hook").path }

    init() { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }

    func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    var backupCount: Int { ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasSuffix(".bak") }.count }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func envelope(_ agent: String, payload: String = "", event: String? = nil, channel: String = "hook",
                      args: [String] = [], pid: Int32 = 4242, wantsReply: Bool = false) -> HookEnvelope {
    var e = HookEnvelope(agent: agent)
    e.channel = channel
    e.event = event
    e.payload = payload
    e.args = args
    e.pid = pid
    e.tty = "/dev/ttys004"
    e.cwd = "/tmp/helper-cwd"
    e.env = ["TERM_PROGRAM": "iTerm.app"]
    e.wantsReply = wantsReply
    e.sentAt = Date().timeIntervalSince1970
    return e
}

private func fixtureNames(_ folder: String, suffix: String = ".json") -> [String] {
    let url = TestRunner.fixture(folder)
    return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(suffix) }.sorted()
}

private func pendingRequest(_ agent: AgentKind, _ kind: RequestKind) -> PendingRequest {
    PendingRequest(sessionID: Session.makeID(agent, "s"), agent: agent, kind: kind, createdAt: Date(), raw: .null)
}

private let samplePermission = RequestKind.permission(PermissionRequest(toolName: "Bash", summary: "Run", detail: "ls"))

// MARK: - Shared helpers

private func runSharedHelperTests(_ t: TestRunner) {
    t.test("OrderedJSON keeps key order, numbers and unicode") {
        let text = "{\"zeta\": 1.50, \"alpha\": [true, null, \"a\\u00e9\\n\\ud83d\\ude00\"], \"m\": {\"y\": 1e3, \"x\": -2}}"
        let value = try OrderedJSON.parse(text)
        t.expectEqual(value.members?.map(\.key), ["zeta", "alpha", "m"])
        t.expectEqual(value["zeta"], .number("1.50"))
        t.expectEqual(value["alpha"]?.arrayValue?[2].stringValue, "aé\n😀")
        t.expectEqual(value["m"]?.members?.map(\.key), ["y", "x"])
        let printed = value.serialized()
        t.expect(printed.contains("\"zeta\": 1.50"), "number text is kept")
        t.expect(printed.contains("1e3"))
        t.expectEqual(try OrderedJSON.parse(printed), value, "round trip")
        t.expect(printed.hasSuffix("}\n"))
    }

    t.test("OrderedJSON editing replaces in place and appends new keys") {
        var value = try OrderedJSON.parse("{\"a\":1,\"b\":2,\"c\":3}")
        value["b"] = .string("two")
        value["d"] = .bool(true)
        t.expectEqual(value.members?.map(\.key), ["a", "b", "c", "d"])
        value["a"] = nil
        t.expectEqual(value.members?.map(\.key), ["b", "c", "d"])
        t.expectEqual(value.jsonValue["b"].stringValue, "two")
        t.expectEqual(OrderedJSON.object([]).serialized(), "{}\n")
        t.expectEqual(OrderedJSON.quote("a/b \"q\" \\ \u{01}"), "\"a/b \\\"q\\\" \\\\ \\u0001\"")
    }

    t.test("OrderedJSON rejects anything that is not strict JSON") {
        let bad = ["", "{", "{\"a\":1,}", "[1,2", "{\"a\" 1}", "// c\n{}", "{\"a\":1} x", "{'a':1}", "[01x]", "\"abc", "{\"a\":\"\\q\"}",
                   "[+1]", "[.5]", "[1.]", "nul", "{\"a\":\"\\ud83d\"}", String(repeating: "[", count: 500)]
        for text in bad {
            t.expect((try? OrderedJSON.parse(text)) == nil, "should not parse: \(text.prefix(20))")
        }
        t.expectEqual(try OrderedJSON.parse("\u{FEFF}{\"a\": []}")["a"], .array([]), "byte-order mark is allowed")
        t.expectEqual(try OrderedJSON.parse(" [ ] "), .array([]))
    }

    t.test("SafeConfigFile backs up, writes atomically and keeps permissions") {
        let box = Sandbox(); defer { box.cleanUp() }
        let file = box.home.appendingPathComponent("conf/settings.json")
        t.expectNil(try SafeConfigFile.read(file))
        t.expect(try SafeConfigFile.update(file, to: "one", label: "x", backupsDir: box.backups), "creates the file")
        t.expectEqual(box.backupCount, 0, "nothing to back up for a new file")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        t.expect(try SafeConfigFile.update(file, to: "two", label: "x", backupsDir: box.backups))
        t.expect(try SafeConfigFile.update(file, to: "three", label: "x", backupsDir: box.backups))
        t.expectEqual(box.backupCount, 2, "one backup per change, even within the same second")
        t.expectEqual(try SafeConfigFile.update(file, to: "three", label: "x", backupsDir: box.backups), false, "no change, no write")
        t.expectEqual(box.backupCount, 2)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        t.expectEqual(mode, 0o600, "permissions survive")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        t.expectEqual(leftovers, ["settings.json"], "no temporary files left behind")
        let backups = try FileManager.default.contentsOfDirectory(atPath: box.backups.path).sorted()
        t.expect(backups.allSatisfy { $0.hasPrefix("x-settings.json.") })
        t.expectEqual(Set(backups.map { box.read(box.backups.appendingPathComponent($0)) }), ["one", "two"])
    }

    t.test("SafeConfigFile writes through a symlink and refuses non-UTF-8") {
        let box = Sandbox(); defer { box.cleanUp() }
        let real = box.home.appendingPathComponent("dotfiles/hooks.json")
        let link = box.home.appendingPathComponent("hooks.json")
        box.write("old", to: real)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/hooks.json")
        try SafeConfigFile.update(link, to: "new", label: "x", backupsDir: box.backups)
        t.expectEqual(box.read(real), "new")
        t.expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "still a symlink")
        let binary = box.home.appendingPathComponent("binary")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        t.expect((try? SafeConfigFile.read(binary)) == nil, "non-UTF-8 is an error, not an empty file")
        SafeConfigFile.markCreatedByPerch(real, label: "x", backupsDir: box.backups)
        t.expect(SafeConfigFile.wasCreatedByPerch(real, label: "x", backupsDir: box.backups))
        t.expect(!SafeConfigFile.wasCreatedByPerch(link, label: "y", backupsDir: box.backups))
        SafeConfigFile.clearCreatedMark(real, label: "x", backupsDir: box.backups)
        t.expect(!SafeConfigFile.wasCreatedByPerch(real, label: "x", backupsDir: box.backups))
        t.expectEqual(ShellQuote.single("/a b/it's"), "'/a b/it'\\''s'")
    }

    t.test("JSONLinesTailer returns only complete new lines") {
        let box = Sandbox(); defer { box.cleanUp() }
        let file = box.home.appendingPathComponent("s.jsonl")
        box.write("{\"a\":1}\n{\"a\":2}\n", to: file)
        let fromStart = JSONLinesTailer(url: file, startAtEnd: false)
        t.expectEqual(fromStart.readNewLines(), ["{\"a\":1}", "{\"a\":2}"])
        t.expectEqual(fromStart.readNewLines(), [])
        let fromEnd = JSONLinesTailer(url: file, startAtEnd: true)
        t.expectEqual(fromEnd.readNewLines(), [])
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"a\":3}\n\n{\"a\":4".utf8))
        t.expectEqual(fromEnd.readNewLines(), ["{\"a\":3}"], "the unfinished line waits")
        handle.write(Data("4}\n".utf8))
        t.expectEqual(fromEnd.readNewLines(), ["{\"a\":44}"])
        t.expectEqual(fromStart.readNewLines(), ["{\"a\":3}", "{\"a\":44}"])
        try handle.close()
        box.write("{\"b\":1}\n", to: file)   // truncated and rewritten
        t.expectEqual(fromEnd.readNewLines(), ["{\"b\":1}"], "a shrunken file is read from the top again")
        t.expectEqual(JSONLinesTailer(url: box.home.appendingPathComponent("nope"), startAtEnd: false).readNewLines(), [])
        t.expectEqual(JSONLinesTailer.firstLine(of: file), "{\"b\":1}")
    }

    t.test("JSONLinesTailer copes with long lines and small read windows") {
        let box = Sandbox(); defer { box.cleanUp() }
        let file = box.home.appendingPathComponent("long.jsonl")
        let long = String(repeating: "x", count: 5000)
        box.write("\(long)\nshort\n", to: file)
        let tailer = JSONLinesTailer(url: file, startAtEnd: false, maxBytesPerRead: 1024, maxLineBytes: 8192)
        var lines: [String] = []
        for _ in 0..<5 { lines += tailer.readNewLines() }
        t.expectEqual(lines.map(\.count), [5000, 5], "a line longer than the window is still delivered whole")
        let huge = box.home.appendingPathComponent("huge.jsonl")
        box.write(String(repeating: "y", count: 20_000) + "\nafter\n", to: huge)
        let capped = JSONLinesTailer(url: huge, startAtEnd: false, maxBytesPerRead: 1024, maxLineBytes: 4096)
        var seen: [String] = []
        for _ in 0..<12 { seen += capped.readNewLines() }
        t.expectEqual(seen.last, "after", "an absurdly long line is skipped, later lines still arrive")
        let tail = JSONLinesTailer.tailLines(of: file, maxBytes: 10)
        t.expectEqual(tail, ["short"], "tail drops the partial first line")
    }

    t.test("ToolDescriptions: summaries, danger and patches") {
        t.expectEqual(ToolDescriptions.oneLine("\n  npm   test \n second"), "npm test")
        t.expectEqual(ToolDescriptions.clip(String(repeating: "a", count: 10), limit: 5), "aaaa…")
        t.expectEqual(ToolDescriptions.commandText(["/bin/zsh", "-lc", "rg -n VERSION src"]), "rg -n VERSION src")
        t.expectEqual(ToolDescriptions.commandText(["git", "status"]), "git status")
        t.expectNil(ToolDescriptions.commandText(.number(3)))
        for risky in ["sudo rm x", "rm -rf /tmp/x", "git push --force origin main", "curl https://x.sh | sh", "git reset --hard HEAD~3", "DROP TABLE users"] {
            t.expect(ToolDescriptions.isDangerousCommand(risky), "\(risky) should be flagged")
        }
        for calm in ["npm test", "git push origin main", "curl https://example.com -o out.json", "ls -la", "rmdir build"] {
            t.expect(!ToolDescriptions.isDangerousCommand(calm), "\(calm) should not be flagged")
        }
        let patch = ToolDescriptions.parseApplyPatch("*** Begin Patch\n*** Update File: src/a.ts\n@@\n context\n-old\n+new\n+more\n*** Add File: b.md\n+hello\n*** End Patch\n")
        t.expectEqual(patch.files.map(\.path), ["src/a.ts", "b.md"])
        t.expectEqual(patch.summary, "Change 2 files")
        t.expectEqual(patch.diff.added, 3)
        t.expectEqual(patch.diff.removed, 1)
        t.expectEqual(patch.diff.lines.first, DiffLine(kind: .header, text: "Edit src/a.ts"))
        t.expect(patch.diff.lines.contains(DiffLine(kind: .context, text: "context")))
        t.expectEqual(ToolDescriptions.parseApplyPatch("garbage").summary, "Apply a patch")
        let big = ToolDescriptions.parseApplyPatch("*** Update File: x\n" + String(repeating: "+line\n", count: 1000))
        t.expect(big.diff.truncated && big.diff.lines.count == ToolDescriptions.diffLineLimit && big.diff.added == 1000)
        let unified = ToolDescriptions.parseUnifiedDiff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n", filePath: "/x")
        t.expectEqual([unified.added, unified.removed], [1, 1])
        t.expectEqual(ToolDescriptions.splitMCPToolName("mcp__github__create_issue")?.tool, "create_issue")
        t.expectNil(ToolDescriptions.splitMCPToolName("Bash")?.tool)
        t.expectEqual(EnvelopeReading.expandTilde("~/x/y", home: URL(fileURLWithPath: "/Users/alex")), "/Users/alex/x/y")
    }

    runTOMLTests(t)
}

private func runTOMLTests(_ t: TestRunner) {
    let sample = """
    # Codex config
    model = "gpt-5.2-codex"   # trailing comment
    approvals_reviewer = 'auto_review'
    notes = \"\"\"
    [not.a.table]
    key = "inside a string"
    \"\"\"
    list = [
      "a", # comment with ] bracket
      "b#not a comment",
    ]

    [features]
    hooks = false
    web.search = true

    [hooks.state."/Users/alex/.codex/hooks.json:permission_request:0:0"]
    trusted_hash = "sha256:00"

    [[hooks.Stop]]
    matcher = "*"
    """ + "\n"

    t.test("TOML reader finds keys, tables and multi-line values") {
        let toml = TOMLSnippetEditor(text: sample)
        t.expect(toml.isFullyUnderstood)
        t.expectEqual(toml.text, sample, "text round-trips byte for byte")
        t.expectEqual(toml.string(at: ["model"]), "gpt-5.2-codex")
        t.expectEqual(toml.string(at: ["approvals_reviewer"]), "auto_review")
        t.expectEqual(toml.bool(at: ["features", "hooks"]), false)
        t.expectEqual(toml.bool(at: ["features", "web", "search"]), true, "dotted keys")
        t.expectNil(toml.rawValue(at: ["not", "a", "table", "key"]), "text inside a multi-line string is not config")
        t.expectNil(toml.rawValue(at: ["key"]))
        t.expectEqual(toml.stringArray(at: ["list"]), ["a", "b#not a comment"])
        t.expectEqual(toml.tables.map(\.path).first, ["features"])
        t.expectEqual(toml.tables.last?.isArrayOfTables, true)
        let state = toml.tablePaths(under: ["hooks", "state"])
        t.expectEqual(state.count, 1)
        t.expectEqual(state.first?.last, "/Users/alex/.codex/hooks.json:permission_request:0:0")
        t.expectEqual(toml.string(at: (state.first ?? []) + ["trusted_hash"]), "sha256:00")
        t.expectEqual(toml.tablePaths(under: ["features"]), [["features", "web"]])
    }

    t.test("TOML editor adds, replaces and removes one top-level key without touching the rest") {
        var toml = TOMLSnippetEditor(text: sample)
        try toml.setTopLevel(key: "notify", rawValue: TOMLSnippetEditor.quoteArray(["/a b/perch-hook", "--x"]))
        t.expectEqual(toml.stringArray(at: ["notify"]), ["/a b/perch-hook", "--x"])
        let lines = toml.text.components(separatedBy: "\n")
        t.expectEqual(lines.firstIndex(of: "notify = [\"/a b/perch-hook\", \"--x\"]"), 11, "inserted after the last top-level key, before the first table")
        t.expectNil(toml.rawValue(at: ["features", "notify"]), "not swallowed by a table")
        t.expectEqual(toml.text.replacingOccurrences(of: "notify = [\"/a b/perch-hook\", \"--x\"]\n", with: ""), sample, "only one line was added")
        try toml.setTopLevel(key: "notify", rawValue: "[]")
        t.expectEqual(toml.stringArray(at: ["notify"]), [])
        t.expect(try toml.removeTopLevel(key: "notify"))
        t.expectEqual(toml.text, sample, "install + uninstall is byte-for-byte neutral")
        t.expectEqual(try toml.removeTopLevel(key: "notify"), false)
        try toml.setTopLevel(key: "list", rawValue: "[\"z\"]")
        t.expectEqual(toml.stringArray(at: ["list"]), ["z"], "a multi-line value is replaced as a whole")
        t.expect(!toml.text.contains("\"b#not a comment\""))
        t.expectEqual(toml.bool(at: ["features", "hooks"]), false, "later tables are untouched")
    }

    t.test("TOML editor edge cases") {
        var empty = TOMLSnippetEditor(text: "")
        try empty.setTopLevel(key: "notify", rawValue: "[\"x\"]")
        t.expectEqual(empty.text, "notify = [\"x\"]\n")
        try empty.removeTopLevel(key: "notify")
        t.expectEqual(empty.text, "")

        var noNewline = TOMLSnippetEditor(text: "a = 1")
        try noNewline.setTopLevel(key: "b", rawValue: "2")
        t.expectEqual(noNewline.text, "a = 1\nb = 2")
        try noNewline.removeTopLevel(key: "b")
        t.expectEqual(noNewline.text, "a = 1", "the missing final newline is restored")

        var tablesOnly = TOMLSnippetEditor(text: "# top comment\n\n# about features\n[features]\nhooks = true\n")
        try tablesOnly.setTopLevel(key: "notify", rawValue: "[]")
        t.expectEqual(tablesOnly.text, "# top comment\nnotify = []\n\n# about features\n[features]\nhooks = true\n")
        t.expectEqual(tablesOnly.bool(at: ["features", "hooks"]), true)

        var crlf = TOMLSnippetEditor(text: "a = 1\r\n[t]\r\nb = 2\r\n")
        try crlf.setTopLevel(key: "n", rawValue: "3")
        t.expectEqual(crlf.text, "a = 1\r\nn = 3\r\n[t]\r\nb = 2\r\n", "Windows line endings are kept")

        var commentHeader = TOMLSnippetEditor(text: "[features] # switches\nhooks = false # off\n")
        t.expectEqual(commentHeader.bool(at: ["features", "hooks"]), false)
        t.expect(commentHeader.isFullyUnderstood)
        try commentHeader.setTopLevel(key: "x", rawValue: "1")
        t.expectEqual(commentHeader.text, "x = 1\n[features] # switches\nhooks = false # off\n")

        for broken in ["a = \"unterminated\n[features]\nhooks = false\n", "just words\n", "a =\nb = 1\n", "[bad header\n", "a = [1, 2\n", "a = 1 ]\n"] {
            var toml = TOMLSnippetEditor(text: broken)
            t.expect(!toml.isFullyUnderstood, "should be flagged: \(broken.prefix(16))")
            t.expect((try? toml.setTopLevel(key: "notify", rawValue: "[]")) == nil, "edits are refused")
            t.expectEqual(toml.text, broken, "and the text is untouched")
        }
        var asTable = TOMLSnippetEditor(text: "[notify]\nx = 1\n")
        t.expect((try? asTable.setTopLevel(key: "notify", rawValue: "[]")) == nil, "a key that is a table is not edited")
        var dotted = TOMLSnippetEditor(text: "notify.x = 1\n")
        t.expect((try? dotted.removeTopLevel(key: "notify")) == nil)

        t.expectEqual(TOMLSnippetEditor.parseKeyPath("a.\"b.c\".'d e'"), ["a", "b.c", "d e"])
        t.expectNil(TOMLSnippetEditor.parseKeyPath("a..b"))
        t.expectNil(TOMLSnippetEditor.parseKeyPath("a b"))
        t.expectEqual(TOMLSnippetEditor.unquote("\"a\\\"b\\\\c\""), "a\"b\\c")
        t.expectEqual(TOMLSnippetEditor.unquote("'C:\\dir'"), "C:\\dir")
        t.expectNil(TOMLSnippetEditor.unquote("42"))
        t.expectNil(TOMLSnippetEditor.parseStringArray("[1, 2]"))
        t.expectEqual(TOMLSnippetEditor.parseStringArray(TOMLSnippetEditor.quoteArray(["a, b", "c\"d", "e\\f"])), ["a, b", "c\"d", "e\\f"])
    }
}

// MARK: - Codex

private func codexAdapter(_ box: Sandbox, detected: Bool = true) -> (CodexAdapter, URL) {
    let home = box.home.appendingPathComponent(".codex", isDirectory: true)
    if detected { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    var tuning = SessionFileWatcher.Tuning()
    tuning.interval = 0.05
    return (CodexAdapter(codexHome: home, helperPath: box.helper, backupsDir: box.backups, watcherTuning: tuning), home)
}

private func runCodexTests(_ t: TestRunner) {
    let adapter = CodexAdapter(codexHome: URL(fileURLWithPath: "/nonexistent/perch-test/.codex"), helperPath: "/x/perch-hook",
                               backupsDir: URL(fileURLWithPath: "/nonexistent/perch-test/backups"))
    func normalize(_ fixture: String, wantsReply: Bool = false) -> [NormalizedEvent] {
        adapter.normalize(envelope("codex", payload: TestRunner.fixtureText("codex/hooks/\(fixture)"), wantsReply: wantsReply))
    }
    let sessionID = "019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10"

    t.test("Codex: every hook fixture normalizes to the right session") {
        let names = fixtureNames("codex/hooks")
        t.expectEqual(names.count, 23, "all fixtures found")
        for name in names {
            let events = normalize(name)
            t.expectEqual(events.count, 1, "\(name) gives one event")
            t.expectEqual(events.first?.sessionID, sessionID, name)
            t.expectEqual(events.first?.agent, .codex, name)
            t.expectEqual(events.first?.rawEventName, String(name.prefix(while: { $0 != "." })), name)
            t.expectEqual(events.first?.context.cwd, "/Users/alex/code/acme-api", name)
            t.expectEqual(events.first?.context.pid, 4242, name)
        }
    }

    t.test("Codex: lifecycle events") {
        t.expectEqual(normalize("SessionStart.startup.json").first?.event, .sessionStarted(title: nil, model: "gpt-5.2-codex", source: "startup"))
        t.expectEqual(normalize("SessionStart.resume.json").first?.event, .sessionStarted(title: nil, model: "gpt-5.2-codex", source: "resume"))
        guard case .promptSubmitted(let prompt)? = normalize("UserPromptSubmit.json").first?.event else { return t.expect(false, "prompt") }
        t.expect(prompt.hasPrefix("Bump the API version"))
        t.expectEqual(normalize("Stop.json").first?.event,
                      .turnFinished(lastMessage: "Bumped VERSION to 1.4.2 in src/routes/health.ts and the health check test passes.", backgroundWork: false))
        t.expectEqual(normalize("Interrupt.json").first?.event, .turnFailed(error: "Interrupted"))
        t.expectEqual(normalize("SessionEnd.json").first?.event, .sessionEnded(reason: "other"))
        t.expectEqual(normalize("SubagentStart.json").first?.event, .subagentStarted(id: "019a9d1f-0b44-7e51-a2c7-9d3e6f1b8c20", type: "explorer"))
        t.expectEqual(normalize("SubagentStop.json").first?.event, .subagentStopped(id: "019a9d1f-0b44-7e51-a2c7-9d3e6f1b8c20"))
        t.expectEqual(normalize("PreCompact.json").first?.event, .compactionStarted)
        t.expectEqual(normalize("PostCompact.json").first?.event, .compactionFinished)
        t.expect(normalize("Stop.json").first?.context.transcriptPath?.hasSuffix(".jsonl") == true)
        t.expectEqual(normalize("Stop.json").first?.raw, .null, "only blocking requests keep the raw payload")
    }

    t.test("Codex: tool events have readable summaries") {
        guard case .toolStarted(let bash)? = normalize("PreToolUse.Bash.json").first?.event else { return t.expect(false, "bash") }
        t.expectEqual(bash.name, "Bash")
        t.expectEqual(bash.summary, "rg -n \"VERSION\" src")
        t.expectEqual(bash.id, "call_Q2x1c3RlckJhc2gwMDAx")
        guard case .toolStarted(let patch)? = normalize("PreToolUse.apply_patch.json").first?.event else { return t.expect(false, "patch") }
        t.expectEqual(patch.summary, "Edit health.ts")
        guard case .toolStarted(let mcp)? = normalize("PreToolUse.mcp.json").first?.event else { return t.expect(false, "mcp") }
        t.expectEqual(mcp.summary, "github · create_issue: Bump API version to 1.4.2")
        guard case .toolStarted(let plan)? = normalize("PreToolUse.update_plan.json").first?.event else { return t.expect(false, "plan") }
        t.expectEqual(plan.summary, "Plan: 1 of 3 done · Update it to 1.4.2")
        t.expectEqual(normalize("PostToolUse.Bash.json").first?.event, .toolFinished(id: "call_Q2x1c3RlckJhc2gwMDAx", name: "Bash", succeeded: true))
        guard case .toolFinished(_, let name, let ok)? = normalize("PostToolUse.apply_patch.json").first?.event else { return t.expect(false, "post patch") }
        t.expectEqual(name, "apply_patch")
        t.expect(ok)
        t.expectEqual(CodexHookEvents.toolSucceeded(response: "Exit code: 2\nOutput:\nboom"), false)
        t.expectEqual(CodexHookEvents.toolSucceeded(response: ["output": "Exit code: 0"]), true)
        t.expectEqual(CodexHookEvents.toolSummary(name: "weird_tool", input: .null), "weird_tool")
    }

    t.test("Codex: a question is shown but is display-only") {
        let events = normalize("PreToolUse.request_user_input.json")
        guard case .questionAsked(let request)? = events.first?.event else { return t.expect(false, "question") }
        t.expectEqual(request.questions.count, 1)
        t.expectEqual(request.questions.first?.header, "Release scope")
        t.expectEqual(request.questions.first?.options.map(\.label), ["Yes (Recommended)", "No"])
        t.expectEqual(request.questions.first?.options.first?.detail, "Add a CHANGELOG.md entry for 1.4.2.")
        t.expectEqual(adapter.encode(.answer(["q": "Yes"]), for: pendingRequest(.codex, .question(request))), .passthrough,
                      "hooks cannot answer questions")
    }

    t.test("Codex: permission requests") {
        guard case .permissionRequested(let bash)? = normalize("PermissionRequest.Bash.json", wantsReply: true).first?.event else { return t.expect(false, "bash") }
        t.expectEqual(bash.toolName, "Bash")
        t.expectEqual(bash.detail, "npm test -- health")
        t.expect(bash.summary.hasPrefix("Run the health check test outside the sandbox"))
        t.expect(!bash.isDangerous && bash.suggestions.isEmpty, "Codex offers no always-allow rules")
        guard case .permissionRequested(let plain)? = normalize("PermissionRequest.Bash.no-description.json").first?.event else { return t.expect(false, "plain") }
        t.expectEqual(plain.summary, "Run a shell command")
        guard case .permissionRequested(let network)? = normalize("PermissionRequest.network.json").first?.event else { return t.expect(false, "network") }
        t.expectEqual(network.summary, "Allow network access to registry.npmjs.org:443")
        t.expectEqual(network.detail, "npm install")
        guard case .permissionRequested(let patch)? = normalize("PermissionRequest.apply_patch.json").first?.event else { return t.expect(false, "patch") }
        t.expectEqual(patch.detail, "src/routes/health.ts")
        t.expectEqual([patch.diff?.added, patch.diff?.removed], [1, 1])
        t.expectEqual(patch.diff?.filePath, "src/routes/health.ts")
        guard case .permissionRequested(let mcp)? = normalize("PermissionRequest.mcp.json").first?.event else { return t.expect(false, "mcp") }
        t.expect(mcp.summary.hasPrefix("Use ") && mcp.toolName.hasPrefix("mcp__"))
        t.expect(normalize("PermissionRequest.subagent.json").first?.sessionID == sessionID, "subagent requests land on the parent session")
        t.expect(normalize("PermissionRequest.Bash.json").first?.raw.objectValue != nil, "the request keeps its raw payload")
        let danger = CodexHookEvents.permissionRequest(toolName: "Bash", input: ["command": "sudo rm -rf /"])
        t.expect(danger.isDangerous)
    }

    t.test("Codex: decisions match the documented output exactly") {
        let request = pendingRequest(.codex, samplePermission)
        let allow = adapter.encode(.allow, for: request)
        t.expectEqual(JSONValue.parse(allow.stdout), JSONValue.parse(TestRunner.fixtureText("codex/decisions/PermissionRequest.allow.stdout.json")))
        t.expectEqual(allow.exitCode, 0)
        t.expect(!allow.stdout.contains("\n"), "one line")
        let deny = adapter.encode(.deny(message: "Denied from Perch: do not push from this machine."), for: request)
        t.expectEqual(JSONValue.parse(deny.stdout), JSONValue.parse(TestRunner.fixtureText("codex/decisions/PermissionRequest.deny.stdout.json")))
        let silentDeny = JSONValue.parse(adapter.encode(.deny(message: "  "), for: request).stdout)
        t.expectEqual(silentDeny?["hookSpecificOutput"]["decision"], ["behavior": "deny"], "no empty message key")
        t.expectEqual(JSONValue.parse(adapter.encode(.allowAlways(suggestionID: 0), for: request).stdout), JSONValue.parse(allow.stdout),
                      "no always-allow in Codex: allow once")
        t.expectEqual(adapter.encode(.passToTerminal, for: request), .passthrough)
        t.expectEqual(adapter.encode(.passToTerminal, for: request).stdout, TestRunner.fixtureText("codex/decisions/PermissionRequest.no-decision.stdout.txt"))
        t.expectEqual(adapter.encode(.approvePlan(acceptEdits: true), for: request), .passthrough)
        t.expectEqual(adapter.encode(.rejectPlan(feedback: "x"), for: request), .passthrough)
        t.expectEqual(adapter.encode(.allow, for: pendingRequest(.codex, .plan(PlanRequest(markdown: "p", filePath: nil)))), .passthrough)
        // Only keys Codex's strict parser accepts.
        t.expectEqual(JSONValue.parse(allow.stdout)?.objectValue?.keys.sorted(), ["hookSpecificOutput"])
    }

    t.test("Codex: notify channel and malformed input") {
        let json = TestRunner.fixtureText("codex/notify/agent-turn-complete.json")
        let events = adapter.normalize(envelope("codex", channel: "notify", args: [json]))
        t.expectEqual(events.first?.sessionID, "b5f6c1c2-1111-2222-3333-444455556666")
        t.expectEqual(events.first?.event, .turnFinished(lastMessage: "Rename complete and verified `cargo build` succeeds.", backgroundWork: false))
        t.expectEqual(events.first?.context.cwd, "/Users/example/project")
        t.expectEqual(adapter.normalize(envelope("codex", channel: "notify", args: ["not json"])), [])
        t.expectEqual(adapter.normalize(envelope("codex", channel: "notify", args: ["{\"type\":\"other\"}"])), [])
        for bad in ["", "not json", "[]", "null", "{}", "{\"hook_event_name\":\"Stop\"}", "{\"session_id\":\"\",\"hook_event_name\":\"Stop\"}",
                    "{\"session_id\":\"s\"}", "{\"session_id\":\"s\",\"hook_event_name\":\"FutureEvent\"}",
                    "{\"session_id\":5,\"hook_event_name\":\"Stop\"}", "{\"session_id\":\"s\",\"hook_event_name\":\"UserPromptSubmit\"}"] {
            t.expectEqual(adapter.normalize(envelope("codex", payload: bad)), [], "ignored: \(bad.prefix(30))")
        }
        // Wrong types everywhere must not crash and should still give something sensible.
        let odd = adapter.normalize(envelope("codex", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":7,\"tool_input\":[1],\"cwd\":null}"))
        guard case .toolStarted(let call)? = odd.first?.event else { return t.expect(false, "odd payload") }
        t.expectEqual(call.name, "tool")
        t.expectEqual(odd.first?.context.cwd, "/tmp/helper-cwd", "falls back to the helper's folder")
        let oddPermission = adapter.normalize(envelope("codex", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"PermissionRequest\"}"))
        t.expectEqual(oddPermission.count, 1)
        let subagentPrompt = "{\"session_id\":\"s\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"inner\",\"agent_id\":\"a\"}"
        t.expectEqual(adapter.normalize(envelope("codex", payload: subagentPrompt)), [], "a subagent's prompt is not the user's prompt")
        let compact = "{\"session_id\":\"s\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"model\":\"m\"}"
        t.expectEqual(adapter.normalize(envelope("codex", payload: compact)).first?.event,
                      .metadata(title: nil, model: "m", gitBranch: nil, permissionMode: nil), "compaction is not a new session")
    }

    runCodexInstallTests(t)
    runCodexRolloutTests(t)
}

private func runCodexInstallTests(_ t: TestRunner) {
    t.test("Codex: status when not installed anywhere") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box, detected: false)
        let status = adapter.status()
        t.expect(!status.detected)
        t.expectEqual(status.hookStatus, .notDetected)
        t.expectNil(status.version)
        t.expect((try? adapter.installHooks()) == nil, "install refuses when Codex is not there")
        t.expect(!box.exists(home), "and creates nothing")
        t.expectEqual(adapter.capabilities, AgentCapabilities(liveEvents: true, approvals: true, questions: false, planReview: false, usage: true, jump: true))
    }

    t.test("Codex: install into an empty home, idempotent, exact uninstall") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let hooks = home.appendingPathComponent("hooks.json")
        t.expectEqual(adapter.status().hookStatus, .notInstalled)
        let summary = try adapter.installHooks()
        t.expect(summary.contains("Trust all and continue"), "tells the user about Codex's trust step")
        let written = try OrderedJSON.parse(box.read(hooks))
        t.expectEqual(written.members?.map(\.key), ["hooks"], "no extra top-level keys (Codex rejects them)")
        let events = written["hooks"]?.members ?? []
        t.expectEqual(events.count, 12)
        t.expectEqual(Set(events.map(\.key)), Set(fixtureNames("codex/hooks").map { String($0.prefix(while: { $0 != "." })) }),
                      "exactly the events the fixtures cover")
        for member in events {
            let handler = member.value.arrayValue?.first?["hooks"]?.arrayValue?.first
            let expected = "'\(box.helper)' --agent codex" + (member.key == "PermissionRequest" ? " --wait" : "")
            t.expectEqual(handler?["command"]?.stringValue, expected, member.key)
            t.expectEqual(handler?["type"]?.stringValue, "command")
            t.expectNil(member.value.arrayValue?.first?["matcher"], "no matcher: match everything")
        }
        let reference = try OrderedJSON.parse(TestRunner.fixtureText("codex/config/hooks.perch-only.json"))
        for member in reference["hooks"]?.members ?? [] {
            let wanted = member.value.arrayValue?.first?["hooks"]?.arrayValue?.first
            let got = written["hooks"]?[member.key]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            t.expectEqual(got?["timeout"], wanted?["timeout"], "timeout for \(member.key) matches the research fixture")
            t.expectEqual(got?["statusMessage"], wanted?["statusMessage"], "status message for \(member.key)")
        }
        t.expectEqual(adapter.status().hookStatus, .installed)
        t.expect(adapter.status().detail.contains("Trust all and continue"), "no trust record yet")
        let first = box.read(hooks)
        t.expect(try adapter.installHooks().contains("already installed"))
        t.expectEqual(box.read(hooks), first, "second install changes nothing")
        t.expectEqual(box.backupCount, 0)
        _ = try adapter.uninstallHooks()
        t.expect(!box.exists(hooks), "a file Perch created is removed again")
        t.expectEqual(box.backupCount, 1, "with a backup")
        t.expectEqual(adapter.status().hookStatus, .notInstalled)
        t.expect(try adapter.uninstallHooks().contains("Nothing was changed"))
    }

    t.test("Codex: merge next to the user's own hooks, preserving order") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let hooks = home.appendingPathComponent("hooks.json")
        let original = """
        {
          "description": "User's own hooks",
          "hooks": {
            "PreToolUse": [
              { "matcher": "^Bash$", "hooks": [ { "type": "command", "command": "/usr/local/bin/audit --pre", "timeout": 3, "custom": {"z": 1, "a": 2} } ] }
            ],
            "Stop": [],
            "Zzz": [ { "hooks": [ { "type": "command", "command": "true" } ] } ]
          }
        }
        """
        box.write(original, to: hooks)
        _ = try adapter.installHooks()
        let merged = try OrderedJSON.parse(box.read(hooks))
        t.expectEqual(merged.members?.map(\.key), ["description", "hooks"])
        t.expectEqual(merged["description"]?.stringValue, "User's own hooks")
        let pre = merged["hooks"]?["PreToolUse"]?.arrayValue ?? []
        t.expectEqual(pre.count, 2, "Perch's group is appended")
        t.expectEqual(pre.first, try OrderedJSON.parse(original)["hooks"]?["PreToolUse"]?.arrayValue?.first, "the user's group is untouched and still first")
        t.expectEqual(pre.first?["hooks"]?.arrayValue?.first?["custom"]?.members?.map(\.key), ["z", "a"], "unknown fields keep their order")
        t.expectEqual(Array((merged["hooks"]?.members?.map(\.key) ?? []).prefix(3)), ["PreToolUse", "Stop", "Zzz"], "existing events keep their position")
        t.expectEqual(merged["hooks"]?["Stop"]?.arrayValue?.count, 1)
        t.expectEqual(box.backupCount, 1)
        t.expectEqual(adapter.status().hookStatus, .installed)

        // The user adds a hook after ours, then Perch is uninstalled.
        var edited = merged
        var stop = edited["hooks"]?["Stop"]?.arrayValue ?? []
        stop.append(try OrderedJSON.parse("{\"hooks\":[{\"type\":\"command\",\"command\":\"say done\"}]}"))
        var hooksObject = edited["hooks"] ?? .object([])
        hooksObject["Stop"] = .array(stop)
        edited["hooks"] = hooksObject
        box.write(edited.serialized(), to: hooks)
        let summary = try adapter.uninstallHooks()
        t.expect(summary.contains("review them again"), "warns that the user's later hooks moved")
        let after = try OrderedJSON.parse(box.read(hooks))
        t.expectEqual(after["hooks"]?["PreToolUse"], try OrderedJSON.parse(original)["hooks"]?["PreToolUse"])
        t.expectEqual(after["hooks"]?["Stop"]?.arrayValue?.count, 1)
        t.expectEqual(after["hooks"]?["Zzz"], try OrderedJSON.parse(original)["hooks"]?["Zzz"])
        t.expectEqual(after["hooks"]?.members?.map(\.key), ["PreToolUse", "Stop", "Zzz"], "events Perch added are gone")
        t.expect(!box.read(hooks).contains("perch-hook"))
        t.expectEqual(after["description"]?.stringValue, "User's own hooks")
    }

    t.test("Codex: the research's merged fixture is recognised and cleanly uninstalled") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let hooks = home.appendingPathComponent("hooks.json")
        box.write(TestRunner.fixtureText("codex/config/hooks.merged-with-user-hooks.json"), to: hooks)
        t.expectEqual(adapter.status().hookStatus, .needsUpdate, "entries from another Perch path count as stale")
        _ = try adapter.installHooks()
        t.expectEqual(adapter.status().hookStatus, .installed)
        let repaired = try OrderedJSON.parse(box.read(hooks))
        let pre = repaired["hooks"]?["PreToolUse"]?.arrayValue ?? []
        t.expectEqual(pre.count, 2, "repaired in place, not duplicated")
        t.expectEqual(pre.first?["matcher"]?.stringValue, "^Bash$", "the user's group keeps index 0 (and so its trust)")
        t.expect(!box.read(hooks).contains("/Users/alex/Library/Application Support/Perch"), "old helper path replaced")
        _ = try adapter.uninstallHooks()
        let after = try OrderedJSON.parse(box.read(hooks))
        t.expect(!box.read(hooks).contains("perch-hook"))
        t.expectEqual(after["hooks"]?["PreToolUse"]?.arrayValue?.count, 1)
        t.expect(after["description"] != nil)
    }

    t.test("Codex: files Perch cannot edit safely are left alone") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let hooks = home.appendingPathComponent("hooks.json")
        for broken in ["{ not json", "[]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}", "// comment\n{\"hooks\":{}}"] {
            box.write(broken, to: hooks)
            do {
                _ = try adapter.installHooks()
                t.expect(false, "install should throw for \(broken)")
            } catch {
                t.expect(!((error as? LocalizedError)?.errorDescription ?? "").isEmpty, "error has a readable message")
            }
            t.expectEqual(box.read(hooks), broken, "file untouched")
        }
        box.write("{ not json", to: hooks)
        t.expectEqual(adapter.status().hookStatus, .error)
        t.expect((try? adapter.uninstallHooks()) == nil, "uninstall also refuses")
        t.expectEqual(box.backupCount, 0)
    }

    t.test("Codex: status reads trust and feature flags from config.toml") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        _ = try adapter.installHooks()
        let config = home.appendingPathComponent("config.toml")
        box.write("[features]\nhooks = false\n", to: config)
        t.expect(adapter.status().detail.contains("switched off"))
        box.write("[features]\ncodex_hooks = false\n", to: config)
        t.expect(adapter.status().detail.contains("switched off"), "old flag name too")
        // Codex records trust under a path it resolved itself; only the ending is compared.
        box.write("model = \"x\"\n\n[hooks.state.\"/private/resolved/.codex/hooks.json:permission_request:0:0\"]\ntrusted_hash = \"sha256:00\"\n", to: config)
        t.expect(adapter.status().detail.hasPrefix("Sessions, usage and Allow / Deny"), "trusted")
        t.expect(adapter.status().detail.contains("answered in the terminal"), "honest about questions and plans")
        box.write("[hooks.state.\"/x/hooks.json:permission_request:0:0\"]\nenabled = false\ntrusted_hash = \"sha256:00\"\n", to: config)
        t.expect(adapter.status().detail.contains("Trust all and continue"), "a disabled hook is not counted as working")
        t.expectEqual(CodexConfig(configFile: config).trust(forKeySuffixes: ["hooks.json:permission_request:0:0"]),
                      CodexConfig.TrustSummary(trusted: 0, disabled: 1))
        let example = CodexConfig(configFile: TestRunner.fixture("codex/config/config.hooks-state.example.toml"))
        t.expectEqual(example.trust(forKeySuffixes: ["hooks.json:permission_request:0:0", "hooks.json:stop:1:0", "hooks.json:nope:9:9"]),
                      CodexConfig.TrustSummary(trusted: 1, disabled: 1))
        t.expectEqual(CodexHooksInstaller.snakeCase("PermissionRequest"), "permission_request")
        t.expectEqual(CodexHooksInstaller.snakeCase("Stop"), "stop")
        t.expectEqual(box.read(config).contains("perch"), false, "status never writes config.toml")
    }

    t.test("Codex: version comes from the newest session file, without running anything") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        t.expectNil(adapter.status().version)
        let paths = CodexPaths(home: home, binaryCandidates: [])
        let day = paths.recentSessionDirectories()[0]
        box.write(TestRunner.fixtureText("codex/rollout/rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"),
                  to: day.appendingPathComponent("rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"))
        box.write("zstd bytes", to: day.appendingPathComponent("rollout-2026-10-11T00-00-00-x.jsonl.zst"))
        t.expectEqual(adapter.status().version, "0.162.1")
        t.expectEqual(paths.recentRolloutFiles()?.count, 1, "compressed files are skipped")
        t.expectEqual(CodexPaths(home: box.home.appendingPathComponent("nope"), binaryCandidates: []).recentRolloutFiles() == nil, true)
        box.write("12345\n", to: paths.daemonPidFile)
        t.expectEqual(paths.daemonPid(), 12345)
    }

    t.test("Codex: optional notify program edits config.toml minimally") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let config = home.appendingPathComponent("config.toml")
        let original = "# my config\nmodel = \"gpt-5.2-codex\"  # keep\n\n[features]\nhooks = true\n"
        box.write(original, to: config)
        _ = try adapter.notifyInstaller.install()
        t.expect(adapter.notifyInstaller.isInstalled)
        let edited = box.read(config)
        t.expect(edited.hasPrefix("# my config\nmodel = \"gpt-5.2-codex\"  # keep\nnotify = ["), "added as a top-level key, comments kept")
        t.expect(edited.hasSuffix("\n\n[features]\nhooks = true\n"))
        t.expectEqual(TOMLSnippetEditor(text: edited).stringArray(at: ["notify"]), [box.helper, "--agent", "codex", "--channel", "notify", "--"])
        t.expect(try adapter.notifyInstaller.install().contains("already"))
        t.expectEqual(box.read(config), edited)
        _ = try adapter.uninstallHooks()   // removes everything Perch added, including notify
        t.expectEqual(box.read(config), original, "byte-for-byte back to the original")
        box.write("notify = [\"python3\", \"/me/notify.py\"]\n", to: config)
        t.expect((try? adapter.notifyInstaller.install()) == nil, "never replaces the user's notify program")
        t.expect(try adapter.notifyInstaller.uninstall().contains("Nothing was changed"))
        t.expectEqual(box.read(config), "notify = [\"python3\", \"/me/notify.py\"]\n")
        box.write("model = \"unterminated\n", to: config)
        t.expect((try? adapter.notifyInstaller.install()) == nil, "refuses a file it does not understand")
        t.expectEqual(box.read(config), "model = \"unterminated\n")
    }

    t.test("Codex: requests under automatic review are left to Codex") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let rollout = home.appendingPathComponent("sessions/r.jsonl")
        func permission() -> [NormalizedEvent] {
            adapter.normalize(envelope("codex", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"transcript_path\":\"\(rollout.path)\"}", wantsReply: true))
        }
        t.expectEqual(permission().count, 1, "no file, no config: Perch asks")
        box.write("{\"type\":\"turn_context\",\"payload\":{\"approvals_reviewer\":\"user\"}}\n{\"type\":\"turn_context\",\"payload\":{\"approvals_reviewer\":\"auto_review\"}}\n", to: rollout)
        t.expectEqual(permission(), [], "latest turn uses auto review")
        box.write("{\"type\":\"turn_context\",\"payload\":{\"approvals_reviewer\":\"guardian_subagent\"}}\n{\"type\":\"turn_context\",\"payload\":{\"approvals_reviewer\":\"user\"}}\n", to: rollout)
        t.expectEqual(permission().count, 1, "the latest turn wins")
        box.write("{\"type\":\"session_meta\",\"payload\":{}}\n", to: rollout)
        box.write("approvals_reviewer = \"auto_review\"\n", to: home.appendingPathComponent("config.toml"))
        t.expectEqual(permission(), [], "falls back to config.toml")
        // Other events are never suppressed.
        t.expectEqual(adapter.normalize(envelope("codex", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\"}")).count, 1)
    }

    t.test("Codex: hooks started by the shared background server carry no terminal facts") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        box.write("{\"pid\": 777}", to: home.appendingPathComponent("app-server-daemon/app-server.pid"))
        let payload = "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"cwd\":\"/p\"}"
        let viaDaemon = adapter.normalize(envelope("codex", payload: payload, pid: 777)).first
        t.expectNil(viaDaemon?.context.tty)
        t.expectNil(viaDaemon?.context.pid)
        t.expectEqual(viaDaemon?.context.env, [:])
        t.expectEqual(viaDaemon?.context.cwd, "/p")
        let direct = adapter.normalize(envelope("codex", payload: payload, pid: 778)).first
        t.expectEqual(direct?.context.tty, "/dev/ttys004")
        t.expectEqual(direct?.context.env["TERM_PROGRAM"], "iTerm.app")
    }
}

private func runCodexRolloutTests(_ t: TestRunner) {
    let name = "rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"
    let sessionID = "019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10"

    for (label, path) in [("paginated", "codex/rollout/\(name)"), ("legacy", "codex/rollout/legacy/\(name)")] {
        t.test("Codex rollout (\(label)): the whole fixture replays into a sensible story") {
            let lines = TestRunner.fixtureText(path).split(separator: "\n").map(String.init)
            let parser = CodexRolloutParser(fileURL: TestRunner.fixture(path))
            let out = parser.parse(lines: lines)
            let events = out.map(\.event.event)
            t.expect(out.allSatisfy { $0.event.sessionID == sessionID && $0.event.agent == .codex })
            t.expectEqual(parser.model, "gpt-5.2-codex")
            t.expectEqual(parser.approvalsReviewer, "user")
            t.expectEqual(parser.cwd, "/Users/alex/code/acme-api")
            guard case .sessionStarted(_, _, let source)? = events.first else { return t.expect(false, "starts with sessionStarted") }
            t.expectEqual(source, "startup")
            t.expectEqual(events.filter { if case .sessionStarted = $0 { return true } else { return false } }.count, 1)
            let prompts = events.compactMap { event -> String? in if case .promptSubmitted(let text) = event { return text } else { return nil } }
            t.expectEqual(prompts, ["Bump the API version to 1.4.2 and make sure the health check test still passes."],
                          "the injected environment block is not mistaken for a prompt")
            let tools = events.compactMap { event -> ToolCall? in if case .toolStarted(let call) = event { return call } else { return nil } }
            t.expectEqual(tools.map(\.name), ["Bash", "apply_patch"])
            t.expectEqual(tools.map(\.summary), ["rg -n \"VERSION\" src", "Edit health.ts"])
            let finished = events.compactMap { event -> String? in
                if case .toolFinished(let id, let name, let ok) = event { return "\(id ?? "-"):\(name):\(ok)" } else { return nil }
            }
            t.expectEqual(finished, ["call_Q2x1c3RlckJhc2gwMDAx:Bash:true", "call_Q2x1c3RlclBhdGNoMDAy:apply_patch:true"])
            t.expect(events.contains(.turnFinished(lastMessage: "Bumped VERSION to 1.4.2 in src/routes/health.ts and the health check test passes.", backgroundWork: false)))
            t.expectEqual(events.last, .turnFailed(error: "Interrupted"))
            t.expectEqual(out.last?.neededEvenWithHooks, false, "the Interrupt hook already reports a user interrupt")
            let usage = out.filter { if case .usageUpdated = $0.event.event { return true } else { return false } }
            t.expectEqual(usage.count, 3)
            t.expect(usage.allSatisfy(\.neededEvenWithHooks), "usage is always passed on")
            guard case .usageUpdated(let percent, let windows, let model, let cost)? = usage.last?.event.event else { return t.expect(false, "usage") }
            t.expectEqual(model, "gpt-5.2-codex")
            t.expectNil(cost)
            t.expect(abs((percent ?? 0) - 12813.0 / 272000.0 * 100) < 0.001, "context percent from the last response")
            t.expectEqual(windows.map(\.id), ["primary", "secondary"])
            t.expectEqual(windows.map(\.label), ["5-hour limit", "Weekly limit"])
            let lifecycle = out.filter { !$0.neededEvenWithHooks }.count
            t.expect(lifecycle >= 8, "prompts, tools and turn ends are marked as duplicates of hooks")
            t.expectEqual(out.first?.event.context.transcriptPath, TestRunner.fixture(path).path)
            t.expectNil(out.first?.event.context.pid)
        }
    }

    t.test("Codex rollout: rate-limit windows") {
        let lineDate = Date(timeIntervalSince1970: 1_000_000)
        let limits: JSONValue = ["limit_id": "codex", "primary": ["used_percent": 13.0, "window_minutes": 300, "resets_at": 2_000_000],
                                 "secondary": ["used_percent": 131.5, "window_minutes": 10080, "resets_at": 500]]
        let windows = CodexRolloutParser.rateWindows(from: limits, lineDate: lineDate, now: Date(timeIntervalSince1970: 1_500_000))
        t.expectEqual(windows.first, RateWindow(id: "primary", label: "5-hour limit", usedPercent: 13, resetsAt: Date(timeIntervalSince1970: 2_000_000)))
        t.expectEqual(windows.last, RateWindow(id: "secondary", label: "Weekly limit", usedPercent: 0, resetsAt: nil), "a window whose reset time passed shows as empty")
        let legacy: JSONValue = ["primary": ["used_percent": 50, "resets_in_seconds": 600]]
        t.expectEqual(CodexRolloutParser.rateWindows(from: legacy, lineDate: lineDate, now: lineDate).first?.resetsAt, lineDate.addingTimeInterval(600),
                      "old resets_in_seconds is accepted")
        let other: JSONValue = ["limit_id": "codex_other", "limit_name": "Spark", "primary": ["used_percent": 5, "window_minutes": 1440]]
        let extra = CodexRolloutParser.rateWindows(from: other, lineDate: lineDate, now: lineDate)
        t.expectEqual(extra.first?.id, "codex_other.primary")
        t.expectEqual(extra.first?.label, "Spark · 1-day limit")
        t.expectEqual(CodexRolloutParser.rateWindows(from: .null, lineDate: lineDate, now: lineDate), [])
        t.expectEqual(CodexRolloutParser.rateWindows(from: ["primary": .null, "secondary": ["window_minutes": 5]], lineDate: lineDate, now: lineDate), [])
        t.expectEqual(CodexRolloutParser.windowLabel(minutes: nil, slot: "primary"), "Short-term limit")
        t.expectEqual(CodexRolloutParser.windowLabel(minutes: 90, slot: "primary"), "1.5-hour limit")
        t.expectEqual(CodexRolloutParser.windowLabel(minutes: 30, slot: "primary"), "30-minute limit")
    }

    t.test("Codex rollout: errors, subagent threads and junk") {
        let parser = CodexRolloutParser(fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"))
        t.expectEqual(parser.parse(lines: ["{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}"]), [], "nothing before the session is known")
        var out = parser.parse(lines: [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"only-thread-id\",\"cwd\":\"/p\",\"git\":{\"branch\":\"main\"}}}",
            "garbage", "{\"type\":\"future_thing\",\"payload\":7}", "[1,2,3]", "{\"type\":\"event_msg\"}", "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"error\":{\"message\":\"usage limit reached\"}}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"reason\":\"budget_limited\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":null}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":[\\\"bash\\\",\\\"-lc\\\",\\\"make test\\\"]}\",\"call_id\":\"c1\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"Exit code: 1\\nOutput:\\nfail\"}}",
        ])
        t.expectEqual(out.first?.event.sessionID, "only-thread-id", "old files without session_id use the thread id")
        t.expect(out.contains { $0.event.event == .metadata(title: nil, model: nil, gitBranch: "main", permissionMode: nil) })
        let failures = out.filter { if case .turnFailed = $0.event.event { return true } else { return false } }
        t.expectEqual(failures.map(\.event.event), [.turnFailed(error: "usage limit reached"), .turnFailed(error: "Stopped: the usage budget was reached.")])
        t.expect(failures.allSatisfy(\.neededEvenWithHooks), "hooks have no event for these, so they always pass")
        t.expect(out.contains { $0.event.event == .toolFinished(id: "c1", name: "Bash", succeeded: false) }, "exit code 1 is a failure")
        t.expect(out.contains { if case .toolStarted(let call) = $0.event.event { return call.summary == "make test" } else { return false } })
        t.expect(!out.contains { if case .usageUpdated = $0.event.event { return true } else { return false } }, "empty token_count is skipped")

        let sub = CodexRolloutParser(fileURL: URL(fileURLWithPath: "/tmp/sub.jsonl"))
        out = sub.parse(lines: [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"child\",\"session_id\":\"root\",\"parent_thread_id\":\"root\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"inner task\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"done\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":5},\"last_token_usage\":{\"total_tokens\":5},\"model_context_window\":100}}}",
        ])
        t.expect(sub.isSubagentThread)
        t.expectEqual(out.count, 1, "a subagent's file adds usage to the parent, not prompts or turn ends")
        t.expectEqual(out.first?.event.sessionID, "root")
        t.expectEqual(out.first?.event.event, .usageUpdated(contextPercent: 5, windows: [], model: nil, costUSD: nil))
        t.expectEqual(sub.parse(lines: ["{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":5},\"last_token_usage\":{\"total_tokens\":5}}}}"]), [],
                      "a repeated identical record is not reported twice")
    }

    t.test("Codex monitoring: follows new session files, skips old content, and defers to hooks") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box)
        let paths = CodexPaths(home: home, binaryCandidates: [])
        let day = paths.recentSessionDirectories()[0]
        let fixtureLines = TestRunner.fixtureText("codex/rollout/\(name)").split(separator: "\n").map(String.init)

        // A session that finished long before Perch started, and one that is active right now.
        let stale = day.appendingPathComponent("rollout-2026-10-09T08-00-00-aaaa.jsonl")
        box.write(fixtureLines.joined(separator: "\n").replacingOccurrences(of: sessionID, with: "stale-session") + "\n", to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: stale.path)
        let ancient = day.appendingPathComponent("rollout-2026-10-01T08-00-00-bbbb.jsonl")
        box.write(fixtureLines.joined(separator: "\n").replacingOccurrences(of: sessionID, with: "ancient-session") + "\n", to: ancient)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: ancient.path)
        let live = day.appendingPathComponent("rollout-2026-10-12T08-00-00-cccc.jsonl")
        box.write(fixtureLines.prefix(10).joined(separator: "\n").replacingOccurrences(of: sessionID, with: "live-session") + "\n", to: live)
        box.write("{\"id\":\"live-session\",\"thread_name\":\"Bump API version\",\"updated_at\":\"2026-10-10T16:15:41Z\"}\n", to: paths.sessionIndexFile)

        var received: [NormalizedEvent] = []
        var emittedOffMain = false
        adapter.startMonitoring { events in
            if !Thread.isMainThread { emittedOffMain = true }
            received.append(contentsOf: events)
        }
        defer { adapter.stopMonitoring() }

        t.expect(t.wait(3) { received.contains { $0.sessionID == "live-session" } }, "the live session is announced")
        t.expect(!emittedOffMain, "events are delivered on the main thread")
        t.expectEqual(received.first?.event, .sessionStarted(title: "Bump API version", model: "gpt-5.2-codex", source: "resume"), "with the name Codex gave the thread")
        t.expect(received.contains { if case .usageUpdated(_, let windows, _, _) = $0.event { return windows.count == 2 } else { return false } },
                 "and its latest usage numbers")
        t.expect(!received.contains { if case .promptSubmitted = $0.event { return true } else { return false } }, "old content is not replayed")
        t.expect(!received.contains { $0.sessionID == "stale-session" || $0.sessionID == "ancient-session" }, "finished sessions get no card")

        // The live session continues.
        let before = received.count
        let handle = try FileHandle(forWritingTo: live)
        handle.seekToEndOfFile()
        handle.write(Data((fixtureLines[10...16].joined(separator: "\n").replacingOccurrences(of: sessionID, with: "live-session") + "\n").utf8))
        try handle.close()
        t.expect(t.wait(3) { received.contains { if case .turnFinished = $0.event { return true } else { return false } } }, "appended lines arrive")
        let added = received[before...].map(\.event)
        t.expect(added.contains { if case .toolStarted(let call) = $0 { return call.name == "apply_patch" } else { return false } })
        t.expectEqual(added.filter { if case .sessionStarted = $0 { return true } else { return false } }.count, 0, "announced only once")

        // The stale session wakes up: it is announced first, then its new events follow.
        let staleHandle = try FileHandle(forWritingTo: stale)
        staleHandle.seekToEndOfFile()
        staleHandle.write(Data("{\"timestamp\":\"2026-10-12T10:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Again\"}}\n".utf8))
        try staleHandle.close()
        t.expect(t.wait(3) { received.contains { $0.sessionID == "stale-session" && $0.event == .promptSubmitted(text: "Again") } }, "a woken session is followed")
        let staleEvents = received.filter { $0.sessionID == "stale-session" }.map(\.event)
        guard case .sessionStarted? = staleEvents.first else { return t.expect(false, "woken session starts with sessionStarted") }

        // A brand-new session that Perch also hears about through hooks: only usage and failures come from the file.
        _ = adapter.normalize(envelope("codex", payload: "{\"session_id\":\"hooked-session\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"))
        let hooked = day.appendingPathComponent("rollout-2026-10-12T09-00-00-dddd.jsonl")
        box.write(fixtureLines.joined(separator: "\n").replacingOccurrences(of: sessionID, with: "hooked-session") + "\n", to: hooked)
        t.expect(t.wait(3) { received.filter { $0.sessionID == "hooked-session" }.count >= 4 }, "the hooked session's file is read")
        let hookedEvents = received.filter { $0.sessionID == "hooked-session" }.map(\.event)
        t.expect(hookedEvents.allSatisfy { event in
            switch event {
            case .usageUpdated, .metadata: return true
            default: return false
            }
        }, "no duplicate prompts, tools or turn ends for a session hooks already report: \(hookedEvents.count) events")
        t.expectEqual(hookedEvents.filter { if case .usageUpdated = $0 { return true } else { return false } }.count, 3)
    }

    t.test("Codex monitoring: costs nothing when Codex is not installed") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, home) = codexAdapter(box, detected: false)
        var received = 0
        adapter.startMonitoring { received += $0.count }
        t.wait(0.3) { false }
        adapter.stopMonitoring()
        adapter.stopMonitoring()   // stopping twice is harmless
        t.expectEqual(received, 0)
        t.expect(!box.exists(home), "nothing is created")

        // The watcher itself: an absent agent is not polled, and its files are dropped when it disappears.
        var installed = false
        var changes: [String] = []
        let file = box.home.appendingPathComponent("w/a.jsonl")
        box.write("{\"n\":1}\n", to: file)
        let watcher = SessionFileWatcher(queue: .main, listFiles: { installed ? [file] : nil }, onChange: { change in
            switch change {
            case .discovered(_, let existed, _): changes.append("discovered:\(existed)")
            case .lines(_, let lines): changes.append("lines:\(lines.count)")
            case .dropped: changes.append("dropped")
            }
        })
        watcher.pollNow()
        t.expectEqual(changes, [])
        installed = true
        watcher.pollNow()
        t.expectEqual(changes, ["discovered:true"], "existing content is skipped")
        box.write("{\"n\":1}\n{\"n\":2}\n", to: file)
        watcher.pollNow()
        t.expectEqual(changes.last, "lines:1")
        let second = box.home.appendingPathComponent("w/b.jsonl")
        box.write("{\"n\":1}\n{\"n\":2}\n", to: second)
        let both = SessionFileWatcher(queue: .main, listFiles: { [file, second] }, onChange: { change in
            if case .discovered(let url, let existed, _) = change { changes.append("\(url.lastPathComponent):\(existed)") }
            if case .lines(let url, let lines) = change { changes.append("\(url.lastPathComponent):\(lines.count)") }
        })
        both.pollNow()
        box.write("{\"n\":1}\n", to: box.home.appendingPathComponent("w/c.jsonl"))
        t.expect(changes.contains("a.jsonl:true") && changes.contains("b.jsonl:true"))
        installed = false
        watcher.pollNow()
        t.expectEqual(changes.last, "dropped")
    }
}

// MARK: - Gemini CLI

private func geminiAdapter(_ box: Sandbox, detected: Bool = true) -> (GeminiAdapter, URL) {
    let dir = box.home.appendingPathComponent(".gemini", isDirectory: true)
    if detected {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        if !box.exists(dir.appendingPathComponent("settings.json")) { box.write("{}\n", to: dir.appendingPathComponent("settings.json")) }
    }
    var tuning = SessionFileWatcher.Tuning()
    tuning.interval = 0.05
    tuning.absentInterval = 0.05
    return (GeminiAdapter(geminiDir: dir, helperPath: box.helper, backupsDir: box.backups, watcherTuning: tuning), dir)
}

private func runGeminiTests(_ t: TestRunner) {
    let adapter = GeminiAdapter(geminiDir: URL(fileURLWithPath: "/nonexistent/perch-test/.gemini"), helperPath: "/x/perch-hook",
                                backupsDir: URL(fileURLWithPath: "/nonexistent/perch-test/backups"))
    func normalize(_ fixture: String) -> [NormalizedEvent] {
        adapter.normalize(envelope("gemini", payload: TestRunner.fixtureText("antigravity/gemini-cli/hooks/\(fixture)")))
    }
    let sessionID = "5f0c1d1e-6a0b-4b53-8f58-0d5a8c2c9f01"

    t.test("Gemini: every hook fixture normalizes") {
        let names = fixtureNames("antigravity/gemini-cli/hooks")
        t.expectEqual(names.count, 8)
        for name in names {
            let events = normalize(name)
            t.expect(!events.isEmpty, "\(name) gives events")
            t.expect(events.allSatisfy { $0.sessionID == sessionID && $0.agent == .gemini }, name)
            t.expectEqual(events.first?.context.cwd, "/Users/alex/code/shop-api", name)
            t.expect(events.first?.context.transcriptPath?.hasSuffix(".jsonl") == true, name)
        }
    }

    t.test("Gemini: event mapping") {
        t.expectEqual(normalize("SessionStart.synth.json").first?.event, .sessionStarted(title: nil, model: nil, source: "startup"))
        t.expectEqual(normalize("BeforeAgent.synth.json").first?.event, .promptSubmitted(text: "Add a /health endpoint and a test"))
        t.expectEqual(normalize("AfterAgent.synth.json").first?.event,
                      .turnFinished(lastMessage: "Added the /health endpoint and a passing test.", backgroundWork: false))
        t.expectEqual(normalize("SessionEnd.synth.json").first?.event, .sessionEnded(reason: "exit"))

        // Default install has no BeforeTool: AfterTool alone reports the call as started and finished.
        let alone = normalize("AfterTool.synth.json")
        t.expectEqual(alone.count, 2)
        guard case .toolStarted(let call)? = alone.first?.event else { return t.expect(false, "started") }
        t.expectEqual(call.summary, "npm test")
        t.expectEqual(alone.last?.event, .toolFinished(id: call.id, name: "run_shell_command", succeeded: true))
        // With BeforeTool, the pair shares one id and nothing is doubled.
        guard case .toolStarted(let before)? = normalize("BeforeTool.synth.json").first?.event else { return t.expect(false, "before") }
        t.expectEqual(normalize("AfterTool.synth.json").map(\.event), [.toolFinished(id: before.id, name: "run_shell_command", succeeded: true)])
        let failed = "{\"session_id\":\"s\",\"hook_event_name\":\"AfterTool\",\"tool_name\":\"replace\",\"tool_input\":{\"file_path\":\"/a/b.ts\"},\"tool_response\":{\"error\":\"no match\"}}"
        let failedEvents = adapter.normalize(envelope("gemini", payload: failed)).map(\.event)
        guard case .toolStarted(let edit)? = failedEvents.first else { return t.expect(false, "edit") }
        t.expectEqual(edit.summary, "Edit b.ts")
        t.expectEqual(failedEvents.last, .toolFinished(id: edit.id, name: "replace", succeeded: false))
    }

    t.test("Gemini: confirmation prompts are shown but cannot be answered") {
        guard case .permissionRequested(let exec)? = normalize("Notification.ToolPermission.exec.synth.json").first?.event else { return t.expect(false, "exec") }
        t.expectEqual(exec.summary, "Confirm Shell Command")
        t.expectEqual(exec.detail, "npm test")
        t.expect(!exec.isDangerous)
        let editEvents = normalize("Notification.ToolPermission.edit.synth.json")
        guard case .permissionRequested(let edit)? = editEvents.first?.event else { return t.expect(false, "edit") }
        t.expectEqual(edit.detail, "/Users/alex/code/shop-api/src/server.ts")
        t.expectEqual(edit.diff?.added, 1)
        t.expectEqual(editEvents.first?.raw, .null, "whole-file contents in the payload are not kept")
        let request = pendingRequest(.gemini, .permission(exec))
        for decision in [Decision.allow, .deny(message: "no"), .allowAlways(suggestionID: 0), .passToTerminal, .answer([:])] {
            t.expectEqual(adapter.encode(decision, for: request), .passthrough, "Gemini CLI has no decision protocol")
        }
        t.expectEqual(adapter.capabilities, AgentCapabilities(liveEvents: true, approvals: false, questions: false, planReview: false, usage: false, jump: true))
        let other = "{\"session_id\":\"s\",\"hook_event_name\":\"Notification\",\"notification_type\":\"Idle\",\"message\":\"hi\"}"
        t.expectEqual(adapter.normalize(envelope("gemini", payload: other)).first?.event, .notification(kind: "Idle", message: "hi"))
        let mcp = GeminiHookEvents.permissionRequest(details: ["type": "mcp", "serverName": "github", "toolName": "create_issue"], message: "")
        t.expectEqual(mcp.summary, "Use create_issue from github")
        let info = GeminiHookEvents.permissionRequest(details: .null, message: "Proceed?")
        t.expectEqual(info.detail, "Proceed?")
    }

    t.test("Gemini: malformed input is ignored") {
        for bad in ["", "nope", "[]", "{}", "{\"hook_event_name\":\"AfterAgent\"}", "{\"session_id\":\"s\"}", "{\"session_id\":\"s\",\"hook_event_name\":\"BeforeModel\"}",
                    "{\"session_id\":\"s\",\"hook_event_name\":\"BeforeAgent\"}", "{\"session_id\":7,\"hook_event_name\":\"AfterAgent\"}"] {
            t.expectEqual(adapter.normalize(envelope("gemini", payload: bad)), [], "ignored: \(bad.prefix(30))")
        }
        // The event name may come from the command line when the payload lacks it.
        t.expectEqual(adapter.normalize(envelope("gemini", payload: "{\"session_id\":\"s\"}", event: "PreCompress")).first?.event, .compactionStarted)
        t.expectEqual(adapter.normalize(envelope("gemini", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"AfterAgent\"}", channel: "statusline")), [])
        let odd = adapter.normalize(envelope("gemini", payload: "{\"session_id\":\"s\",\"hook_event_name\":\"AfterTool\",\"tool_name\":null,\"tool_input\":\"x\",\"tool_response\":3}"))
        t.expectEqual(odd.count, 2)
    }

    t.test("Gemini: install, idempotence, preservation and uninstall") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, dir) = geminiAdapter(box)
        let settings = dir.appendingPathComponent("settings.json")
        let original = """
        {
          "theme": "GitHub",
          "general": { "vimMode": true, "previewFeatures": false },
          "hooks": {
            "AfterTool": [
              { "matcher": "write_file", "sequential": true, "hooks": [ { "name": "format", "type": "command", "command": "prettier --write .", "timeout": 30000 } ] }
            ]
          },
          "mcpServers": { "github": { "command": "gh-mcp" } }
        }
        """
        box.write(original, to: settings)
        t.expectEqual(adapter.status().hookStatus, .notInstalled)
        _ = try adapter.installHooks()
        let merged = try OrderedJSON.parse(box.read(settings))
        t.expectEqual(merged.members?.map(\.key), ["theme", "general", "hooks", "mcpServers"], "top-level order kept")
        t.expectEqual(merged["general"], try OrderedJSON.parse(original)["general"])
        t.expectEqual(merged["mcpServers"], try OrderedJSON.parse(original)["mcpServers"])
        let afterTool = merged["hooks"]?["AfterTool"]?.arrayValue ?? []
        t.expectEqual(afterTool.count, 2)
        t.expectEqual(afterTool.first, try OrderedJSON.parse(original)["hooks"]?["AfterTool"]?.arrayValue?.first, "the user's hook is untouched and first")
        t.expectEqual(afterTool.last?["matcher"]?.stringValue, "*")
        t.expectEqual(Set(merged["hooks"]?.members?.map(\.key) ?? []), ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "AfterTool", "Notification"])
        t.expectNil(merged["hooks"]?["BeforeTool"], "the risky BeforeTool hook is not installed")
        let reference = try OrderedJSON.parse(TestRunner.fixtureText("antigravity/gemini-cli/config/settings.hooks.perch.json"))
        for member in merged["hooks"]?.members ?? [] {
            let handler = member.value.arrayValue?.last?["hooks"]?.arrayValue?.first
            let command = handler?["command"]?.stringValue ?? ""
            t.expectEqual(command, "'\(box.helper)' --agent gemini --event \(member.key) >/dev/null 2>&1; echo '{}'", member.key)
            t.expectEqual(handler?["name"]?.stringValue, "perch")
            let wanted = reference["hooks"]?[member.key]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            t.expectEqual(handler?["timeout"], wanted?["timeout"], "timeout (milliseconds) matches the research fixture")
            t.expect((wanted?["command"]?.stringValue ?? "").hasSuffix(">/dev/null 2>&1; echo '{}'") && command.hasSuffix(">/dev/null 2>&1; echo '{}'"),
                     "same fail-safe ending as the research fixture")
        }
        t.expectEqual(adapter.status().hookStatus, .installed)
        t.expect(adapter.status().detail.contains("stay in the terminal"), "honest about approvals")
        let first = box.read(settings)
        t.expect(try adapter.installHooks().contains("already installed"))
        t.expectEqual(box.read(settings), first)
        t.expectEqual(box.backupCount, 1)
        _ = try adapter.uninstallHooks()
        t.expectEqual(try OrderedJSON.parse(box.read(settings)), try OrderedJSON.parse(original), "back to exactly the user's settings")
        t.expect(try adapter.uninstallHooks().contains("Nothing was changed"))
    }

    t.test("Gemini: the installed command really is fail-safe") {
        // Run the exact command through bash, as Gemini CLI does, with a helper that does not exist.
        let box = Sandbox(); defer { box.cleanUp() }
        let installer = GeminiHooksInstaller(settingsFile: box.home.appendingPathComponent("s.json"), helperPath: box.helper, backupsDir: box.backups)
        let result = runProcess("/bin/bash", ["-c", installer.command(for: "BeforeAgent")], stdin: "{\"prompt\":\"hi\"}")
        t.expectEqual(result.stdout, "{}\n", "prints {} even though the helper is missing")
        t.expectEqual(result.stderr, "")
        t.expectEqual(result.status, 0)
    }

    t.test("Gemini: detection, stale entries, switched-off hooks and unsafe files") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (absent, absentDir) = geminiAdapter(box, detected: false)
        t.expectEqual(absent.status().hookStatus, .notDetected)
        t.expect((try? absent.installHooks()) == nil)
        t.expect(!box.exists(absentDir), "nothing created for a Mac without Gemini CLI")
        // ~/.gemini with settings but no tmp folder is not Gemini CLI (Antigravity shares the folder).
        box.write("{}", to: absentDir.appendingPathComponent("settings.json"))
        t.expectEqual(absent.status().hookStatus, .notDetected)

        let (adapter, dir) = geminiAdapter(box)
        let settings = dir.appendingPathComponent("settings.json")
        _ = try adapter.installHooks()
        var root = try OrderedJSON.parse(box.read(settings))
        root["hooksConfig"] = try OrderedJSON.parse("{\"disabled\":[\"perch\"]}")
        box.write(root.serialized(), to: settings)
        t.expect(adapter.status().detail.contains("switched off"))
        box.write(box.read(settings).replacingOccurrences(of: box.helper, with: "/old/place/perch-hook"), to: settings)
        t.expectEqual(adapter.status().hookStatus, .needsUpdate)
        _ = try adapter.installHooks()
        t.expect(!box.read(settings).contains("/old/place"), "stale entries are refreshed in place")
        t.expectEqual(try OrderedJSON.parse(box.read(settings))["hooks"]?["AfterAgent"]?.arrayValue?.count, 1, "not duplicated")
        _ = try adapter.uninstallHooks()
        t.expectEqual(try OrderedJSON.parse(box.read(settings)).members?.map(\.key), ["hooksConfig"], "an emptied hooks object is removed, the rest stays")

        for broken in ["{ // comment\n \"a\": 1 }", "[]", "{\"hooks\": 3}", "{\"hooks\": {\"AfterAgent\": {}}}"] {
            box.write(broken, to: settings)
            t.expect((try? adapter.installHooks()) == nil, "refuses \(broken.prefix(14))")
            t.expectEqual(box.read(settings), broken)
        }
        box.write("{ // comment\n}", to: settings)
        t.expectEqual(adapter.status().hookStatus, .error)

        // A file Perch created is removed again on uninstall.
        let fresh = Sandbox(); defer { fresh.cleanUp() }
        let bin = fresh.home.appendingPathComponent("bin/gemini")
        fresh.write("#!/bin/sh\n", to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let created = GeminiAdapter(geminiDir: fresh.home.appendingPathComponent(".gemini"), helperPath: fresh.helper, backupsDir: fresh.backups,
                                    binaryCandidates: [bin.path])
        t.expect(created.isDetected, "found by its binary")
        _ = try created.installHooks()
        t.expect(fresh.exists(fresh.home.appendingPathComponent(".gemini/settings.json")))
        _ = try created.uninstallHooks()
        t.expect(!fresh.exists(fresh.home.appendingPathComponent(".gemini/settings.json")))
    }

    t.test("Gemini: session file gives model, title, tokens and errors") {
        let parser = GeminiSessionParser(fileURL: URL(fileURLWithPath: "/tmp/s.jsonl"), sessionID: nil)
        let lines = TestRunner.fixtureText("antigravity/gemini-cli/session/session.synth.jsonl").split(separator: "\n").map(String.init)
        let events = parser.parse(lines: lines + ["{\"id\":\"e1\",\"type\":\"error\",\"content\":\"Quota exceeded\"}", "junk", "{\"$set\":{}}"])
        t.expect(events.allSatisfy { $0.sessionID == sessionID })
        let usage = events.filter { if case .usageUpdated = $0.event { return true } else { return false } }
        t.expectEqual(usage.count, 2)
        t.expectEqual(usage.last?.event, .usageUpdated(contextPercent: nil, windows: [], model: "gemini-3-pro-preview", costUSD: nil))
        t.expectEqual(usage.last?.raw["tokens"]["total"].intValue, 14134, "token counts ride along in raw")
        t.expect(events.contains { $0.event == .metadata(title: "Add /health endpoint", model: nil, gitBranch: nil, permissionMode: nil) })
        t.expectEqual(events.last?.event, .turnFailed(error: "Quota exceeded"))
        t.expectEqual(parser.parse(lines: [lines[2]]), [], "a rewritten identical record is not reported twice")
        t.expectEqual(GeminiSessionParser(fileURL: URL(fileURLWithPath: "/tmp/x"), sessionID: nil).parse(lines: ["{\"type\":\"error\",\"content\":\"x\"}"]), [],
                      "nothing without a session id")
    }

    t.test("Gemini monitoring: follows only files that hooks pointed at, from their end") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, dir) = geminiAdapter(box)
        let file = dir.appendingPathComponent("tmp/proj/chats/session-1.jsonl")
        box.write("{\"sessionId\":\"g1\"}\n{\"id\":\"old\",\"type\":\"error\",\"content\":\"old failure\"}\n", to: file)
        var received: [NormalizedEvent] = []
        adapter.startMonitoring { received.append(contentsOf: $0) }
        defer { adapter.stopMonitoring() }
        t.wait(0.2) { false }
        t.expectEqual(received.count, 0, "nothing is read before a hook names a file")
        _ = adapter.normalize(envelope("gemini", payload: "{\"session_id\":\"g1\",\"hook_event_name\":\"SessionStart\",\"transcript_path\":\"\(file.path)\"}"))
        t.wait(0.3) { false }
        t.expectEqual(received.count, 0, "old records are not replayed")
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"m1\",\"type\":\"gemini\",\"model\":\"gemini-3-pro\",\"tokens\":{\"total\":10}}\n{\"id\":\"e2\",\"type\":\"error\",\"content\":\"API error\"}\n".utf8))
        try handle.close()
        t.expect(t.wait(3) { received.count >= 2 }, "new records arrive")
        t.expectEqual(received.map(\.sessionID), ["g1", "g1"])
        t.expectEqual(received.last?.event, .turnFailed(error: "API error"))
    }
}

/// Runs a short command and returns what it printed. Used to exercise the installed hook commands.
private func runProcess(_ path: String, _ arguments: [String], stdin: String) -> (stdout: String, stderr: String, status: Int32, seconds: TimeInterval) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let started = Date()
    do { try process.run() } catch { return ("", "could not start: \(error)", -1, 0) }
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    let seconds = Date().timeIntervalSince(started)
    let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (out, err, process.terminationStatus, seconds)
}

// MARK: - Antigravity

private func antigravityAdapter(_ box: Sandbox, detected: Bool = true) -> (AntigravityAdapter, URL) {
    let dir = box.home.appendingPathComponent(".gemini", isDirectory: true)
    if detected { try? FileManager.default.createDirectory(at: dir.appendingPathComponent("antigravity-cli"), withIntermediateDirectories: true) }
    return (AntigravityAdapter(geminiDir: dir, helperPath: box.helper, backupsDir: box.backups), dir)
}

private func runAntigravityTests(_ t: TestRunner) {
    func freshAdapter() -> AntigravityAdapter {
        AntigravityAdapter(geminiDir: URL(fileURLWithPath: "/Users/alex/.gemini"), helperPath: "/x/perch-hook",
                           backupsDir: URL(fileURLWithPath: "/nonexistent/perch-test/backups"))
    }
    func eventName(_ fixture: String) -> String { String(fixture.prefix(while: { $0 != "." })) }
    func normalize(_ adapter: AntigravityAdapter, _ fixture: String) -> [NormalizedEvent] {
        adapter.normalize(envelope("antigravity", payload: TestRunner.fixtureText("antigravity/hooks/\(fixture)"), event: eventName(fixture)))
    }

    t.test("Antigravity: every hook fixture normalizes, and the first event announces the session") {
        let names = fixtureNames("antigravity/hooks")
        t.expectEqual(names.count, 17)
        for name in names {
            let events = normalize(freshAdapter(), name)
            guard case .sessionStarted(_, let model, _)? = events.first?.event else { t.expect(false, "\(name) starts a session"); continue }
            t.expect(model?.hasPrefix("gemini-") == true, name)
            t.expect(events.allSatisfy { $0.agent == .antigravity && $0.rawEventName == eventName(name) }, name)
            t.expect(events.first?.context.cwd?.hasPrefix("/") == true && events.first?.context.cwd != "/tmp/helper-cwd",
                     "\(name): the project comes from workspacePaths, never from the hook's own folder")
            t.expect(events.first?.context.transcriptPath?.hasPrefix("/Users/") == true, "\(name): ~ is expanded")
        }
    }

    t.test("Antigravity: the same payload means different things depending on the event name") {
        let payload = TestRunner.fixtureText("antigravity/hooks/PreInvocation.docs.json")
        let pre = freshAdapter().normalize(envelope("antigravity", payload: payload, event: "PreInvocation")).map(\.event)
        let post = freshAdapter().normalize(envelope("antigravity", payload: payload, event: "PostInvocation")).map(\.event)
        t.expectEqual(pre.count, 2)
        t.expectEqual(pre.last, .promptSubmitted(text: ""), "no transcript to read: the prompt text is unknown")
        t.expectEqual(post.count, 1, "PostInvocation only announces the session")
        t.expectEqual(freshAdapter().normalize(envelope("antigravity", payload: payload, event: nil)), [], "no event name, no guess")
        t.expectEqual(freshAdapter().normalize(envelope("antigravity", payload: payload, event: "SomethingNew")).count, 1)
    }

    t.test("Antigravity: tools, questions and permission requests") {
        let adapter = freshAdapter()
        let post = normalize(adapter, "PostToolUse.view_file.ok.synth.json").map(\.event)
        guard case .toolStarted(let read)? = post.dropFirst().first else { return t.expect(false, "synth start") }
        t.expectEqual(read.summary, "Read server.ts")
        t.expectEqual(post.last, .toolFinished(id: read.id, name: "view_file", succeeded: true))
        let failed = normalize(freshAdapter(), "PostToolUse.run_command.error.docs.json").map(\.event)
        guard case .toolFinished(_, let name, let ok)? = failed.last else { return t.expect(false, "failed tool") }
        t.expectEqual(name, "run_command")
        t.expect(!ok, "a non-empty error means the tool failed (the turn continues)")
        t.expect(!failed.contains { if case .turnFailed = $0 { return true } else { return false } })
        guard case .toolStarted(let command)? = failed.dropFirst().first else { return t.expect(false, "command") }
        t.expectEqual(command.summary, "npm test")

        // With the experimental hook: PreToolUse then PostToolUse share an id.
        let paired = freshAdapter()
        let before = normalize(paired, "PreToolUse.run_command.docs.json").map(\.event)
        guard case .toolStarted(let started)? = before.last else { return t.expect(false, "pre") }
        let after = normalize(paired, "PostToolUse.run_command.error.docs.json").map(\.event)
        t.expectEqual(after, [.toolFinished(id: started.id, name: "run_command", succeeded: false)])

        let memory = ToolStartMemory()
        memory.noteStarted(session: "s", tool: "view_file", callID: "first")
        memory.noteStarted(session: "s", tool: "view_file", callID: "second")
        t.expectEqual(memory.takeStarted(session: "s", tool: "view_file"), "first", "same-name calls pair in the order they started")
        t.expectEqual(memory.takeStarted(session: "s", tool: "view_file"), "second")
        t.expectNil(memory.takeStarted(session: "s", tool: "view_file"))
        t.expectNil(memory.takeStarted(session: "other", tool: "view_file"))

        let question = normalize(freshAdapter(), "PreToolUse.ask_question.synth.json").map(\.event)
        guard case .questionAsked(let request)? = question.last else { return t.expect(false, "question") }
        t.expectEqual(request.questions.map(\.text), ["Which package manager should I use?", "Which checks should run before commit?"])
        t.expectEqual(request.questions.map(\.multiSelect), [false, true])
        t.expectEqual(request.questions.first?.options.map(\.label), ["npm", "pnpm", "yarn"])
        let permission = normalize(freshAdapter(), "PreToolUse.ask_permission.synth.json").map(\.event)
        guard case .permissionRequested(let ask)? = permission.last else { return t.expect(false, "permission") }
        t.expectEqual(ask.detail, "git push")
        t.expectEqual(ask.summary, "Publish the release branch")
        let plan = normalize(freshAdapter(), "PostToolUse.write_to_file.plan-artifact.synth.json").map(\.event)
        guard case .notification(let kind, let message)? = plan.last else { return t.expect(false, "plan note") }
        t.expectEqual(kind, "plan_ready")
        t.expect(message.contains("implementation_plan.md"))
        t.expect(!plan.contains { if case .planProposed = $0 { return true } else { return false } }, "a written plan is a note, not a blocking review")

        let adapterForEncode = freshAdapter()
        for decision in [Decision.allow, .deny(message: nil), .answer(["q": "a"]), .approvePlan(acceptEdits: false), .passToTerminal] {
            t.expectEqual(adapterForEncode.encode(decision, for: pendingRequest(.antigravity, .permission(ask))), .passthrough)
        }
        t.expectEqual(adapterForEncode.capabilities, AgentCapabilities(liveEvents: true, approvals: false, questions: false, planReview: false, usage: false, jump: true))
        t.expectEqual(AntigravityHookEvents.toolSummary(name: "browser_click_element", args: .null), "Browser: click element")
        t.expectEqual(AntigravityHookEvents.toolSummary(name: "grep_search", args: ["Query": "TODO"]), "Search for TODO")
    }

    t.test("Antigravity: turn endings") {
        t.expectEqual(normalize(freshAdapter(), "Stop.model_stop.docs.json").last?.event, .turnFinished(lastMessage: nil, backgroundWork: false))
        t.expectEqual(normalize(freshAdapter(), "Stop.background-tasks.synth.json").last?.event, .turnFinished(lastMessage: nil, backgroundWork: true))
        guard case .turnFailed(let error)? = normalize(freshAdapter(), "Stop.error.synth.json").last?.event else { return t.expect(false, "failed") }
        t.expect(!error.isEmpty)
        t.expectEqual(normalize(freshAdapter(), "Stop.max_steps.synth.json").last?.event,
                      .turnFinished(lastMessage: "Stopped after reaching the step limit.", backgroundWork: false))
        // Missing fields (protobuf JSON omits empty values) are read as "nothing wrong".
        let sparse = freshAdapter().normalize(envelope("antigravity", payload: "{\"conversationId\":\"c\"}", event: "Stop")).map(\.event)
        t.expectEqual(sparse.last, .turnFinished(lastMessage: nil, backgroundWork: false))
    }

    for file in ["turn.safe-mode.synth.ndjson", "turn.with-pretooluse.synth.ndjson", "turn.failed.synth.ndjson"] {
        t.test("Antigravity: sequence \(file) replays into one coherent turn") {
            let box = Sandbox(); defer { box.cleanUp() }
            let transcript = box.home.appendingPathComponent("transcript.jsonl")
            box.write(TestRunner.fixtureText("antigravity/transcript/transcript.synth.jsonl"), to: transcript)
            let adapter = freshAdapter()
            var all: [AgentEvent] = []
            for line in TestRunner.fixtureText("antigravity/sequences/\(file)").split(separator: "\n") {
                guard var step = JSONValue.parse(String(line))?.objectValue, var payload = step["payload"]?.objectValue else { continue }
                payload["transcriptPath"] = .string(transcript.path)   // point at a transcript that exists
                step["payload"] = .object(payload)
                all += adapter.normalize(envelope("antigravity", payload: JSONValue.object(payload).serialized(), event: step["event"]?.stringValue)).map(\.event)
            }
            t.expectEqual(all.filter { if case .sessionStarted = $0 { return true } else { return false } }.count, 1, "one session")
            t.expectEqual(all.filter { if case .promptSubmitted = $0 { return true } else { return false } },
                          [.promptSubmitted(text: "Add a /health endpoint and a test")], "one prompt per turn, text from the transcript")
            let starts = all.compactMap { event -> String? in if case .toolStarted(let call) = event { return call.id } else { return nil } }
            let ends = all.compactMap { event -> String? in if case .toolFinished(let id, _, _) = event { return id } else { return nil } }
            if file != "turn.failed.synth.ndjson" {
                t.expect(!starts.isEmpty, "tools are visible even without a PreToolUse hook")
                t.expectEqual(Set(starts), Set(ends), "every tool start has its finish")
                t.expectEqual(starts.count, Set(starts).count, "no tool is reported twice")
                t.expectEqual(all.last, .turnFinished(lastMessage: "I added the /health endpoint and a passing test.", backgroundWork: false))
            } else {
                guard case .turnFailed? = all.last else { return t.expect(false, "ends in failure") }
            }
        }
    }

    t.test("Antigravity: a second turn starts at the next model call, whatever its number") {
        let adapter = freshAdapter()
        func send(_ event: String, _ extra: String = "") -> [AgentEvent] {
            adapter.normalize(envelope("antigravity", payload: "{\"conversationId\":\"c1\"\(extra)}", event: event)).map(\.event)
        }
        t.expectEqual(send("PreInvocation").count, 2)
        t.expectEqual(send("PreInvocation", ",\"invocationNum\":1"), [], "later model calls in the same turn are quiet")
        t.expectEqual(send("Stop").count, 1)
        t.expectEqual(send("PreInvocation", ",\"invocationNum\":7"), [.promptSubmitted(text: "")], "works even if the counter does not restart")
        for bad in ["", "x", "[]", "{}", "{\"conversationId\":\"\"}", "{\"conversationId\":3}"] {
            t.expectEqual(adapter.normalize(envelope("antigravity", payload: bad, event: "Stop")), [], "ignored: \(bad)")
        }
        t.expectEqual(AntigravityHookEvents.surface(transcriptPath: "/Users/a/.gemini/antigravity-cli/brain/x", env: [:]), "cli")
        t.expectEqual(AntigravityHookEvents.surface(transcriptPath: "/Users/a/.gemini/antigravity/brain/x", env: [:]), "app")
        t.expectEqual(AntigravityHookEvents.surface(transcriptPath: "/Users/a/.gemini/antigravity/brain/x", env: ["__CFBundleIdentifier": "com.google.antigravity-ide"]), "ide")
        t.expectNil(AntigravityHookEvents.surface(transcriptPath: nil, env: [:]))
    }

    t.test("Antigravity: status feed gives quota, cost, title and the waiting signal, never the email") {
        let adapter = freshAdapter()
        let feed = TestRunner.fixtureText("antigravity/statusline/payload.tool-confirmation.synth.json")
        let events = adapter.normalize(envelope("antigravity", payload: feed, channel: "statusline"))
        t.expectEqual(events.first?.event, .sessionStarted(title: "Add a /health endpoint", model: "Gemini 3.8 Flash (High)", source: "cli"))
        t.expect(events.contains { $0.event == .metadata(title: "Add a /health endpoint", model: "Gemini 3.8 Flash (High)", gitBranch: "main", permissionMode: nil) })
        guard case .usageUpdated(let percent, let windows, _, let cost)? = events.first(where: { if case .usageUpdated = $0.event { return true } else { return false } })?.event
        else { return t.expect(false, "usage") }
        t.expectEqual(percent, 14.24)
        t.expectEqual(cost, 0.4821375)
        t.expectEqual(windows.map(\.id), ["gemini-5h", "gemini-weekly"])
        t.expectEqual(windows.map(\.label), ["Gemini 5-hour limit", "Gemini weekly limit"])
        t.expect(abs((windows.first?.usedPercent ?? 0) - 58) < 0.001, "used = 1 - remaining")
        t.expect(windows.allSatisfy { $0.resetsAt != nil })
        t.expectEqual(events.last?.event, .notification(kind: "permission_prompt", message: "Antigravity is waiting for your approval in its terminal."))
        t.expect(events.allSatisfy { $0.raw == .null && !"\($0)".contains("someone@example.com") }, "the account email is never carried along")
        t.expectEqual(events.first?.context.cwd, "/Users/alex/code/shop-api")
        t.expectEqual(adapter.normalize(envelope("antigravity", payload: feed, channel: "statusline")), [], "an unchanged feed produces nothing")
        let docs = freshAdapter().normalize(envelope("antigravity", payload: TestRunner.fixtureText("antigravity/statusline/payload.docs-example.json"), channel: "statusline"))
        t.expect(!docs.contains { if case .notification = $0.event { return true } else { return false } }, "no waiting signal in the docs example")
        t.expect(docs.count >= 3)
        t.expectEqual(AntigravityHookEvents.quotaWindows(["a": ["disabled": true], "b": ["remaining_fraction": 1.5, "reset_in_seconds": 60]], now: Date(timeIntervalSince1970: 0)),
                      [RateWindow(id: "b", label: "B limit", usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 60))])
        t.expectEqual(freshAdapter().normalize(envelope("antigravity", payload: "{\"agent_state\":\"idle\"}", channel: "statusline")), [])
    }

    t.test("Antigravity: transcript reading is best effort") {
        let path = TestRunner.fixture("antigravity/transcript/transcript.synth.jsonl").path
        t.expectEqual(AntigravityTranscript.lastUserRequest(at: path), "Add a /health endpoint and a test")
        t.expectEqual(AntigravityTranscript.lastReply(at: path), "I added the /health endpoint and a passing test.")
        t.expectNil(AntigravityTranscript.lastUserRequest(at: "/nonexistent/file"))
        let box = Sandbox(); defer { box.cleanUp() }
        let odd = box.home.appendingPathComponent("t.jsonl")
        box.write("not json USER_INPUT\n{\"type\":\"USER_INPUT\",\"content\":\"plain text\"}\n{\"type\":\"USER_INPUT\"}\n", to: odd)
        t.expectNil(AntigravityTranscript.lastUserRequest(at: odd.path), "newest record has no content")
        box.write("{\"type\":\"USER_INPUT\",\"content\":\"plain text\"}\n", to: odd)
        t.expectEqual(AntigravityTranscript.lastUserRequest(at: odd.path), "plain text")
    }

    runAntigravityInstallTests(t)
}

private func runAntigravityInstallTests(_ t: TestRunner) {
    t.test("Antigravity: install writes the documented shapes and never a broken one") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, dir) = antigravityAdapter(box)
        let hooks = dir.appendingPathComponent("config/hooks.json")
        let shim = dir.appendingPathComponent("config/perch/hook.sh")
        t.expectEqual(adapter.status().hookStatus, .notInstalled)
        let summary = try adapter.installHooks()
        t.expect(summary.contains("Restart"), "tells the user to restart running sessions")
        let root = try OrderedJSON.parse(box.read(hooks))
        t.expectEqual(root.members?.map(\.key), ["perch"])
        let block = root["perch"]
        t.expectEqual(block?.members?.map(\.key), ["PreInvocation", "PostInvocation", "PostToolUse", "Stop"], "no PreToolUse by default")
        // Same structure as the research's reference file, with this machine's paths.
        let reference = TestRunner.fixtureText("antigravity/config/hooks.perch.safe.json")
            .replacingOccurrences(of: "/Users/alex/.gemini/config/perch/hook.sh", with: shim.path)
        t.expectEqual(root, try OrderedJSON.parse(reference), "identical to the research's safe block")
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let entry = block?[event]?.arrayValue?.first
            t.expectEqual(entry?["command"]?.stringValue, "/bin/sh \(shim.path) \(event)", "\(event): command at the top level")
            t.expectNil(entry?["hooks"], "\(event) must not be wrapped in hooks:[...]")
        }
        let command = block?["PostToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue ?? ""
        t.expect(!command.contains("'") && !command.contains("\"") && !command.contains(";") && !command.contains("&") && !command.contains("|"),
                 "no shell syntax in the command line")
        t.expectEqual(command.split(separator: " ").count, 3, "exactly: /bin/sh <script> <Event>")
        t.expectNil(AntigravityHooksInstaller.shapeProblem(in: block ?? .null))
        let broken = try OrderedJSON.parse(TestRunner.fixtureText("antigravity/config/hooks.broken-nested-stop.src.json"))
        t.expect((broken.members ?? []).contains { AntigravityHooksInstaller.shapeProblem(in: $0.value) != nil }, "the known-bad shape is recognised")
        let docs = try OrderedJSON.parse(TestRunner.fixtureText("antigravity/config/hooks.docs-example.json"))
        t.expect((docs.members ?? []).allSatisfy { AntigravityHooksInstaller.shapeProblem(in: $0.value) == nil }, "Google's own example passes the check")

        t.expect(box.exists(shim))
        t.expect(FileManager.default.isExecutableFile(atPath: shim.path))
        t.expect(box.read(shim).contains("PERCH_HOOK='\(box.helper)'"), "helper path is quoted inside the script")
        t.expectEqual(adapter.status().hookStatus, .installed)
        t.expect(adapter.status().detail.contains("stay in Antigravity"), "honest about approvals")
        let first = box.read(hooks)
        t.expect(try adapter.installHooks().contains("already installed"))
        t.expectEqual(box.read(hooks), first)
        t.expectEqual(box.backupCount, 0)

        _ = try adapter.uninstallHooks()
        t.expect(!box.exists(hooks), "a file Perch created is removed")
        t.expect(!box.exists(shim) && !box.exists(shim.deletingLastPathComponent()), "script and its folder are removed")
        t.expectEqual(adapter.status().hookStatus, .notInstalled)
        t.expect(try adapter.uninstallHooks().contains("Nothing was changed"))
    }

    t.test("Antigravity: merge next to the user's hooks, pause, repair, uninstall") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (adapter, dir) = antigravityAdapter(box)
        let hooks = dir.appendingPathComponent("config/hooks.json")
        let shim = dir.appendingPathComponent("config/perch/hook.sh")
        let original = "\u{FEFF}" + TestRunner.fixtureText("antigravity/config/hooks.docs-example.json")   // a byte-order mark is legal here
        box.write(original, to: hooks)
        _ = try adapter.installHooks()
        let merged = try OrderedJSON.parse(box.read(hooks))
        let originalRoot = try OrderedJSON.parse(original)
        t.expectEqual(merged.members?.dropLast().map(\.key), originalRoot.members?.map(\.key), "the user's hooks keep their order")
        for member in originalRoot.members ?? [] { t.expectEqual(merged[member.key], member.value, "\(member.key) untouched") }
        t.expectEqual(merged.members?.last?.key, "perch")
        t.expectEqual(box.backupCount, 1)
        let golden = try OrderedJSON.parse(TestRunner.fixtureText("antigravity/config/hooks.merged-with-user.json")
            .replacingOccurrences(of: "/Users/alex/.gemini/config/perch/hook.sh", with: shim.path))
        t.expectEqual(merged["perch"], golden["perch"], "matches the research's merged example")

        // The user pauses Perch's hooks; a reinstall keeps the pause.
        var paused = merged
        var block = paused["perch"] ?? .object([])
        block["enabled"] = .bool(false)
        paused["perch"] = block
        box.write(paused.serialized(), to: hooks)
        t.expect(adapter.status().detail.contains("paused"))
        box.write("#!/bin/sh\n# old script\n", to: shim)
        t.expectEqual(adapter.status().hookStatus, .needsUpdate, "an outdated script is noticed")
        _ = try adapter.installHooks()
        t.expectEqual(try OrderedJSON.parse(box.read(hooks))["perch"]?["enabled"], .bool(false), "pause survives")
        t.expect(box.read(shim).contains("printf"), "script repaired")
        t.expectEqual(adapter.status().hookStatus, .installed)

        // A broken hook from someone else is reported, not touched.
        var withBroken = try OrderedJSON.parse(box.read(hooks))
        withBroken["other-tool"] = try OrderedJSON.parse("{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}")
        box.write(withBroken.serialized(), to: hooks)
        t.expect(try adapter.installHooks(includingPreToolUse: true).contains("other-tool"), "warns about the invalid neighbour")
        t.expectEqual(try OrderedJSON.parse(box.read(hooks))["other-tool"], withBroken["other-tool"])

        // Experimental PreToolUse: matches the research's variant, and uninstall then keeps the script.
        let withPre = try OrderedJSON.parse(box.read(hooks))["perch"]
        var expected = try OrderedJSON.parse(TestRunner.fixtureText("antigravity/config/hooks.perch.with-pretooluse.json")
            .replacingOccurrences(of: "/Users/alex/.gemini/config/perch/hook.sh", with: shim.path))["perch"]
        expected?["enabled"] = nil
        var comparable = withPre
        comparable?["enabled"] = nil
        t.expectEqual(comparable?.jsonValue, expected?.jsonValue, "matches the research's PreToolUse variant")
        let summary = try adapter.uninstallHooks()
        t.expect(summary.contains("left in place"), "explains why the script stays")
        t.expect(box.exists(shim), "running sessions would refuse tools without it")
        let after = try OrderedJSON.parse(box.read(hooks))
        t.expectNil(after["perch"])
        t.expectEqual(after.members?.map(\.key), (originalRoot.members?.map(\.key) ?? []) + ["other-tool"])
        t.expect(box.exists(hooks), "the user's file is kept")
    }

    t.test("Antigravity: detection and files that must not be touched") {
        let box = Sandbox(); defer { box.cleanUp() }
        let (absent, dir) = antigravityAdapter(box, detected: false)
        // Only Gemini CLI's files are present: that is not Antigravity.
        box.write("{}", to: dir.appendingPathComponent("settings.json"))
        t.expectEqual(absent.status().hookStatus, .notDetected)
        t.expect((try? absent.installHooks()) == nil)
        t.expect(!box.exists(dir.appendingPathComponent("config")), "no config folder is created for a Gemini-CLI-only user")
        let viaApp = AntigravityAdapter(geminiDir: dir, helperPath: box.helper, backupsDir: box.backups,
                                        appLookup: { $0 == "com.google.antigravity-ide" ? URL(fileURLWithPath: "/Applications/Antigravity IDE.app") : nil })
        t.expectEqual(viaApp.detectedSurfaces, ["IDE"])
        t.expect(viaApp.status().detected)

        let (adapter, _) = antigravityAdapter(box)
        t.expectEqual(adapter.detectedSurfaces, ["CLI"])
        let hooks = dir.appendingPathComponent("config/hooks.json")
        for broken in ["{ nope", "[]", "\"text\""] {
            box.write(broken, to: hooks)
            t.expect((try? adapter.installHooks()) == nil, "refuses \(broken)")
            t.expectEqual(box.read(hooks), broken)
            t.expect(!box.exists(dir.appendingPathComponent("config/perch/hook.sh")), "no script without a hooks block")
        }
        box.write("{ nope", to: hooks)
        t.expectEqual(adapter.status().hookStatus, .error)
        t.expect((try? adapter.uninstallHooks()) == nil)

        // A home folder with a space cannot be used safely (one runtime splits the command on spaces).
        let spaced = box.root.appendingPathComponent("my home/.gemini")
        try FileManager.default.createDirectory(at: spaced.appendingPathComponent("antigravity"), withIntermediateDirectories: true)
        let spacedAdapter = AntigravityAdapter(geminiDir: spaced, helperPath: box.helper, backupsDir: box.backups)
        do {
            _ = try spacedAdapter.installHooks()
            t.expect(false, "should refuse a path with a space")
        } catch {
            t.expect(((error as? LocalizedError)?.errorDescription ?? "").contains("space"))
        }
        t.expect(!box.exists(spaced.appendingPathComponent("config")))
    }

    t.test("Antigravity: the script answers correctly whatever state Perch is in") {
        let box = Sandbox(); defer { box.cleanUp() }
        let dir = box.home.appendingPathComponent("shim")
        let payload = "{\"conversationId\":\"c\",\"toolCall\":{\"name\":\"run_command\"}}"

        // 1. Perch missing entirely.
        let missing = dir.appendingPathComponent("missing.sh")
        box.write(AntigravityShim.script(helperPath: box.helper), to: missing)
        var result = runProcess("/bin/sh", [missing.path, "PreToolUse"], stdin: payload)
        t.expectEqual(result.stdout, "{\"decision\":\"ask\"}", "PreToolUse always gets a decision")
        t.expectEqual(result.status, 0)
        t.expectEqual(result.stderr, "")
        for event in ["PreInvocation", "PostInvocation", "PostToolUse", "Stop"] {
            result = runProcess("/bin/sh", [missing.path, event], stdin: payload)
            t.expectEqual(result.stdout, "{}", "\(event) gets an empty object")
            t.expectEqual(result.status, 0)
        }
        result = runProcess("/bin/sh", [missing.path], stdin: "")
        t.expectEqual(result.stdout, "{}", "no event name still answers")
        t.expect(JSONValue.parse(TestRunner.fixtureText("antigravity/hook-outputs/PreToolUse.perch-observer.json")) == JSONValue.parse(AntigravityShim.preToolUseAnswer))
        t.expect(JSONValue.parse(TestRunner.fixtureText("antigravity/hook-outputs/lifecycle.perch-observer.json")) == JSONValue.parse(AntigravityShim.observerAnswer))

        // 2. Perch present (path with a space): it receives the payload and the event name, and its output is discarded.
        let capture = dir.appendingPathComponent("captured.txt")
        let helper = dir.appendingPathComponent("with space/perch-hook")
        box.write("#!/bin/sh\necho \"$@\" > '\(capture.path)'\ncat >> '\(capture.path)'\necho noise\necho noise >&2\nexit 3\n", to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let working = dir.appendingPathComponent("working.sh")
        box.write(AntigravityShim.script(helperPath: helper.path), to: working)
        result = runProcess("/bin/sh", [working.path, "Stop"], stdin: payload)
        t.expectEqual(result.stdout, "{}", "the helper's own output never reaches Antigravity")
        t.expectEqual(result.stderr, "")
        t.expectEqual(result.status, 0, "even when the helper exits non-zero")
        t.expectEqual(box.read(capture), "--agent antigravity --event Stop\n\(payload)")

        // 3. Perch hangs: the script still answers at once and exits by itself within about two seconds.
        let hanging = dir.appendingPathComponent("hang/perch-hook")
        box.write("#!/bin/sh\nexec sleep 20\n", to: hanging)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        let slow = dir.appendingPathComponent("slow.sh")
        box.write(AntigravityShim.script(helperPath: hanging.path), to: slow)
        result = runProcess("/bin/sh", [slow.path, "PreToolUse"], stdin: payload)
        t.expectEqual(result.stdout, "{\"decision\":\"ask\"}")
        t.expectEqual(result.status, 0)
        t.expect(result.seconds < 4.5, "returned in \(result.seconds)s, inside the 5 second hook timeout")
        t.expect(result.seconds > 1.0, "the watchdog, not luck, ended it")
    }
}

// ClaudeDangerDetector.swift — decides whether a shell command deserves a second look.
//
// Approval cards mark some commands as dangerous (PermissionRequest.isDangerous) so the card can
// warn, and ask for confirmation when the user turned that on. This file holds the whole rule
// set in one place: deleting folders, administrator rights, rewriting git history on a remote,
// throwing away local changes, running a script straight from the internet, opening files to
// everyone, writing to or erasing disks, shutting the Mac down, and fork bombs.
//
// It works on the parsed command (see ClaudeShellParser), so text that merely mentions a risky
// command — inside quotes, a comment, a commit message, a file written with a here-document —
// is not flagged. It errs on the side of silence for anything it does not recognise: this is a
// hint for people, not a security boundary.

import Foundation

enum ClaudeDangerDetector {
    static func isDangerous(_ command: String) -> Bool { reason(for: command) != nil }

    /// A short plain-English reason when the command is risky, nil when it looks ordinary.
    static func reason(for command: String) -> String? { reason(for: command, depth: 0) }

    // MARK: - Word lists (the one obvious place to adjust the rules)

    /// Commands that only run another command: the real one comes after them.
    private static let wrappers: Set<String> = [
        "env", "command", "builtin", "exec", "nohup", "time", "nice", "caffeinate", "stdbuf", "timeout", "xargs", "watch",
    ]
    /// Wrapper options that take a value as the next word (so that value is not mistaken for the command).
    private static let wrapperOptionsWithValue: [String: Set<String>] = [
        "env": ["-u", "-C", "-S"], "nice": ["-n"], "caffeinate": ["-t", "-w"], "timeout": ["-s", "-k"],
        "xargs": ["-I", "-n", "-P", "-L", "-d", "-E", "-s", "-J", "-R"], "watch": ["-n", "-d"], "stdbuf": ["-i", "-o", "-e"],
    ]
    /// Shell words that can stand in front of a command without being one.
    private static let reservedWords: Set<String> = [
        "{", "}", "!", "if", "then", "else", "elif", "fi", "while", "until", "do", "done", "function",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    /// Programs that run whatever text they are given on standard input when no script file is named.
    private static let interpreters: Set<String> = ["python", "python3", "perl", "ruby", "node", "php", "osascript"]
    private static let downloaders: Set<String> = ["curl", "wget", "fetch"]
    private static let harmlessDevices: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/zero", "/dev/tty"]
    private static let diskEraseVerbs: Set<String> = [
        "erasedisk", "erasevolume", "erase", "zerodisk", "randomdisk", "secureerase", "partitiondisk", "reformat",
    ]
    private static let apfsDeleteVerbs: Set<String> = ["deletecontainer", "deletevolume", "deletevolumegroup", "erasevolume"]
    /// How many levels of "a command inside a command" (`bash -c`, `$(...)`, `eval`) are followed.
    private static let maxDepth = 4
    /// Commands longer than this are only examined up to this many characters.
    private static let maxLength = 50_000

    // MARK: - Walking the command line

    private static func reason(for command: String, depth: Int) -> String? {
        guard depth <= maxDepth, !command.isEmpty else { return nil }
        let text = command.count > maxLength ? String(command.prefix(maxLength)) : command
        if isForkBomb(text) { return "starts endless copies of itself (a fork bomb)" }

        for pipeline in ClaudeShellParser.pipelines(in: text) {
            let stages = pipeline.map { (command: $0, resolved: resolve($0.words)) }
            for stage in stages {
                if let found = redirectReason(stage.command) { return found }
                if let resolved = stage.resolved,
                   let found = commandReason(name: resolved.name, args: resolved.args, command: stage.command, depth: depth) {
                    return found
                }
                for nested in stage.command.nested {
                    if let found = reason(for: nested, depth: depth + 1) { return found }
                }
            }
            if pipesDownloadIntoInterpreter(stages.map(\.resolved)) {
                return "downloads a script and runs it straight away"
            }
        }
        return nil
    }

    /// Finds the program a list of words really runs: skips `VAR=value` settings, shell keywords
    /// and wrapper commands such as `env`, `nohup` or `xargs`.
    private static func resolve(_ allWords: [String]) -> (name: String, args: [String])? {
        var words = allWords[...]
        for _ in 0..<8 {
            while let first = words.first, isAssignment(first) || reservedWords.contains(first) { words = words.dropFirst() }
            guard let first = words.first else { return nil }
            let name = (first as NSString).lastPathComponent.lowercased()
            guard wrappers.contains(name) else { return (name, Array(words.dropFirst())) }
            words = words.dropFirst()
            let valueOptions = wrapperOptionsWithValue[name] ?? []
            while let option = words.first, option.hasPrefix("-") || (name == "env" && isAssignment(option)) {
                words = words.dropFirst()
                if valueOptions.contains(option) { words = words.dropFirst() }
            }
            // `timeout 30 npm test`: the first plain word is the duration.
            if name == "timeout", words.first != nil { words = words.dropFirst() }
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Rules per command

    private static func commandReason(name: String, args: [String], command: ClaudeShellCommand, depth: Int) -> String? {
        switch name {
        case "sudo", "doas", "su":
            return "runs with administrator rights (\(name))"
        case "rm":
            return removesFolders(args) ? "deletes folders and everything inside them (rm -r)" : nil
        case "git":
            return gitReason(args)
        case "chmod":
            return opensToEveryone(args) ? "makes files writable by everyone (chmod -R)" : nil
        case "dd":
            let writesDevice = args.contains { arg in
                guard arg.hasPrefix("of=") else { return false }
                let target = String(arg.dropFirst(3))
                return target.hasPrefix("/dev/") && !harmlessDevices.contains(target) && !target.hasPrefix("/dev/fd/")
            }
            return writesDevice ? "writes straight to a disk or device (dd)" : nil
        case "diskutil":
            let verbs = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
            guard let verb = verbs.first else { return nil }
            let erases = diskEraseVerbs.contains(verb) || (verb == "apfs" && verbs.count > 1 && apfsDeleteVerbs.contains(verbs[1]))
            return erases ? "erases or repartitions a disk (diskutil)" : nil
        case "shutdown", "reboot", "halt", "poweroff":
            return "shuts down or restarts the Mac"
        case "kill":
            return args.count >= 2 && args.last == "-1" ? "stops every process you own (kill -1)" : nil
        case "wipefs", "shred":
            return "destroys data beyond recovery (\(name))"
        case "csrutil":
            return args.contains("disable") ? "turns off a macOS security feature" : nil
        case "spctl":
            return args.contains("--master-disable") || args.contains("--global-disable") ? "turns off a macOS security feature" : nil
        case "find":
            return findReason(args, depth: depth)
        case "eval":
            if command.nested.contains(where: startsWithDownloader) { return "downloads a script and runs it straight away" }
            return reason(for: args.joined(separator: " "), depth: depth + 1)
        case "source", ".":
            return command.nested.contains(where: startsWithDownloader) ? "downloads a script and runs it straight away" : nil
        case "ssh":
            return sshReason(args, depth: depth)
        default:
            if shells.contains(name) { return shellReason(args, command: command, depth: depth) }
            if name == "mkfs" || name.hasPrefix("mkfs.") || name == "newfs" || name.hasPrefix("newfs_") {
                return "formats a disk (\(name))"
            }
            return nil
        }
    }

    /// `rm` with a "recursive" option in any spelling: -r, -R, -rf, -fr, --recursive.
    private static func removesFolders(_ args: [String]) -> Bool {
        for arg in args {
            if arg == "--" { break }
            if arg == "--recursive" { return true }
            if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.contains(where: { $0 == "r" || $0 == "R" }) { return true }
        }
        return false
    }

    private static func gitReason(_ allArgs: [String]) -> String? {
        // Skip git's own options ("git -C repo push") to find the subcommand.
        var args = allArgs[...]
        let optionsWithValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]
        while let first = args.first, first.hasPrefix("-") {
            args = args.dropFirst()
            if optionsWithValue.contains(first) { args = args.dropFirst() }
        }
        guard let subcommand = args.first else { return nil }
        let rest = Array(args.dropFirst())
        func hasShortFlag(_ letter: Character) -> Bool {
            rest.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(letter) }
        }
        let dryRun = rest.contains("--dry-run") || hasShortFlag("n")

        switch subcommand {
        case "push":
            guard !dryRun else { return nil }
            let forced = rest.contains { $0 == "--force" || $0.hasPrefix("--force-with-lease") || $0 == "--mirror" || $0 == "--delete" }
                || hasShortFlag("f") || hasShortFlag("d")
                || rest.contains { $0.hasPrefix("+") && $0.count > 1 }
            return forced ? "overwrites or deletes branches on the remote (git push --force)" : nil
        case "reset":
            return rest.contains("--hard") ? "throws away uncommitted changes (git reset --hard)" : nil
        case "clean":
            guard !dryRun else { return nil }
            return rest.contains("--force") || hasShortFlag("f") ? "deletes untracked files (git clean)" : nil
        case "checkout":
            let discards = rest.contains("--force") || hasShortFlag("f") || rest.contains(".")
            return discards ? "throws away uncommitted changes (git checkout)" : nil
        case "restore":
            // `git restore --staged .` only unstages; it is the working tree that loses changes.
            let worktree = !rest.contains("--staged") || rest.contains("--worktree")
            return worktree && rest.contains(".") ? "throws away uncommitted changes (git restore)" : nil
        default:
            return nil
        }
    }

    /// `chmod -R` with a mode that lets everyone write: 777, 666, a+w, o+rwx...
    private static func opensToEveryone(_ args: [String]) -> Bool {
        // chmod's own options are capital or lower-case letters that are not permission letters;
        // "-w" or "-x" by itself is a mode ("remove write"), not an option.
        func isOption(_ arg: String) -> Bool {
            arg == "--recursive" || (arg.hasPrefix("-") && arg.count > 1 && arg.dropFirst().allSatisfy { "RfhvHLPECNiI".contains($0) })
        }
        let recursive = args.contains { $0 == "--recursive" || (isOption($0) && $0.contains("R")) }
        guard recursive, let mode = args.first(where: { !isOption($0) }) else { return false }
        if mode.count >= 3, mode.count <= 4, mode.allSatisfy({ ("0"..."7").contains($0) }) {
            // Octal: the last digit is "everyone else"; its 2-bit is write.
            return (mode.last?.wholeNumberValue ?? 0) & 2 != 0
        }
        for clause in mode.split(separator: ",") {
            guard let opIndex = clause.firstIndex(where: { $0 == "+" || $0 == "=" }) else { continue }
            let who = clause[..<opIndex]
            let permissions = clause[clause.index(after: opIndex)...]
            if permissions.contains("w"), who.contains("o") || who.contains("a") { return true }
        }
        return false
    }

    private static func findReason(_ args: [String], depth: Int) -> String? {
        if args.contains("-delete") { return "deletes every file it finds (find -delete)" }
        // `find ... -exec rm -rf {} \;` runs a command for each match: check that command too.
        var index = 0
        while index < args.count {
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(args[index]) else { index += 1; continue }
            var inner: [String] = []
            index += 1
            while index < args.count, args[index] != ";", args[index] != "+" { inner.append(args[index]); index += 1 }
            if let found = wordsReason(inner, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func shellReason(_ args: [String], command: ClaudeShellCommand, depth: Int) -> String? {
        // bash <(curl ...), sh -c "$(curl ...)"
        if command.nested.contains(where: startsWithDownloader) { return "downloads a script and runs it straight away" }
        // sh -c '<script>' (also -lc, -ic...)
        if let flag = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c") }), flag + 1 < args.count,
           let found = reason(for: args[flag + 1], depth: depth + 1) {
            return found
        }
        // A script fed on standard input: a here-document or a here-string.
        if let script = command.heredoc, let found = reason(for: script, depth: depth + 1) { return found }
        for redirect in command.redirects where redirect.op == "<<<" {
            if let found = reason(for: redirect.target, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func sshReason(_ args: [String], depth: Int) -> String? {
        // Everything after the host is a command run on the other machine.
        let optionsWithValue = Set("bcDEeFIiJLlmOopQRSWw".map { "-\($0)" })
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-"), positional.isEmpty {
                index += optionsWithValue.contains(arg) ? 2 : 1
            } else {
                positional.append(arg)
                index += 1
            }
        }
        guard positional.count > 1 else { return nil }
        return reason(for: positional.dropFirst().joined(separator: " "), depth: depth + 1)
    }

    /// Checks a command that is already split into words (from `find -exec`).
    private static func wordsReason(_ words: [String], depth: Int) -> String? {
        guard depth <= maxDepth, let resolved = resolve(words) else { return nil }
        return commandReason(name: resolved.name, args: resolved.args, command: ClaudeShellCommand(words: words), depth: depth)
    }

    // MARK: - Rules about how commands are connected

    /// `curl ... | sh`, `wget -qO- ... | bash`, `curl ... | python3`.
    private static func pipesDownloadIntoInterpreter(_ stages: [(name: String, args: [String])?]) -> Bool {
        guard let download = stages.firstIndex(where: { $0.map { downloaders.contains($0.name) } ?? false }) else { return false }
        return stages[(download + 1)...].contains { stage in
            guard let stage else { return false }
            if shells.contains(stage.name) { return true }
            // `python3 parse.py` only reads the download as data; with no script named it runs it.
            return interpreters.contains(stage.name) && stage.args.allSatisfy { $0.hasPrefix("-") }
        }
    }

    private static func startsWithDownloader(_ text: String) -> Bool {
        guard let first = ClaudeShellParser.pipelines(in: text).first?.first, let resolved = resolve(first.words) else { return false }
        return downloaders.contains(resolved.name)
    }

    /// Output sent straight onto a raw disk device, e.g. `> /dev/disk2`.
    private static func redirectReason(_ command: ClaudeShellCommand) -> String? {
        let rawDisk = command.redirects.contains { redirect in
            guard redirect.op.hasPrefix(">") || redirect.op == "<>" else { return false }
            return ["/dev/disk", "/dev/rdisk", "/dev/sd", "/dev/nvme", "/dev/hd"].contains { redirect.target.hasPrefix($0) }
        }
        return rawDisk ? "overwrites a disk directly" : nil
    }

    /// The classic `:(){ :|:& };:` and the same thing with another function name.
    private static func isForkBomb(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.contains("(){") else { return false }
        if compact.contains(":(){:|:&};:") { return true }
        guard let pattern = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\(\)\{\1\|\1&\};?\1"#) else { return false }
        return pattern.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)) != nil
    }
}

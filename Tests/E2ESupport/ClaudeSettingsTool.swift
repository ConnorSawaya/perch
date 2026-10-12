// ClaudeSettingsTool.swift — a tiny command-line tool used only by scripts/e2e-claude.sh.
//
//   claude-settings-tool <config-dir> <helper-path> <backups-dir>
//
// It runs the app's real ClaudeAdapter installer against a throwaway config folder, so the
// end-to-end test hands the real Claude Code exactly the settings file Perch would write into
// ~/.claude/settings.json, without going anywhere near that file. It prints what it found.

import Foundation

@main
enum ClaudeSettingsTool {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: claude-settings-tool <config-dir> <helper-path> <backups-dir>\n".utf8))
            exit(2)
        }
        let adapter = ClaudeAdapter(configDir: URL(fileURLWithPath: arguments[1], isDirectory: true),
                                    helperURL: URL(fileURLWithPath: arguments[2]),
                                    backupsDir: URL(fileURLWithPath: arguments[3], isDirectory: true))
        print("detected version: \(adapter.detectedVersion?.description ?? "none")")
        do {
            print("install: \(try adapter.installHooks())")
        } catch {
            print("install FAILED: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            exit(1)
        }
        let status = adapter.status()
        print("status: \(status.hookStatus.rawValue) — \(status.detail)")
        exit(status.hookStatus == .installed ? 0 : 1)
    }
}

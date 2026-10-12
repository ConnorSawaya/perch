// ReadOnlyTools.swift — the tools the "allow read-only tools automatically" setting covers.
//
// This is the ONE place that list lives. A tool belongs here only if it can do nothing but look
// at files that are already on this Mac: no writing, no running commands, and no network access
// (fetching a web page can leak data through the address, so web tools are deliberately absent).

import Foundation

enum ReadOnlyTools {
    /// Tool names, lower-cased. Names are compared without regard to case.
    static let names: Set<String> = [
        // Claude Code
        "read", "glob", "grep", "ls", "notebookread",
        // Codex
        "read_file", "list_dir", "grep_files", "view_image",
        // Antigravity
        "view_file", "view_file_outline", "view_code_item", "find_by_name", "grep_search",
        // Gemini CLI
        "read_many_files", "list_directory", "search_file_content",
    ]

    static func contains(_ toolName: String) -> Bool {
        names.contains(toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// True when a permission request may be allowed without asking the user.
    /// A request the adapter flagged as dangerous is never auto-allowed, whatever the tool.
    static func mayAutoAllow(_ request: PermissionRequest) -> Bool {
        contains(request.toolName) && !request.isDangerous
    }
}

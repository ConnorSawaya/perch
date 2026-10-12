// SessionHost.swift — the one-word answer to "where is this session running?".
//
// A session started in a terminal has a terminal device and is shown as "CLI". One started from a
// desktop app (the Claude app's Code tab, the ChatGPT app's Codex) has none and is shown as "App".

import Foundation

enum SessionHost {
    case cli
    case app

    init(_ session: Session) {
        self = (session.terminal.tty ?? "").isEmpty ? .app : .cli
    }

    var label: String {
        switch self {
        case .cli: return "CLI"
        case .app: return "App"
        }
    }
}

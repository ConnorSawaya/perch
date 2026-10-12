// main.swift — entry point of the `perch-hook` helper.
//
//   perch-hook --agent <claude|codex|antigravity|gemini> [--channel hook|statusline|notify]
//              [--event <Name>] [--wait] [--timeout <seconds>] [--pid <n>] [--fallback <text>]
//              [-- <extra args>...]
//
// This file only reads the command line; the work is done by HookClient (see HookClient.swift).
// Nothing here can fail loudly: an option that is unknown or has no value is skipped, because a
// hook that prints an error or exits non-zero would get in the agent's way.

import Foundation

/// Turns the command line (without the program name) into options.
func parseOptions(_ arguments: [String]) -> HookClient.Options {
    var options = HookClient.Options()
    var index = 0
    /// The value that follows an option such as `--agent`, if there is one.
    func nextValue() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        switch argument {
        case "--":
            options.extraArgs = Array(arguments[index...])
            index = arguments.count
        case "--wait":
            options.wait = true
        case "--agent":
            options.agent = nextValue() ?? ""
        case "--channel":
            if let value = nextValue(), !value.isEmpty { options.channel = value }
        case "--event":
            options.event = nextValue()
        case "--fallback":
            options.fallback = nextValue()
        case "--timeout":
            // Anything that is not a positive number means "no timeout".
            if let value = nextValue().flatMap(Double.init), value.isFinite, value > 0 { options.timeout = value }
        case "--pid":
            if let value = nextValue().flatMap({ Int32($0) }), value > 0 { options.pidOverride = value }
        default:
            break   // an option from a newer Perch that this build does not know: ignore it
        }
    }
    return options
}

// Writing to a pipe or socket whose other end has gone must fail quietly, not kill the helper.
signal(SIGPIPE, SIG_IGN)
exit(HookClient.run(parseOptions(Array(CommandLine.arguments.dropFirst()))))

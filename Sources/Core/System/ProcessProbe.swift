// ProcessProbe.swift — small, read-only questions about processes on this Mac.
//
// "Is this pid still running?", "which terminal device does it own?", "who started it?" and
// "which app is it running inside?". The session engine uses these to drop cards whose agent has
// quit, and the terminal jumper uses them to find the app to bring forward.
//
// Everything here asks the kernel directly (sysctl / libproc), so nothing is spawned and the
// calls are cheap enough to make from the main thread. Nothing here ever sends a signal.

import AppKit
import Darwin

/// The app a process is running inside (its nearest ancestor that is a running application).
struct HostApp: Equatable {
    var pid: Int32
    var bundleID: String
}

enum ProcessProbe {

    // MARK: Single-process facts

    /// True when a process with this id exists and has not exited. Zombies count as gone.
    static func isAlive(_ pid: Int32) -> Bool {
        guard let info = kernelInfo(pid) else { return false }
        return info.kp_proc.p_stat != zombieState
    }

    /// The terminal device the process is attached to, e.g. "/dev/ttys003". Nil when it has none
    /// (headless runs, GUI apps) or the process is gone.
    static func tty(of pid: Int32) -> String? {
        guard let info = kernelInfo(pid) else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != noDevice else { return nil }
        var buffer = [CChar](repeating: 0, count: 128)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(cString: buffer)
        // The kernel answers "??" for devices it cannot name.
        guard !name.isEmpty, !name.contains("?") else { return nil }
        return "/dev/" + name
    }

    /// The parent process id. Nil when the process is gone or has no parent (pid 0).
    static func parent(of pid: Int32) -> Int32? {
        guard let info = kernelInfo(pid) else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// The process name as the system shows it (the executable's file name). Note that some
    /// agents ship a binary named after its version, so this is not always a friendly name.
    static func name(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        // proc_name can be refused for other users' processes; the kernel record still has a short name.
        guard let info = kernelInfo(pid) else { return nil }
        let short = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return short.isEmpty ? nil : short
    }

    /// Full path of the program the process is running, when the system lets us see it.
    static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// When the process started. Process ids are reused, so "same pid AND same start time" is the
    /// only reliable way to say "still the same process".
    static func startTime(of pid: Int32) -> Date? {
        guard let info = kernelInfo(pid) else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    // MARK: Family tree

    /// The chain of parents, nearest first, ending at launchd (pid 1). Empty when the process is gone.
    static func ancestors(of pid: Int32) -> [Int32] {
        ancestors(of: pid, parentOf: parent(of:))
    }

    /// The same walk with the lookup passed in, so the loop and depth guards can be tested.
    static func ancestors(of pid: Int32, parentOf: (Int32) -> Int32?) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < maxDepth, let next = parentOf(current), next > 0, next != current, !chain.contains(next) {
            chain.append(next)
            current = next
        }
        return chain
    }

    // MARK: Apps

    /// What we need to know about a running application to decide whether it "hosts" a process.
    struct AppFacts: Equatable {
        var bundleID: String?
        /// True for ordinary apps with a Dock icon and windows (not background helpers).
        var isRegular: Bool
    }

    /// The app a process runs inside: the process itself or its nearest ancestor that is a running
    /// application. Ordinary apps win over background helpers, because editors such as VS Code run
    /// their terminals under a helper process whose own bundle id is of no use for jumping.
    static func hostApp(of pid: Int32) -> HostApp? {
        hostApp(of: pid, parentOf: parent(of:), appAt: appFacts(at:))
    }

    /// Bundle identifier of `hostApp(of:)`, e.g. "com.apple.Terminal".
    static func hostBundleID(of pid: Int32) -> String? {
        hostApp(of: pid)?.bundleID
    }

    /// The same search with the lookups passed in, so it can be tested with a made-up process tree.
    static func hostApp(of pid: Int32, parentOf: (Int32) -> Int32?, appAt: (Int32) -> AppFacts?) -> HostApp? {
        guard pid > 0 else { return nil }
        var firstHelper: HostApp?
        for candidate in [pid] + ancestors(of: pid, parentOf: parentOf) {
            guard let facts = appAt(candidate), let bundleID = facts.bundleID, !bundleID.isEmpty else { continue }
            if facts.isRegular { return HostApp(pid: candidate, bundleID: bundleID) }
            if firstHelper == nil { firstHelper = HostApp(pid: candidate, bundleID: bundleID) }
        }
        return firstHelper
    }

    /// Bundle identifier of the app the user is working in right now.
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: Plumbing

    private static let maxDepth = 64
    /// `SZOMB` from <sys/proc.h>: the process has exited but has not been collected by its parent yet.
    private static let zombieState: CChar = 5
    /// `NODEV` from <sys/param.h>: "no controlling terminal".
    private static let noDevice: dev_t = -1

    private static func appFacts(at pid: Int32) -> AppFacts? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return AppFacts(bundleID: app.bundleIdentifier, isRegular: app.activationPolicy == .regular)
    }

    /// The kernel's record for one process, or nil when there is no such process.
    private static func kernelInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let status = sysctl(&query, UInt32(query.count), &info, &size, nil, 0)
        // For a pid that does not exist the call succeeds but writes nothing.
        guard status == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}

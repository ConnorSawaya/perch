// ProcessLiveness.swift — "is the agent's process still running, and is it still the same one?"
//
// Used by housekeeping to drop cards whose agent was killed without a goodbye (a force-quit
// terminal cannot run a "session ended" hook). It only ever asks the system questions; it never
// sends a signal that could affect the process.

import Foundation
import Darwin

enum ProcessLiveness {
    /// Which process a process id refers to, so a recycled id is not mistaken for the old process.
    struct Identity: Equatable {
        /// Start time of the process (seconds since 1970); nil when it could not be read.
        var startedAt: Double?
    }

    /// nil when no process has this id. Otherwise its start time, which tells a recycled process
    /// id apart from the original (nil start time when the system would not say).
    static func identity(of pid: Int32) -> Identity? {
        guard isAlive(pid) else { return nil }
        return Identity(startedAt: startTime(of: pid))
    }

    /// `kill(pid, 0)` delivers nothing; it only reports whether the process exists.
    /// "Not permitted" still means it exists (it belongs to another user), so that counts as alive.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// When the process started, in seconds since 1970, or nil if it cannot be read.
    static func startTime(of pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&query, UInt32(query.count), &info, &size, nil, 0)
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }
}

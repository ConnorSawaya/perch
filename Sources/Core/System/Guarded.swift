// Guarded.swift — a value that two threads may share safely.
//
// Used where background work hands a result back to a waiting caller (running a command-line
// tool, a bounded wait for a script). Every read and write takes a lock.

import Foundation

/// A value shared between two threads, guarded by a lock.
final class Guarded<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

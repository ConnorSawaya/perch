// BriefCache.swift — remembers slow answers for a moment so frequent questions stay cheap.
//
// "Which tab is in front?" takes a script run of 50–200 ms, far too slow to do on the main thread
// every time someone asks. This cache loads each answer on a background queue and hands it out
// like this:
//   - a fresh answer is returned at once;
//   - a slightly old answer is returned at once while a new one is fetched for next time;
//   - with no usable answer, the caller waits a short, fixed time for the fetch. If that is not
//     enough the caller gets nil ("don't know yet") and the answer is kept for the next call.
// So the main thread never waits longer than `waitLimit`, and usually does not wait at all.

import Foundation

final class BriefCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var loadedAt: Date
    }

    private let freshFor: TimeInterval
    private let usableFor: TimeInterval
    private let waitLimit: TimeInterval
    private let queue: DispatchQueue
    private let now: () -> Date

    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    private var loading: Set<Key> = []
    /// Bumped by `removeAll`, so a fetch that started before it cannot put an outdated answer back.
    private var generation = 0

    /// - Parameters:
    ///   - freshFor: seconds an answer is trusted without re-checking.
    ///   - usableFor: seconds an answer may still be handed out while a new one is fetched.
    ///   - waitLimit: the longest a caller is kept waiting when there is no usable answer.
    init(freshFor: TimeInterval, usableFor: TimeInterval, waitLimit: TimeInterval,
         queue: DispatchQueue = .global(qos: .userInitiated), now: @escaping () -> Date = Date.init) {
        self.freshFor = freshFor
        self.usableFor = max(usableFor, freshFor)
        self.waitLimit = waitLimit
        self.queue = queue
        self.now = now
    }

    /// The answer for `key`, fetched with `load` (on a background queue) when needed.
    /// Returns nil when no answer arrived within the wait limit.
    func value(for key: Key, load: @escaping () -> Value) -> Value? {
        condition.lock()
        defer { condition.unlock() }

        if let entry = entries[key] {
            let age = now().timeIntervalSince(entry.loadedAt)
            if age >= 0, age <= freshFor { return entry.value }
            if age >= 0, age <= usableFor {
                startLoading(key, load)
                return entry.value
            }
        }

        startLoading(key, load)
        let deadline = Date().addingTimeInterval(waitLimit)
        while loading.contains(key) {
            if !condition.wait(until: deadline) { break }
        }
        // Still loading means we ran out of time; otherwise the entry was just written.
        return loading.contains(key) ? nil : entries[key]?.value
    }

    /// Forgets everything (used after we changed which tab is in front ourselves).
    func removeAll() {
        condition.lock()
        entries.removeAll()
        generation += 1
        condition.unlock()
    }

    /// Must be called with the lock held.
    private func startLoading(_ key: Key, _ load: @escaping () -> Value) {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        let startedIn = generation
        queue.async { [weak self] in
            let value = load()
            guard let self else { return }
            self.condition.lock()
            if self.generation == startedIn {
                self.entries[key] = Entry(value: value, loadedAt: self.now())
                self.dropExpired()
            }
            self.loading.remove(key)
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    /// Keeps the cache from growing: answers nobody could use any more are thrown away.
    private func dropExpired() {
        guard entries.count > 32 else { return }
        let time = now()
        entries = entries.filter { time.timeIntervalSince($0.value.loadedAt) <= usableFor }
    }
}

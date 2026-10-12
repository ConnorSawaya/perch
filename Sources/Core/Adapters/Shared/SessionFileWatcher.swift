// SessionFileWatcher.swift — watches a set of session files and reports the lines appended to them.
//
// Used by adapters whose agents write session files (Codex rollouts, Gemini CLI chats). It is a
// light timer rather than a file-system event stream, because the files live in dated folders
// that appear over time and a one-second poll of a couple of folders costs next to nothing.
//
// How it keeps the cost down:
//   - when the agent is not installed (`listFiles` returns nil) it only re-checks once a minute;
//   - files that existed before Perch started are not replayed: reading starts at their end;
//   - files untouched for a day are forgotten;
//   - each file is read through a JSONLinesTailer (only new bytes, capped per tick), and the
//     number of tracked files is capped.
//
// All callbacks run on the watcher's own background queue. Adapters parse there and hop to the
// main thread before emitting events.

import Foundation

final class SessionFileWatcher {

    struct Tuning {
        /// Seconds between polls while the agent is installed.
        var interval: TimeInterval = 1.0
        /// Seconds between checks while the agent is not installed.
        var absentInterval: TimeInterval = 60
        /// Files not modified for this long are ignored (and dropped if already tracked).
        var maxAge: TimeInterval = 24 * 60 * 60
        /// At most this many files are tracked; the most recently modified win.
        var maxFiles = 48
        var maxBytesPerFilePerTick = 512 * 1024
        /// True: a file that appears after the first poll is read from its first line (it is a new
        /// session). False: every file is followed from its current end, whenever it is found.
        var readNewFilesFromStart = true
    }

    /// What the watcher tells its owner.
    enum Change {
        /// A file is now being followed. `existedAtStart` is true for files found on the very first
        /// poll: their existing content is skipped and only later additions are reported.
        case discovered(URL, existedAtStart: Bool, modifiedAt: Date)
        /// Complete new lines, in file order.
        case lines(URL, [String])
        /// The file went stale or disappeared and is no longer followed.
        case dropped(URL)
    }

    private let tuning: Tuning
    private let listFiles: () -> [URL]?
    private let onChange: (Change) -> Void
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var tailers: [String: JSONLinesTailer] = [:]
    private var hasPolledOnce = false
    private var currentInterval: TimeInterval = 0

    /// - Parameters:
    ///   - listFiles: the candidate files right now, or nil when the agent is not installed. Called on `queue`.
    ///   - onChange: called on `queue`.
    init(tuning: Tuning = Tuning(), queue: DispatchQueue, listFiles: @escaping () -> [URL]?, onChange: @escaping (Change) -> Void) {
        self.tuning = tuning
        self.queue = queue
        self.listFiles = listFiles
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.schedule(after: 0, interval: self.tuning.interval)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.tailers.removeAll()
            self?.hasPolledOnce = false
        }
    }

    /// Asks a running watcher to poll straight away instead of waiting for its next tick (used when
    /// the owner has just learned about a new file while the watcher was idling).
    func pollSoon() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.schedule(after: 0, interval: self.tuning.interval)
        }
    }

    /// Runs one poll right now on the calling thread, for callers that drive the watcher by hand
    /// instead of starting its timer (the tests do).
    func pollNow() { poll() }

    private func schedule(after delay: TimeInterval, interval: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.poll() }
        currentInterval = interval
        timer = source
        source.resume()
    }

    private func poll() {
        guard let candidates = listFiles() else {
            // Agent not installed: forget everything and slow right down.
            for path in tailers.keys { onChange(.dropped(URL(fileURLWithPath: path))) }
            tailers.removeAll()
            hasPolledOnce = false
            if timer != nil, currentInterval != tuning.absentInterval {
                schedule(after: tuning.absentInterval, interval: tuning.absentInterval)
            }
            return
        }
        if timer != nil, currentInterval != tuning.interval { schedule(after: tuning.interval, interval: tuning.interval) }

        let now = Date()
        let fm = FileManager.default
        // Newest first, so the cap keeps the files most likely to be live.
        let fresh: [(url: URL, modified: Date)] = candidates.compactMap { url in
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) <= tuning.maxAge else { return nil }
            return (url, modified)
        }.sorted { $0.modified > $1.modified }.prefix(tuning.maxFiles).map { $0 }

        let wanted = Set(fresh.map { $0.url.path })
        for path in tailers.keys where !wanted.contains(path) {
            tailers[path] = nil
            onChange(.dropped(URL(fileURLWithPath: path)))
        }
        for (url, modified) in fresh where tailers[url.path] == nil {
            let existedAtStart = !hasPolledOnce || !tuning.readNewFilesFromStart
            tailers[url.path] = JSONLinesTailer(url: url, startAtEnd: existedAtStart, maxBytesPerRead: tuning.maxBytesPerFilePerTick)
            onChange(.discovered(url, existedAtStart: existedAtStart, modifiedAt: modified))
        }
        hasPolledOnce = true
        for (url, _) in fresh {
            guard let tailer = tailers[url.path] else { continue }
            let lines = tailer.readNewLines()
            if !lines.isEmpty { onChange(.lines(url, lines)) }
        }
    }
}

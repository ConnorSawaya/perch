// UsageEngine.swift — all the numbers: rate limits, tokens, estimated cost, daily activity.
//
// This is the one class other modules use (through UsageEngineProtocol). It ties the pieces of
// this folder together and is the only one that touches UsageStore:
//
//   agents' session files ──► UsageScanWorker (background queue) ──► token totals per day
//   live events (observe) ──► LimitBook        ──► rate-limit windows          ──► UsageStore
//   live events, decisions ─► ActivityTracker  ──► daily activity tally
//
// Threading: everything in this file runs on the main thread, except the scan itself, which is
// handed to `scanQueue` and comes back with plain values. The store is only ever changed on the
// main thread.
//
// No network, no keychain, no tokens: every number comes from files the agents already write or
// from events they send to Perch. Dollar amounts are estimates at list prices (UsagePricing).

import Foundation
import Combine

/// The latest numbers one live session reported about itself (from its status line).
struct LiveSessionReading: Equatable {
    var model: String?
    /// 0...100.
    var contextPercent: Double?
    /// The agent's own cost figure for the session, when it gives one.
    var costUSD: Double?
    var updatedAt: Date
}

final class UsageEngine: UsageEngineProtocol {
    /// Called on the main thread when a rate-limit window first reaches the "warn at" percentage
    /// in its current period, and only while the usage-warnings setting is on. The app can hook a
    /// sound or a notification to it.
    var onLimitWarning: ((AgentKind, RateWindow) -> Void)?

    /// How often the clock-driven parts run: active-time tally, expired windows, a new day.
    static let heartbeatSeconds: TimeInterval = 30
    /// Changes are saved this long after the first of them, so a burst of events is one write.
    private static let saveDelay: TimeInterval = 2
    /// A finished turn means new tokens in a transcript; rescan then, but not more often than this.
    private static let turnRefreshGap: TimeInterval = 20
    private static let maxReadings = 200

    private let store: UsageStore
    private let settings: AppSettings
    private var locations: UsageLocations
    private let clock: () -> Date
    /// Nil means "the Mac's current time zone", looked up each time it is needed.
    private let fixedTimeZone: TimeZone?
    private let fileAge: ((String) -> Int64?)?

    private let worker = UsageScanWorker()
    private let scanQueue = DispatchQueue(label: "local.perch.usage.scan", qos: .utility)
    private let saveQueue = DispatchQueue(label: "local.perch.usage.save", qos: .utility)
    /// Goes up when saved stats are cleared: a scan that began before then stops and its result is dropped.
    private let epoch = ScanEpoch()

    // Main-thread state.
    private var limits = LimitBook()
    private var tracker = ActivityTracker()
    private var summaries: [AgentKind: TokenSummary] = [:]
    private var installed: Set<AgentKind> = []
    private var readings: [String: LiveSessionReading] = [:]
    private var didLoadSavedState = false
    private var isStarted = false
    private var scanInFlight = false
    private var scanRequestedAgain = false
    private var limitsNeedSaving = false
    private var savedTrackerRevision = 0
    private var pendingSave: DispatchWorkItem?
    private var lastPublishedDay = ""
    private var lastTurnRefresh = Date.distantPast
    private var refreshTimer: Timer?
    private var heartbeatTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    // MARK: Setting up

    /// The app's initialiser: the agents' real folders and Perch's real data folder.
    convenience init(store: UsageStore, settings: AppSettings) {
        self.init(store: store, settings: settings, locations: .standard)
    }

    /// For tests: custom folders, an injectable clock and a fixed time zone.
    /// - Parameters:
    ///   - claudeProjectsDir: a folder laid out like ~/.claude/projects, or nil for none.
    ///   - codexHome: a folder laid out like ~/.codex, or nil for none.
    ///   - geminiHome: a folder laid out like ~/.gemini, or nil for none.
    ///   - dataDir: where the ledger and the two JSON files go.
    ///   - fileAge: overrides file creation times (ms since 1970); see UsageScanner.scan.
    convenience init(store: UsageStore, settings: AppSettings, claudeProjectsDir: URL?, codexHome: URL?, geminiHome: URL? = nil,
                     dataDir: URL, clock: @escaping () -> Date = { Date() }, timeZone: TimeZone? = nil,
                     fileAge: ((String) -> Int64?)? = nil) {
        let locations = UsageLocations(claudeProjectsDirs: claudeProjectsDir.map { [$0] } ?? [], codexHomes: codexHome.map { [$0] } ?? [],
                                       geminiHome: geminiHome, dataDir: dataDir)
        self.init(store: store, settings: settings, locations: locations, clock: clock, timeZone: timeZone, fileAge: fileAge)
    }

    init(store: UsageStore, settings: AppSettings, locations: UsageLocations, clock: @escaping () -> Date = { Date() },
         timeZone: TimeZone? = nil, fileAge: ((String) -> Int64?)? = nil) {
        self.store = store
        self.settings = settings
        self.locations = locations
        self.clock = clock
        self.fixedTimeZone = timeZone
        self.fileAge = fileAge
    }

    deinit {
        refreshTimer?.invalidate()
        heartbeatTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private var timeZone: TimeZone { fixedTimeZone ?? .autoupdatingCurrent }
    private var zone: LocalDays { LocalDays(timeZone: timeZone) }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: UsageEngineProtocol — start and stop

    func start() {
        onMain { [self] in
            guard !isStarted else { return }
            isStarted = true
            loadSavedStateIfNeeded()
            publish()
            scheduleRefreshTimer(minutes: settings.usageRefreshMinutes)
            let heartbeat = Timer(timeInterval: Self.heartbeatSeconds, repeats: true) { [weak self] _ in self?.heartbeat() }
            RunLoop.main.add(heartbeat, forMode: .common)
            heartbeatTimer = heartbeat
            watchSettings()
            // A new day or a new time zone moves every "today" boundary: build the totals again.
            for name in [Notification.Name.NSCalendarDayChanged, Notification.Name.NSSystemTimeZoneDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshNow()
                })
            }
            refreshNow()
        }
    }

    func stop() {
        onMain { [self] in
            guard isStarted else { return }
            isStarted = false
            refreshTimer?.invalidate()
            refreshTimer = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            subscriptions.removeAll()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if settings.collectActivityStats { tracker.advance(to: clock(), in: zone) }
            save(wait: true)
        }
    }

    /// Seconds between automatic rescans, or nil while the engine is stopped.
    var refreshIntervalSeconds: TimeInterval? { refreshTimer?.timeInterval }

    private func scheduleRefreshTimer(minutes: Double) {
        refreshTimer?.invalidate()
        let clamped = min(60, max(1, minutes.isFinite ? minutes : 5))
        let timer = Timer(timeInterval: clamped * 60, repeats: true) { [weak self] _ in self?.refreshNow() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Reacts to the settings this module honours. `@Published` reports a change just BEFORE the
    /// property holds the new value, so the handlers either use the value they are given or run
    /// one step later on the main queue.
    private func watchSettings() {
        settings.$usageRefreshMinutes.dropFirst().removeDuplicates()
            .sink { [weak self] minutes in self?.scheduleRefreshTimer(minutes: minutes) }
            .store(in: &subscriptions)
        settings.$collectActivityStats.dropFirst().removeDuplicates()
            .sink { [weak self] isOn in
                // Switched off: stop timing the sessions that are running. Saved days stay until cleared.
                if !isOn { self?.tracker.forgetLiveSessions() }
            }
            .store(in: &subscriptions)
        // Turning an agent on or off changes what is scanned and shown.
        Publishers.MergeMany(settings.$claudeEnabled.dropFirst(), settings.$codexEnabled.dropFirst(),
                             settings.$antigravityEnabled.dropFirst(), settings.$geminiEnabled.dropFirst())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshNow() } }
            .store(in: &subscriptions)
        // The note mentions limits above the warning level, and cost only while cost is shown.
        // (Cost is always computed; `showCostEstimates` only decides what the views and the note say.)
        Publishers.Merge3(settings.$usageWarnings.dropFirst().map { _ in () }, settings.$warnAtPercent.dropFirst().map { _ in () },
                          settings.$showCostEstimates.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.publish() } }
            .store(in: &subscriptions)
    }

    // MARK: UsageEngineProtocol — scanning files

    /// Rescans the agents' files in the background and updates the store when done. Requests
    /// that arrive while a scan is running are folded into one follow-up scan.
    func refreshNow() {
        onMain { [self] in
            loadSavedStateIfNeeded()
            if scanInFlight {
                scanRequestedAgain = true
            } else {
                startScan()
            }
        }
    }

    private func startScan() {
        scanInFlight = true
        if !store.isRefreshing { store.isRefreshing = true }
        let startedIn = epoch.value
        let request = UsageScanWorker.Request(
            locations: locations,
            agents: Set(AgentKind.allCases.filter(settings.isEnabled)),
            fileAge: fileAge,
            now: clock,
            timeZone: { [fixedTimeZone] in fixedTimeZone ?? .autoupdatingCurrent },
            shouldStop: { [epoch] in epoch.value != startedIn },
            progress: { [weak self] partial in
                DispatchQueue.main.async {
                    guard let self, self.epoch.value == startedIn else { return }
                    self.summaries = partial
                    self.publish()
                }
            })
        scanQueue.async { [weak self, worker] in
            let result = worker.run(request)
            DispatchQueue.main.async { self?.finishScan(result, startedIn: startedIn) }
        }
    }

    private func finishScan(_ result: UsageScanWorker.Result, startedIn: Int) {
        scanInFlight = false
        if epoch.value == startedIn {
            summaries = result.summaries
            installed = result.installed
            for report in result.limits where limits.merge(report) { limitsNeedSaving = true }
            store.lastRefresh = clock()
            publish()
            scheduleSave()
            Log.debug("Usage scan: \(result.summaryLine).", "usage")
        }
        if scanRequestedAgain {
            scanRequestedAgain = false
            startScan()
        } else if store.isRefreshing {
            store.isRefreshing = false
        }
    }

    // MARK: UsageEngineProtocol — live events

    /// Takes in one event from the session engine: fresh rate-limit numbers go straight to the
    /// store, and every event feeds the daily activity tally.
    func observe(_ event: NormalizedEvent) {
        onMain { [self] in
            loadSavedStateIfNeeded()
            guard settings.isEnabled(event.agent) else { return }
            let now = clock()
            learnLocations(from: event)

            let sessionKey = Session.makeID(event.agent, event.sessionID)
            switch event.event {
            case .usageUpdated(let contextPercent, let windows, let model, let costUSD):
                remember(LiveSessionReading(model: model, contextPercent: contextPercent, costUSD: costUSD, updatedAt: now), for: sessionKey)
                if !windows.isEmpty, limits.merge(LimitReport(agent: event.agent, windows: windows, planName: nil, capturedAt: now)) {
                    limitsNeedSaving = true
                    publish()
                    scheduleSave()
                }
            case .sessionEnded:
                readings[sessionKey] = nil
            case .turnFinished:
                // Do not wait for the timer: the turn that just ended is what the user wants to see counted.
                if isStarted, abs(now.timeIntervalSince(lastTurnRefresh)) >= Self.turnRefreshGap {
                    lastTurnRefresh = now
                    refreshNow()
                }
            default:
                break
            }

            guard settings.collectActivityStats else { return }
            tracker.observe(event, at: now, in: zone)
            publishActivity(now: now)
        }
    }

    func recordDecision(_ decision: Decision, for request: PendingRequest) {
        onMain { [self] in
            loadSavedStateIfNeeded()
            guard settings.collectActivityStats, settings.isEnabled(request.agent) else { return }
            let now = clock()
            tracker.recordDecision(decision, for: request, at: now, in: zone)
            publishActivity(now: now)
        }
    }

    /// What a live session last said about itself, e.g. `latestReading(agent: .claude, sessionID: id)?.contextPercent`.
    /// Main thread only.
    func latestReading(agent: AgentKind, sessionID: String) -> LiveSessionReading? {
        readings[Session.makeID(agent, sessionID)]
    }

    private func remember(_ reading: LiveSessionReading, for key: String) {
        var merged = reading
        // A payload can leave a field out (context is unknown right after a compaction); keep the last known value.
        if let old = readings[key] {
            merged.model = reading.model ?? old.model
            merged.contextPercent = reading.contextPercent ?? old.contextPercent
            merged.costUSD = reading.costUSD ?? old.costUSD
        }
        readings[key] = merged
        if readings.count > Self.maxReadings, let oldest = readings.min(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            readings[oldest.key] = nil
        }
    }

    /// A menu-bar app does not inherit the shell's CLAUDE_CONFIG_DIR or CODEX_HOME, but the hook
    /// helper forwards them. When an event shows an agent keeps its files somewhere else, that
    /// folder is scanned too from the next refresh on.
    private func learnLocations(from event: NormalizedEvent) {
        guard locations.learnsFromEvents else { return }
        switch event.agent {
        case .claude:
            guard let custom = event.context.env["CLAUDE_CONFIG_DIR"], !custom.isEmpty else { return }
            let projects = URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
            if !locations.claudeProjectsDirs.contains(where: { $0.standardizedFileURL == projects.standardizedFileURL }) {
                locations.claudeProjectsDirs.append(projects)
            }
        case .codex:
            guard let custom = event.context.env["CODEX_HOME"], !custom.isEmpty else { return }
            let home = URL(fileURLWithPath: custom, isDirectory: true)
            if !locations.codexHomes.contains(where: { $0.standardizedFileURL == home.standardizedFileURL }) {
                locations.codexHomes.append(home)
            }
        case .antigravity, .gemini:
            break
        }
    }

    // MARK: UsageEngineProtocol — clearing

    /// Deletes what this module saved (the ledger, the saved limits, the activity tally) and empties
    /// the store. The agents' own files are never touched, so while the engine is running the next
    /// scan, which starts at once, brings back the token history the agents still keep.
    func clearSavedStats() {
        onMain { [self] in
            epoch.advance()
            pendingSave?.cancel()
            pendingSave = nil
            limits = LimitBook()
            tracker = ActivityTracker()
            summaries = [:]
            readings = [:]
            limitsNeedSaving = false
            savedTrackerRevision = 0
            didLoadSavedState = true
            store.usage = [:]
            store.activityDays = []
            store.lastRefresh = nil

            // Deleting waits its turn behind any save or scan already under way.
            let files = locations
            saveQueue.async { UsageFiles.remove([files.limitsURL, files.activityURL]) }
            scanQueue.async { [worker] in
                worker.closeLedger()
                UsageFiles.remove(files.ownFiles)
            }
            if isStarted { refreshNow() }
        }
    }

    // MARK: Clock-driven work

    /// Runs every 30 seconds while started (tests call it directly): adds up active time, clears
    /// windows whose reset time has passed, and rebuilds the totals when a new day has begun.
    func heartbeat() {
        loadSavedStateIfNeeded()
        let now = clock()
        if settings.collectActivityStats {
            tracker.advance(to: now, in: zone)
            publishActivity(now: now)
        }
        if !lastPublishedDay.isEmpty, zone.day(of: now) != lastPublishedDay {
            refreshNow()
        }
        publish()
    }

    // MARK: Writing the store

    /// Rebuilds `store.usage` from the last scan's totals and the current limits.
    private func publish() {
        let now = clock()
        lastPublishedDay = zone.day(of: now)
        var usage: [AgentKind: AgentUsage] = [:]
        var newWarnings: [(agent: AgentKind, window: RateWindow)] = []
        for agent in AgentKind.allCases where settings.isEnabled(agent) {
            let summary = summaries[agent]
            let windows = limits.windows(for: agent, at: now)
            let plan = limits.planName(for: agent)
            // An agent that is not installed and has left no trace is simply not listed.
            guard summary != nil || !windows.isEmpty || plan != nil || installed.contains(agent) else { continue }

            var warnings: [RateWindow] = []
            if settings.usageWarnings {
                warnings = windows.filter { $0.usedPercent >= settings.warnAtPercent }
                newWarnings += limits.windowsNeedingWarning(for: agent, threshold: settings.warnAtPercent, at: now).map { (agent, $0) }
            }

            var entry = AgentUsage(agent: agent)
            entry.windows = windows
            entry.planName = plan
            entry.today = summary?.today ?? TokenTotals()
            entry.days = summary?.days ?? []
            entry.allTime = summary?.allTime ?? TokenTotals()
            entry.updatedAt = limits.lastUpdate(for: agent) ?? store.lastRefresh
            entry.note = UsageNotes.note(
                UsageNotes.Facts(agent: agent, hasTokens: (summary?.allTime.messages ?? 0) > 0,
                                 unpricedModels: summary?.unpricedModels ?? [], hasLimits: !windows.isEmpty,
                                 limitsUpdatedAt: limits.lastUpdate(for: agent),
                                 expiredLabels: limits.expiredLabels(for: agent, at: now), warnings: warnings,
                                 showsCost: settings.showCostEstimates),
                now: now, timeZone: timeZone)
            usage[agent] = entry
        }
        if store.usage != usage { store.usage = usage }
        // Tell the app about limits that just crossed the warning level, once the store shows them.
        for warning in newWarnings {
            limitsNeedSaving = true         // which periods were warned about is saved with the limits
            Log.info("\(warning.agent.displayName): the \(warning.window.label) is at \(Int(warning.window.usedPercent.rounded()))%.", "usage")
            onLimitWarning?(warning.agent, warning.window)
        }
        if limitsNeedSaving { scheduleSave() }
    }

    /// Rebuilds `store.activityDays` (at most 90 small values, so this is cheap enough to do per event).
    private func publishActivity(now: Date) {
        let days = tracker.recentDays(at: now, in: zone)
        if store.activityDays != days { store.activityDays = days }
        if tracker.revision != savedTrackerRevision { scheduleSave() }
    }

    // MARK: Saving and loading Perch's own files

    private func loadSavedStateIfNeeded() {
        guard !didLoadSavedState else { return }
        didLoadSavedState = true
        if let saved = UsageFiles.read(LimitBook.self, from: locations.limitsURL) { limits = saved }
        if let saved = UsageFiles.read(SavedActivity.self, from: locations.activityURL) {
            tracker = ActivityTracker(saved: saved.days)
            let days = tracker.recentDays(at: clock(), in: zone)
            if store.activityDays != days { store.activityDays = days }
        }
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.save(wait: false) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes whatever changed since the last save. `wait` blocks until the files are on disk.
    private func save(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        var writes: [() -> Void] = []
        if limitsNeedSaving {
            limitsNeedSaving = false
            let snapshot = limits
            let url = locations.limitsURL
            writes.append { UsageFiles.write(snapshot, to: url) }
        }
        if tracker.revision != savedTrackerRevision {
            savedTrackerRevision = tracker.revision
            let snapshot = SavedActivity(days: tracker.daysToSave(at: clock(), in: zone))
            let url = locations.activityURL
            writes.append { UsageFiles.write(snapshot, to: url) }
        }
        guard !writes.isEmpty else { return }
        let work = { writes.forEach { $0() } }
        if wait { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
    }

    /// Saves pending changes now and waits for the files. For the app's shutdown path and for tests.
    func flush() {
        if Thread.isMainThread { save(wait: true) } else { DispatchQueue.main.sync { save(wait: true) } }
    }
}

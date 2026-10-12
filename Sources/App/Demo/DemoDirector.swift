// DemoDirector.swift — runs demo mode: a looping, pretend story that makes the notch feel alive
// without any coding agent running.
//
// How the pieces fit:
//   DemoCast    the pretend sessions                      (who is on stage)
//   DemoScript  the list of steps                         (what happens, in order)
//   DemoStage   how one step changes the stores           (the engine's part, for demo data only)
//   DemoUsage   pretend usage numbers
//   DemoDirector (this file) starts and stops it all, moves from step to step on a timer, and
//               takes the user's answers to demo requests.
//
// How the app uses it:
//   let demo = DemoDirector(env: env)
//   demo.start()                      // AppActions.setDemo(true)
//   demo.stop()                       // AppActions.setDemo(false) — only demo data is removed
//   if demo.handle(request, decision) { return }   // in AppActions.resolve, before the engine
//   if demo.dismiss(session) { return }            // in AppActions.dismiss, before the engine
//
// Everything here runs on the main thread, like all code that touches the stores.

import Foundation

final class DemoDirector {
    private let env: AppEnv
    private let autoAdvance: Bool
    private let now: () -> Date
    private let stage: DemoStage
    private var timer: Timer?

    /// The story, in order. After the last step it starts again from the first.
    let steps: [DemoStep]
    /// True between `start()` and `stop()`.
    private(set) var isRunning = false
    /// Index into `steps` of the step that happens next.
    private(set) var stepIndex = 0
    /// How many times the whole story has played through.
    private(set) var loopCount = 0
    /// 1 = normal pace. 2 plays twice as fast. Takes effect from the next step.
    var speed: Double = 1

    /// Called for moments that would make a sound in real use (a request arrives, a task
    /// finishes...). Connect it to the app's sound player if the demo should be audible.
    var onCue: ((SoundCue) -> Void)? {
        get { stage.onCue }
        set { stage.onCue = newValue }
    }

    /// What the usage store held that was not put there by the demo. Restored on `stop()`.
    private var realUsage: UsageSnapshot?
    /// What the demo last wrote to the usage store, to notice when something else writes to it.
    private var lastWrittenUsage: UsageSnapshot?

    /// - Parameters:
    ///   - autoAdvance: False turns the timer off, so steps only happen when `advance()` is
    ///     called. Tests use this to walk through the story one step at a time.
    ///   - now: The clock. Tests can pass a fixed one.
    init(env: AppEnv, autoAdvance: Bool = true, steps: [DemoStep] = DemoScript.steps, now: @escaping () -> Date = Date.init) {
        self.env = env
        self.autoAdvance = autoAdvance
        self.steps = steps
        self.now = now
        self.stage = DemoStage(env: env, now: now)
    }

    deinit { timer?.invalidate() }

    // MARK: - Start and stop

    /// Fills the stores with the opening scene and starts the story. Does nothing if already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        stepIndex = 0
        loopCount = 0
        env.ui.isDemo = true
        realUsage = UsageSnapshot(of: env.usage)
        lastWrittenUsage = nil
        stage.raiseCurtain()
        publishUsage()
        scheduleNext()
    }

    /// Stops the story and removes everything the demo added. Real sessions, real requests, real
    /// activity lines and the real usage numbers are left exactly as they are.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        stage.clear()
        restoreUsage()
        env.ui.isDemo = false
    }

    // MARK: - The user's actions

    /// Call this first when the user answers a request. Returns true when the request belonged
    /// to the demo (it has then been dealt with); false means "not mine — pass it to the engine".
    @discardableResult
    func handle(_ request: PendingRequest, _ decision: Decision) -> Bool {
        guard isRunning else { return false }
        return stage.resolve(request, with: decision, byUser: true)
    }

    /// Call this first when the user dismisses a session card. Returns true when it was a demo card.
    @discardableResult
    func dismiss(_ session: Session) -> Bool {
        guard isRunning else { return false }
        return stage.dismiss(sessionID: session.id)
    }

    // MARK: - Stepping

    /// Makes the next step of the story happen right now and returns it. The timer calls this;
    /// tests call it directly. Returns nil when the demo is not running.
    @discardableResult
    func advance() -> DemoStep? {
        guard isRunning, !steps.isEmpty else { return nil }
        let step = steps[stepIndex % steps.count]
        step.actions.forEach(stage.perform)
        stage.tickUsage(activeSeconds: Int(step.wait.rounded()))
        publishUsage()
        stepIndex += 1
        if stepIndex >= steps.count {
            stepIndex = 0
            loopCount += 1
        }
        return step
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = nil
        guard autoAdvance, isRunning, !steps.isEmpty else { return }
        let wait = steps[stepIndex % steps.count].wait / max(speed, 0.01)
        let next = Timer(timeInterval: max(0.01, wait), repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.advance()
            self.scheduleNext()
        }
        // `.common` keeps the story moving while a menu is open or a slider is being dragged.
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    // MARK: - Usage numbers

    /// Writes the demo's usage numbers to the store. If something else wrote there since the last
    /// time (the real usage scanner refreshing), that is remembered as the newest real data.
    private func publishUsage() {
        let current = UsageSnapshot(of: env.usage)
        if let lastWrittenUsage, current != lastWrittenUsage { realUsage = current }
        env.usage.usage = stage.usage.usage
        env.usage.activityDays = stage.usage.activityDays
        env.usage.lastRefresh = now()
        lastWrittenUsage = UsageSnapshot(of: env.usage)
    }

    private func restoreUsage() {
        let current = UsageSnapshot(of: env.usage)
        // If the store no longer holds what the demo wrote, real numbers are already back in place.
        if let lastWrittenUsage, current == lastWrittenUsage {
            realUsage?.write(to: env.usage)
        }
        realUsage = nil
        lastWrittenUsage = nil
    }
}

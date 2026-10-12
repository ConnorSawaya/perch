// SoundEngine.swift — plays Perch's sound cues, respecting the user's sound settings.
//
// The session engine calls `play(.done)`, `play(.needsApproval)` and so on at the right moments.
// This class then:
//   1. reads the current settings (master switch, per-event switches, quiet hours, volume, pack),
//   2. asks SoundPolicy whether the cue should sound and how loud,
//   3. asks SoundRateLimiter whether it is too soon after the last one,
//   4. hands the sound to a SoundOutput, which returns at once — nothing here ever blocks.
// `preview` is for the "try it" buttons in Settings: it skips steps that would mute it.
//
// ("Stay quiet while my terminal is in front" is decided by the session engine, which knows the
// session; it asks TerminalJumper.isFrontmost before calling `play`.)

import Foundation

final class SoundEngine: SoundPlaying {
    private let settings: AppSettings
    private let output: SoundOutput
    private let now: () -> Date
    private var limiter = SoundRateLimiter()

    convenience init(settings: AppSettings) {
        self.init(settings: settings, output: SpeakerOutput())
    }

    /// For tests: a recording `output` and a controllable clock.
    init(settings: AppSettings, output: SoundOutput, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.output = output
        self.now = now
    }

    func play(_ cue: SoundCue) {
        onMain { self.handle(cue, preview: false) }
    }

    func preview(_ cue: SoundCue) {
        onMain { self.handle(cue, preview: true) }
    }

    /// Decides and, if the answer is yes, plays. Returns the decision (handy for tests and logs).
    /// Main thread only, because it reads AppSettings.
    @discardableResult
    func handle(_ cue: SoundCue, preview: Bool) -> SoundDecision {
        let time = now()
        let snapshot = SoundSettings(settings, at: time)
        var decision = SoundPolicy.decide(cue, settings: snapshot, preview: preview)
        // Previews skip the rate limiter: the user is pressing the button on purpose, and a new
        // sound replaces the one still playing anyway.
        if case .play = decision, !preview, !limiter.admit(cue, at: time) {
            decision = .skip(.tooSoon)
        }
        if case .play(let gain) = decision {
            output.play(SoundPolicy.source(for: cue, pack: snapshot.pack), gain: gain)
        }
        return decision
    }

    /// Settings live on the main thread; callers on other threads are moved there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

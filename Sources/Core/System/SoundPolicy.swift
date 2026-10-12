// SoundPolicy.swift — decides WHETHER a sound should play, and how loud. No audio happens here.
//
// Keeping the decision apart from the playing means every rule can be tested as plain logic:
//   - the master switch, the per-event switches and quiet hours (SoundPolicy.decide);
//   - the volume slider's curve (SoundPolicy.gain);
//   - "a burst of events must not stack ten sounds" (SoundRateLimiter).

import Foundation

/// The settings sounds depend on, copied out of AppSettings at one moment in time.
struct SoundSettings: Equatable {
    var enabled = true
    /// The volume slider, 0…1.
    var volume = 0.6
    var pack = SoundPack.chime
    var onDone = true
    var onApproval = true
    var onQuestion = true
    var onError = true
    var onStart = false
    /// True when quiet hours are on and `date` falls inside them.
    var inQuietHours = false

    init() {}

    /// Reads the live settings. Call on the main thread (AppSettings is main-thread only).
    init(_ settings: AppSettings, at date: Date = Date()) {
        enabled = settings.soundsEnabled
        volume = settings.volume
        pack = settings.soundPack
        onDone = settings.soundOnDone
        onApproval = settings.soundOnApproval
        onQuestion = settings.soundOnQuestion
        onError = settings.soundOnError
        onStart = settings.soundOnStart
        inQuietHours = settings.inQuietHours(at: date)
    }
}

enum SoundDecision: Equatable {
    /// Play it, with this gain (0…1).
    case play(gain: Float)
    case skip(SoundSkipReason)
}

enum SoundSkipReason: Equatable {
    case soundsOff      // the master switch
    case cueOff         // this kind of event is switched off
    case quietHours
    case volumeZero
    case tooSoon        // the rate limiter said no
}

enum SoundPolicy {

    /// Should `cue` play, given the user's settings? `preview` is for the Settings "try it" buttons:
    /// it ignores every mute (switches, quiet hours) but still follows the volume slider.
    static func decide(_ cue: SoundCue, settings: SoundSettings, preview: Bool = false) -> SoundDecision {
        if !preview {
            if !settings.enabled { return .skip(.soundsOff) }
            if !isCueEnabled(cue, in: settings) { return .skip(.cueOff) }
            if settings.inQuietHours { return .skip(.quietHours) }
        }
        let gain = gain(forVolume: settings.volume)
        return gain > 0 ? .play(gain: gain) : .skip(.volumeZero)
    }

    /// Which per-event switch governs each cue. The "allowed" / "denied" clicks belong to
    /// approvals; a reminder has no switch of its own here (the engine only sends one when
    /// reminders are turned on).
    static func isCueEnabled(_ cue: SoundCue, in settings: SoundSettings) -> Bool {
        switch cue {
        case .sessionStart: return settings.onStart
        case .needsApproval, .approved, .denied: return settings.onApproval
        case .needsAnswer: return settings.onQuestion
        case .done: return settings.onDone
        case .failed: return settings.onError
        case .reminder: return true
        }
    }

    /// Turns the volume slider (0…1) into a gain. Loudness is heard on a curve, so a straight
    /// slider has no quiet settings; the bottom quarter is therefore squared, and the rest is linear.
    static func gain(forVolume volume: Double) -> Float {
        guard volume.isFinite else { return 0 }
        let v = min(max(volume, 0), 1)
        let knee = 0.25
        return Float(v < knee ? v * v / knee : v)
    }

    /// Which sound to play for a cue in a pack.
    static func source(for cue: SoundCue, pack: SoundPack) -> SoundSource {
        pack == .system ? .system(name: SoundSynth.systemSoundName(for: cue), fallback: cue) : .synthesized(pack: pack, cue: cue)
    }
}

/// Stops bursts of events from stacking sounds on top of each other.
///
/// Rules, checked in this order:
///   1. The same cue is not repeated within its own interval (several approvals queued at once
///      chime once; a session failing over and over thuds once in a while).
///   2. While another sound is still fresh (`gap`), only a MORE important cue may cut in.
///   3. No more than `burstLimit` sounds in any `burstWindow` seconds, whatever they are.
struct SoundRateLimiter {
    var gap: TimeInterval = 0.6
    var burstLimit = 4
    var burstWindow: TimeInterval = 10

    private var lastPlayed: [SoundCue: Date] = [:]
    private var recent: [(cue: SoundCue, at: Date)] = []

    init() {}

    /// Seconds before the same cue may sound again.
    static func repeatInterval(for cue: SoundCue) -> TimeInterval {
        switch cue {
        case .failed: return 20
        case .reminder: return 5
        case .sessionStart, .needsApproval, .needsAnswer, .done, .approved, .denied: return 1.5
        }
    }

    /// Calls for the user's attention outrank news, which outranks feedback for their own clicks.
    static func priority(of cue: SoundCue) -> Int {
        switch cue {
        case .needsApproval, .needsAnswer, .failed: return 3
        case .done, .reminder: return 2
        case .approved, .denied: return 1
        case .sessionStart: return 0
        }
    }

    /// True when `cue` may play at `time`; the play is then remembered. False = stay silent.
    mutating func admit(_ cue: SoundCue, at time: Date) -> Bool {
        recent.removeAll { time.timeIntervalSince($0.at) >= burstWindow || $0.at > time }

        if let last = lastPlayed[cue], abs(time.timeIntervalSince(last)) < Self.repeatInterval(for: cue) { return false }
        if let previous = recent.last, time.timeIntervalSince(previous.at) < gap,
           Self.priority(of: cue) <= Self.priority(of: previous.cue) { return false }
        if recent.count >= burstLimit { return false }

        lastPlayed[cue] = time
        recent.append((cue, time))
        return true
    }
}

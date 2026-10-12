// SoundSynth.swift — Perch's sounds, made from scratch in code.
//
// There are no audio files in the app. Each cue is a tiny tune: a few notes, described once in
// `SoundSynth.tune(for:)` (a rising pair for "done", a triple knock for "needs approval", a low
// thud for "failed"…). A sound pack is a way of playing those tunes — which instrument, how fast,
// how high — so the three packs share their melodies but sound clearly different:
//   chime  — bell-like, ringing notes
//   arcade — short square-wave blips, like an old game console
//   soft   — slow, low, pure tones
// `render` turns a tune into samples (numbers between -1 and 1, 44,100 per second), and
// `wavFile` wraps samples in a WAV header so the system can play them straight from memory.

import Foundation

/// One note of a tune. Pitches are in semitones above the pack's base note; times are in beats.
struct TuneNote: Equatable {
    var semitones: Double
    var startBeat: Double
    var beats: Double
    /// When set, the pitch slides to this many semitones by the end of the note (used for thuds).
    var slideTo: Double?
    var loudness: Double = 1
}

struct Tune: Equatable {
    var notes: [TuneNote]
    /// Overall level, 0…1. Feedback for the user's own clicks is quieter than a call for attention.
    var level: Double
    /// True for the low "something went wrong" thud, which every pack plays with a dull voice.
    var isThud = false
}

/// The instrument a pack plays its notes with.
enum SynthVoice: Equatable {
    case bell, square, pure, thud
}

struct PackStyle: Equatable {
    var voice: SynthVoice
    /// Frequency of "0 semitones", in Hz.
    var baseFrequency: Double
    /// Length of one beat in seconds.
    var beat: Double
    /// How long a note keeps sounding relative to its written length (above 1 = notes ring into each other).
    var ring: Double
}

enum SoundSynth {
    static let sampleRate = 44_100.0
    /// The loudest any sample may be. Kept below 1 so nothing clips.
    static let peakLimit: Float = 0.9

    // MARK: Tunes

    static func tune(for cue: SoundCue) -> Tune {
        switch cue {
        case .sessionStart:   // one light note
            return Tune(notes: [note(7, at: 0, beats: 1.5)], level: 0.55)
        case .needsApproval:  // a gentle triple knock on one pitch
            return Tune(notes: [note(7, at: 0, beats: 1), note(7, at: 1.1, beats: 1), note(7, at: 2.2, beats: 1.7)], level: 1)
        case .needsAnswer:    // high, low, high: the lilt of a question
            return Tune(notes: [note(9, at: 0, beats: 1), note(4, at: 1, beats: 1), note(11, at: 2, beats: 1.8)], level: 1)
        case .done:           // a rising pair, the second note held
            return Tune(notes: [note(0, at: 0, beats: 1), note(7, at: 1, beats: 2.2)], level: 0.95)
        case .failed:         // two falling low thuds
            return Tune(notes: [TuneNote(semitones: -15, startBeat: 0, beats: 2, slideTo: -27),
                                TuneNote(semitones: -20, startBeat: 1.5, beats: 2.6, slideTo: -32, loudness: 0.9)],
                        level: 1, isThud: true)
        case .approved:       // a quick step up
            return Tune(notes: [note(12, at: 0, beats: 0.6), note(16, at: 0.6, beats: 1)], level: 0.5)
        case .denied:         // a quick step down
            return Tune(notes: [note(5, at: 0, beats: 0.7), note(0, at: 0.7, beats: 1.2)], level: 0.5)
        case .reminder:       // the same note twice, unhurried
            return Tune(notes: [note(4, at: 0, beats: 1.2), note(4, at: 2.4, beats: 1.4)], level: 0.7)
        }
    }

    /// How each synthesized pack plays. The "system" pack has no style: it uses macOS's own sounds.
    static func style(for pack: SoundPack) -> PackStyle? {
        switch pack {
        case .chime: return PackStyle(voice: .bell, baseFrequency: 523.25, beat: 0.13, ring: 2.2)    // C5
        case .arcade: return PackStyle(voice: .square, baseFrequency: 659.25, beat: 0.075, ring: 0.9) // E5
        case .soft: return PackStyle(voice: .pure, baseFrequency: 392.0, beat: 0.17, ring: 1.8)      // G4
        case .system: return nil
        }
    }

    /// The built-in macOS sound that stands in for each cue in the "system" pack.
    static func systemSoundName(for cue: SoundCue) -> String {
        switch cue {
        case .sessionStart: return "Pop"
        case .needsApproval: return "Ping"
        case .needsAnswer: return "Submarine"
        case .done: return "Glass"
        case .failed: return "Basso"
        case .approved: return "Tink"
        case .denied: return "Bottle"
        case .reminder: return "Purr"
        }
    }

    // MARK: Rendering

    /// The samples for one cue in one pack. Nil for the "system" pack.
    static func samples(for cue: SoundCue, pack: SoundPack) -> [Float]? {
        guard let style = style(for: pack) else { return nil }
        return render(tune(for: cue), style: style)
    }

    /// Seconds a tune lasts when played in a style.
    static func duration(of tune: Tune, style: PackStyle) -> Double {
        let end = tune.notes.map { $0.startBeat * style.beat + noteLength($0, tune, style) }.max() ?? 0
        return end + tail
    }

    static func render(_ tune: Tune, style: PackStyle) -> [Float] {
        let count = Int((duration(of: tune, style: style) * sampleRate).rounded(.up))
        guard count > 0 else { return [] }
        var mix = [Double](repeating: 0, count: count)
        let voice = tune.isThud && style.voice != .square ? SynthVoice.thud : style.voice

        for note in tune.notes {
            let length = noteLength(note, tune, style)
            let first = Int(note.startBeat * style.beat * sampleRate)
            let total = Int(length * sampleRate)
            let startFrequency = frequency(note.semitones, style)
            let endFrequency = frequency(note.slideTo ?? note.semitones, style)
            var phase = 0.0
            for i in 0..<total where first + i < count {
                let progress = Double(i) / Double(max(total - 1, 1))
                // Slide in pitch-space (equal steps sound even), and add up phase so the slide has no clicks.
                let current = startFrequency * pow(endFrequency / startFrequency, progress)
                phase += 2 * .pi * current / sampleRate
                let time = Double(i) / sampleRate
                mix[first + i] += note.loudness * wave(voice, phase) * envelope(voice, time: time, length: length)
            }
        }
        return normalised(mix, to: Double(peakLimit) * min(max(tune.level, 0), 1))
    }

    // MARK: Pieces of the instrument

    /// Silence kept after the last note so the ending is never cut short.
    private static let tail = 0.02

    private static func note(_ semitones: Double, at beat: Double, beats: Double) -> TuneNote {
        TuneNote(semitones: semitones, startBeat: beat, beats: beats)
    }

    private static func noteLength(_ note: TuneNote, _ tune: Tune, _ style: PackStyle) -> Double {
        // Thuds are the same length in every pack: they are a thump, not a melody.
        tune.isThud ? note.beats * 0.13 : note.beats * style.beat * style.ring
    }

    private static func frequency(_ semitones: Double, _ style: PackStyle) -> Double {
        style.baseFrequency * pow(2, semitones / 12)
    }

    /// One cycle shape per voice, as a function of phase. Roughly within -1…1.
    private static func wave(_ voice: SynthVoice, _ phase: Double) -> Double {
        switch voice {
        case .bell:
            // A fundamental with a few quieter overtones gives a struck-metal colour.
            return sin(phase) + 0.38 * sin(2 * phase) + 0.16 * sin(3 * phase) + 0.07 * sin(4.2 * phase)
        case .square:
            // A square wave built from its first odd harmonics: the retro buzz without harsh aliasing.
            return 0.55 * (sin(phase) + sin(3 * phase) / 3 + sin(5 * phase) / 5 + sin(7 * phase) / 7)
        case .pure:
            return sin(phase) + 0.1 * sin(2 * phase)
        case .thud:
            // Overtones make a low note audible on small laptop speakers.
            return sin(phase) + 0.5 * sin(2 * phase) + 0.22 * sin(3 * phase)
        }
    }

    /// How loud a note is `time` seconds after it starts (0…1): a quick rise, then each voice's own fade.
    private static func envelope(_ voice: SynthVoice, time: Double, length: Double) -> Double {
        let attack: Double, body: Double
        switch voice {
        case .bell: attack = 0.004; body = exp(-time / (length * 0.28))
        case .square: attack = 0.003; body = 1
        case .pure: attack = 0.03; body = exp(-time / (length * 0.4))
        case .thud: attack = 0.004; body = exp(-time / (length * 0.22))
        }
        let rise = min(time / attack, 1)
        // Every note ends with a short fade so it never stops with a click.
        let release = min((length - time) / 0.012, 1)
        return max(0, min(rise, release)) * body
    }

    /// Scales the mix so its loudest sample is exactly `peak`.
    private static func normalised(_ mix: [Double], to peak: Double) -> [Float] {
        let loudest = mix.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return [Float](repeating: 0, count: mix.count) }
        let gain = peak / loudest
        return mix.map { Float($0 * gain) }
    }

    // MARK: WAV

    /// A complete WAV file (16-bit, mono) holding `samples`.
    static func wavFile(_ samples: [Float], sampleRate: Double = SoundSynth.sampleRate) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                                   // size of the format block
        append16(1)                                    // 1 = plain PCM
        append16(1)                                    // channels
        append32(Int(sampleRate))
        append32(Int(sampleRate) * bytesPerSample)     // bytes per second
        append16(bytesPerSample)                       // bytes per frame
        append16(bytesPerSample * 8)                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            withUnsafeBytes(of: Int16(clamped * Float(Int16.max)).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

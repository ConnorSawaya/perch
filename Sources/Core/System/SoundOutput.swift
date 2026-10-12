// SoundOutput.swift — the only place in Perch that actually makes a noise.
//
// `SoundEngine` decides what to play; a `SoundOutput` plays it. Tests replace the output with a
// recorder, so they can check every decision in silence.
//
// `SpeakerOutput` is the real one. It is deliberately gentle with the audio hardware:
//   - Nothing audio-related exists until the first sound is needed, and the sound object is let
//     go as soon as it finishes. Perch never keeps an audio engine running and never opens a
//     microphone. This matters with Bluetooth headphones: an app that merely holds the audio
//     device open can pull AirPods away from a phone call, and opening an input switches them to
//     the low-quality call mode.
//   - A new sound replaces one that is still playing, so sounds never pile up.
// Synthesized cues are rendered once on a background queue, kept as small in-memory WAV files and
// played with NSSound, which follows the user's chosen output device by itself.

import AppKit

enum SoundSource: Equatable {
    /// One of Perch's own cues, generated in code.
    case synthesized(pack: SoundPack, cue: SoundCue)
    /// A sound that ships with macOS (e.g. "Glass"). If it cannot be found, `fallback` is played
    /// from the chime pack instead.
    case system(name: String, fallback: SoundCue)
}

protocol SoundOutput: AnyObject {
    /// Starts playing and returns immediately. `gain` is 0…1.
    func play(_ source: SoundSource, gain: Float)
}

final class SpeakerOutput: NSObject, SoundOutput, NSSoundDelegate {
    private let renderQueue = DispatchQueue(label: "local.perch.sound.render", qos: .userInitiated)
    /// Rendered WAV files by "pack/cue". Only touched on `renderQueue`.
    private var rendered: [String: Data] = [:]
    /// The sound playing right now. Only touched on the main thread.
    private var current: NSSound?

    func play(_ source: SoundSource, gain: Float) {
        switch source {
        case .synthesized(let pack, let cue):
            renderQueue.async { [weak self] in
                guard let self, let file = self.wavFile(pack: pack, cue: cue) else { return }
                DispatchQueue.main.async { self.start(NSSound(data: file), gain: gain) }
            }
        case .system(let name, let fallback):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let sound = NSSound(named: name) {
                    self.start(sound, gain: gain)
                } else {
                    self.play(.synthesized(pack: .chime, cue: fallback), gain: gain)
                }
            }
        }
    }

    /// The WAV file for a cue, rendered on first use.
    private func wavFile(pack: SoundPack, cue: SoundCue) -> Data? {
        let key = "\(pack.rawValue)/\(cue.rawValue)"
        if let ready = rendered[key] { return ready }
        guard let samples = SoundSynth.samples(for: cue, pack: pack), !samples.isEmpty else { return nil }
        let file = SoundSynth.wavFile(samples)
        rendered[key] = file
        return file
    }

    private func start(_ sound: NSSound?, gain: Float) {
        guard let sound else { return }
        current?.stop()
        // System sounds are shared objects; one may still be playing from last time.
        if sound.isPlaying { sound.stop() }
        sound.volume = min(max(gain, 0), 1)
        sound.delegate = self
        current = sound.play() ? sound : nil
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        // Let go of the sound so nothing keeps the audio device busy while we are quiet.
        if sound === current { current = nil }
    }
}

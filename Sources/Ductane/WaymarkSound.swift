//
//  WaymarkSound.swift
//  Ductane
//

import Foundation

/// **What a ``Waymark`` sounds like as it appears** (``Waymark/Look/sound``): made here, not recorded, so a game ships
/// nothing for it and an editor can play it. Mono, at ``sampleRate``, peaking below full scale; load it into an
/// ``AudioEngine`` with `load(_:samples:sampleRate:)` and play it without a place — it is heard, not located.
public nonisolated enum WaymarkSound {

    public static let sampleRate: Double = 48_000

    /// The sound's samples; none for ``Waymark/Look/Sound/none``.
    public static func samples(_ sound: Waymark.Look.Sound) -> [Float] {
        switch sound {
        case .bell: bell()
        case .chime: chime()
        case .sonar: sonar()
        case .pulse: pulse()
        case .none: []
        }
    }

    /// A struck note: its pitch with a quiet octave over it, an instant's rise and a ring that dies over `ring` seconds.
    private static func note(_ t: Float, pitch: Float, from start: Float, ring: Float) -> Float {
        let local = t - start
        guard local > 0 else { return 0 }
        let envelope = min(local / 0.006, 1) * exp(-local / ring)
        return (sin(2 * .pi * pitch * local) + 0.25 * sin(2 * .pi * pitch * 2.01 * local)) * envelope
    }

    private static func made(seconds: Double, peak: Float, _ at: (Float) -> Float) -> [Float] {
        let samples = (0..<Int(sampleRate * seconds)).map { at(Float($0) / Float(sampleRate)) }
        let most = samples.map(abs).max() ?? 0
        return most > 0 ? samples.map { $0 / most * peak } : samples
    }

    /// Two soft notes a fifth apart, the second a breath after the first, ringing out over most of a second.
    static func bell() -> [Float] {
        made(seconds: 0.9, peak: 0.32) { t in
            note(t, pitch: 988, from: 0, ring: 0.22) + 0.8 * note(t, pitch: 1_480, from: 0.07, ring: 0.22)
        }
    }

    /// One clear high note, quickly gone.
    static func chime() -> [Float] {
        made(seconds: 0.7, peak: 0.3) { t in note(t, pitch: 1_760, from: 0, ring: 0.16) }
    }

    /// A sonar's ping, softer at its start, and its echo a third of a second later.
    static func sonar() -> [Float] {
        made(seconds: 1.1, peak: 0.32) { t in
            func ping(_ start: Float) -> Float {
                let local = t - start
                guard local > 0 else { return 0 }
                return sin(2 * .pi * 1_180 * local) * min(local / 0.02, 1) * exp(-local / 0.18)
            }
            return ping(0) + 0.35 * ping(0.34)
        }
    }

    /// A low swell, rising in pitch as it grows and falling away.
    static func pulse() -> [Float] {
        made(seconds: 0.8, peak: 0.34) { t in
            // Its pitch climbs from 200 to 340 Hz over 0.3 s: the phase is that climb's integral.
            let envelope = min(t / 0.22, 1) * exp(-max(t - 0.22, 0) / 0.18)
            let phase = 2 * Float.pi * (200 * t + 140 * (t < 0.3 ? t * t / 0.6 : t - 0.15))
            return (sin(phase) + 0.5 * sin(phase * 1.5)) * envelope
        }
    }
}

//
//  SoundReach.swift
//  Ductane
//

import simd

/// **How far a sound carries, set per sound**: full near it, fading to silence at its reach.
///
/// A world needs a generator heard from 60 m beside a drip heard from 5, and one distance curve for every loop cannot
/// hold both — the near spatializer's inverse law makes everything a small sound, the range curve everything a large
/// one. So a sound given a reach is levelled by this instead: **full within a tenth of its reach (at most a metre), then
/// falling as the square of how far it is towards the reach, and nothing past it** — the shape a light's reach has, and
/// what an author setting one expects: at half its reach a sound is a quarter as loud (−12 dB), at its reach it is gone,
/// so a sound never leaks into a part of the world it was not placed for. The editors' "min and max distance" and
/// "attenuation radius" are the same idea.
public nonisolated enum SoundReach {

    /// The reaches a sound may have, in metres.
    public static let range: ClosedRange<Float> = 0.5...2_000

    /// A reach kept within ``range``; anything not a number is the smallest.
    public static func clamped(_ reach: Float) -> Float {
        reach.isFinite ? min(max(reach, range.lowerBound), range.upperBound) : range.lowerBound
    }

    /// How near is full volume: a tenth of the reach, at most a metre.
    public static func nearDistance(reach: Float) -> Float { min(clamped(reach) * 0.1, 1) }

    /// **How much of a sound is heard `distance` metres away, 0…1.**
    public static func gain(atDistance distance: Float, reach: Float) -> Float {
        let reach = clamped(reach), near = nearDistance(reach: reach)
        guard distance.isFinite else { return 0 }
        if distance <= near { return 1 }
        if distance >= reach { return 0 }
        let t = (distance - near) / (reach - near)
        return (1 - t) * (1 - t)
    }

    /// A sound at a place with a level and a reach: what a voice plays at, heard from somewhere.
    struct Placed: Sendable {
        var position: SIMD3<Float>
        var volume: Float
        var reach: Float
        func level(heardFrom listener: SIMD3<Float>) -> Float {
            volume * SoundReach.gain(atDistance: simd_distance(position, listener), reach: reach)
        }
    }
}

//
//  LightningBolt.swift
//  Ductane
//

import simd

/// **The shape of a lightning strike** (2026-11-16): a jagged trunk from the cloud base to where it lands — or, for one that
/// stays in the clouds, along under them — with thinner branches forking off it, made from the strike's own number so
/// every player sees the same bolt. ``WeatherRenderer/drawLightning(_:into:frameSlot:viewProjection:eye:time:fogDensity:pixelAngle:cloudBase:landing:)``
/// draws it as glowing ribbons for the half second the strike flickers.
public nonisolated struct LightningBolt: Sendable, Equatable {
    /// One straight piece: its ends, how wide its core is (metres), and how bright against the trunk (1). The core is
    /// thin — a bolt's channel is centimetres across, and wider it drew a near strike as a fat beam (2026-11-20); the
    /// shader keeps it at least a pixel or two, so a far one still reads.
    public struct Segment: Sendable, Equatable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var width: Float
        public var brightness: Float
    }

    public var segments: [Segment]

    /// **The bolt of `strike`**: from `cloudBase` metres up down to `landing` — a renderer's choice of where it lands, the
    /// tallest thing near a close strike or the ground under a far one — or, in the clouds, a kilometre or two along under
    /// their base.
    ///
    /// **Shaped as lightning forms (2026-11-20)**: a stepped leader — short straight pieces, each turned sharply from the
    /// last, the whole wandering yet homing on where it lands — with branches forking down off its upper part, forking
    /// again, fading toward their tips. A line broken by midpoint displacement, as it was first made, stayed nearly
    /// straight seen from the ground: its turns shrink with each halving, so it never kinks at the scale a bolt is seen at.
    public static func make(_ strike: Weather.Strike, cloudBase: Float, landing: SIMD3<Float>) -> LightningBolt {
        var random = SplitMix(seed: UInt64(strike.seed) &+ 0x5EED)
        var segments: [Segment] = []
        let start: SIMD3<Float>, end: SIMD3<Float>
        if strike.inCloud {
            let angle = random.unit() * 2 * .pi
            let half = 400 + random.unit() * 900
            let along = SIMD3(cos(angle), 0, sin(angle)) * half
            let height = cloudBase + 50 + random.unit() * 250
            let middle = SIMD3(strike.position.x, height, strike.position.y)
            start = middle - along
            end = middle + along + SIMD3(0, (random.unit() - 0.5) * 200, 0)
        } else {
            start = SIMD3(landing.x + (random.unit() - 0.5) * 500, max(cloudBase, landing.y + 200),
                          landing.z + (random.unit() - 0.5) * 500)
            end = landing
        }
        let span = simd_distance(start, end)
        // About one step every 45 m of the bolt: a kilometre and a half is some thirty-odd turns.
        let steps = max(Int(span / 45), 12)
        let trunk = leader(from: start, to: end, steps: steps, kink: 0.75, random: &random)
        append(trunk, width: strike.inCloud ? 0.5 : 0.35, brightness: 1, taper: 0, to: &segments)
        // **Branches**: all the way down, most from the upper part, heading down (or, in the clouds, along) and away,
        // thinner and dimmer, a share forking again — and each fading toward its tip, as a branch the return stroke never
        // reached does. Down to near the ground, so a strike close by, whose top is out of sight, still forks where it is
        // seen (2026-11-20).
        let top = trunk.count - 3
        for i in 1..<max(top, 2) {
            let low = Float(i) / Float(trunk.count)
            // The chance is per length of channel (one in three every 22 m near the top), so how finely it is drawn
            // changes nothing.
            let per = simd_distance(trunk[i - 1], trunk[i]) / 22
            guard random.unit() < (strike.inCloud ? 0.3 : 0.3 - 0.18 * low) * per else { continue }
            let point = trunk[i]
            let onward = simd_normalize(trunk[min(i + 1, trunk.count - 1)] - point + 1e-5)
            let away = simd_normalize(SIMD3(random.unit() - 0.5, 0, random.unit() - 0.5) + 1e-4)
            let down: Float = strike.inCloud ? (random.unit() - 0.5) * 0.3 : -(0.9 + random.unit() * 1.1)
            let heading = simd_normalize(onward * 0.6 + away * 0.8 + SIMD3(0, down, 0))
            let length = span * (0.1 + random.unit() * 0.32) * (1 - Float(i) / Float(trunk.count) * 0.5)
            let branch = leader(from: point, to: point + heading * length, steps: max(Int(length / 22), 6),
                                kink: 0.55, random: &random)
            append(branch, width: 0.2, brightness: 0.5, taper: 0.8, to: &segments)
            for j in 1..<max(branch.count - 2, 2) where random.unit() < 0.16 * simd_distance(branch[j - 1], branch[j]) / 15 {
                let from = branch[j]
                let side = simd_normalize(SIMD3(-heading.z, 0, heading.x) * (random.unit() < 0.5 ? -1 : 1) * 0.7
                                          + heading * 0.6 + SIMD3(0, down * 0.8, 0))
                let twigLength = length * (0.2 + random.unit() * 0.3)
                let twig = leader(from: from, to: from + side * twigLength, steps: max(Int(twigLength / 18), 4),
                                  kink: 0.55, random: &random)
                append(twig, width: 0.12, brightness: 0.28 * (1 - Float(j) / Float(branch.count)), taper: 0.85,
                       to: &segments)
            }
        }
        return LightningBolt(segments: segments)
    }

    /// **A stepped leader from `a` to `b`**: `steps` straight pieces, each the way still to go shared over the steps
    /// left — so it always arrives — turned off that line by up to about `kink` radians, a turn that partly carries on to
    /// the next piece so the path wanders rather than shivers. Then **each piece is a smaller leader of its own**, kinked
    /// as sharply at its own size — lightning is as crooked close to as from afar, so a strike near enough that only its
    /// last stretch is in view is still a zigzag, not a line with a bend (2026-11-20).
    static func leader(from a: SIMD3<Float>, to b: SIMD3<Float>, steps: Int, kink: Float,
                       random: inout SplitMix) -> [SIMD3<Float>] {
        let coarse = stepped(from: a, to: b, steps: steps, kink: kink, random: &random)
        var fine: [SIMD3<Float>] = [coarse[0]]
        for i in 1..<coarse.count {
            let piece = simd_distance(coarse[i - 1], coarse[i])
            let parts = min(max(Int(piece / 8), 2), 6)
            fine += stepped(from: coarse[i - 1], to: coarse[i], steps: parts, kink: kink * 1.2, random: &random).dropFirst()
        }
        return fine
    }

    /// One level of a leader: `steps` kinked pieces from `a` that always arrive at `b`.
    static func stepped(from a: SIMD3<Float>, to b: SIMD3<Float>, steps: Int, kink: Float,
                        random: inout SplitMix) -> [SIMD3<Float>] {
        var points = [a]
        var p = a
        var drift = SIMD2<Float>(0, 0)
        for i in 0..<steps {
            let left = steps - i
            if left == 1 { points.append(b); break }
            let base = (b - p) / Float(left)
            let length = simd_length(base)
            guard length > 1e-4 else { points.append(b); break }
            let forward = base / length
            var across = simd_cross(forward, SIMD3(0, 1, 0))
            if simd_length(across) < 1e-3 { across = SIMD3(1, 0, 0) }
            across = simd_normalize(across)
            let other = simd_normalize(simd_cross(forward, across))
            // Mostly small turns, now and then a sharp one — lightning's angles are not evenly spread.
            let sharp: Float = random.unit() < 0.18 ? 2.2 : 1
            let turn = SIMD2(random.unit() - 0.5, random.unit() - 0.5) * 2 * kink * sharp
            drift = drift * 0.45 + turn
            p += base + (across * drift.x + other * drift.y * 0.7) * length
            points.append(p)
        }
        return points
    }

    /// The pieces between `points`, dimming by `taper` (0 none, 1 to nothing) from the first to the last.
    static func append(_ points: [SIMD3<Float>], width: Float, brightness: Float, taper: Float,
                       to segments: inout [Segment]) {
        guard points.count > 1 else { return }
        for i in 1..<points.count {
            let along = Float(i - 1) / Float(max(points.count - 2, 1))
            segments.append(Segment(a: points[i - 1], b: points[i], width: width * (1 - taper * along * 0.5),
                                    brightness: brightness * (1 - taper * along)))
        }
    }

    /// A small, fast, seeded generator — SplitMix64.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// 0..<1.
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }
}

public nonisolated extension Weather.Strike {
    /// **How bright its bolt is `seconds` after it**, 0…1: the flash's three flickers, at full whatever the distance — a
    /// bolt is seen however far off it struck, its light on the world fades with distance (``flash(after:seenFrom:)``).
    func boltBrightness(after seconds: Double) -> Float {
        guard seconds >= 0, seconds < Weather.flashLength else { return 0 }
        let t = Float(seconds)
        var bright: Float = 0
        for (start, height) in [(Float(0), Float(1)), (0.09, 0.55), (0.24, 0.8)] where t >= start {
            bright = max(bright, height * exp(-(t - start) * 10))
        }
        return bright
    }
}

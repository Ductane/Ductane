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
    /// One straight piece: its ends, how wide it is (metres), and how bright against the trunk (1).
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
        let trunk = jagged(from: start, to: end, depth: 7, roughness: 0.22, random: &random)
        append(trunk, width: strike.inCloud ? 2 : 1.4, brightness: 1, to: &segments)
        // **Branches**: off the trunk's upper part, heading down and away, thinner and dimmer, a few forking again.
        let span = simd_distance(start, end)
        for (i, point) in trunk.enumerated() where i > 2 && i < trunk.count * 3 / 4 {
            guard random.unit() < 0.14 else { continue }
            let away = simd_normalize(SIMD3(random.unit() - 0.5, 0, random.unit() - 0.5) + 1e-4)
            let down: Float = strike.inCloud ? (random.unit() - 0.5) * 0.4 : -(0.5 + random.unit() * 0.6)
            let length = span * (0.08 + random.unit() * 0.2)
            let tip = point + simd_normalize(away + SIMD3(0, down, 0)) * length
            let branch = jagged(from: point, to: tip, depth: 5, roughness: 0.25, random: &random)
            append(branch, width: 0.7, brightness: 0.45, to: &segments)
            if random.unit() < 0.35, branch.count > 4 {
                let from = branch[branch.count / 2]
                let twig = jagged(from: from, to: from + simd_normalize(SIMD3(-away.z, down, away.x)) * length * 0.4,
                                  depth: 4, roughness: 0.25, random: &random)
                append(twig, width: 0.4, brightness: 0.25, to: &segments)
            }
        }
        return LightningBolt(segments: segments)
    }

    /// A line from `a` to `b` broken by midpoint displacement into `2^depth` pieces, each moved across by up to
    /// `roughness` of its length.
    static func jagged(from a: SIMD3<Float>, to b: SIMD3<Float>, depth: Int, roughness: Float,
                       random: inout SplitMix) -> [SIMD3<Float>] {
        var points = [a, b]
        for _ in 0..<depth {
            var next: [SIMD3<Float>] = [points[0]]
            for i in 1..<points.count {
                let p = points[i - 1], q = points[i]
                let d = q - p
                let length = simd_length(d)
                var across = simd_cross(d, SIMD3(0, 1, 0))
                if simd_length(across) < 1e-4 { across = SIMD3(1, 0, 0) }
                across = simd_normalize(across)
                let other = simd_normalize(simd_cross(d, across) + 1e-6)
                let shift = across * (random.unit() - 0.5) * 2 + other * (random.unit() - 0.5)
                next.append((p + q) / 2 + shift * length * roughness)
                next.append(q)
            }
            points = next
        }
        return points
    }

    static func append(_ points: [SIMD3<Float>], width: Float, brightness: Float, to segments: inout [Segment]) {
        for i in 1..<points.count {
            segments.append(Segment(a: points[i - 1], b: points[i], width: width, brightness: brightness))
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

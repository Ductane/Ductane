//
//  GroundFog.swift
//  Ductane
//

import Metal
import simd

/// **Fog that lies on the ground** (2026-11-16): mist pooling low in hollows and over water, thinning with height — thick
/// in fog weather, rising through the night to be thickest just after sunrise and burnt off by late morning, more after
/// rain, blown away by a strong wind. ``Weather/groundFogDensity(hour:)`` says how thick it is at a moment; ``FogFloor``
/// says where it pools; ``VolumetricFog`` draws it, lit by the sun through gaps and glowing round lights.
///
/// **A world sets its own** — how much (a swamp's standing mist, a desert's none), how high it lies and its colour — and
/// the weather and the hour decide when it comes, as Ultra Dynamic Sky and Enviro set height fog.
public nonisolated struct GroundFog: Sendable, Equatable, Codable {
    /// How much, 0 none … 3 three times the engine's: what the weather and the hour give, scaled.
    public var amount: Float
    /// How high it lies, metres: it thins to a third this far above its floor.
    public var height: Float
    /// Its colour, linear: lit by the sky and the sun as it is.
    public var colour: SIMD3<Float>

    public init(amount: Float = 1, height: Float = 6, colour: SIMD3<Float> = GroundFog.mist) {
        self.amount = amount.isFinite ? min(max(amount, Self.amounts.lowerBound), Self.amounts.upperBound) : 1
        self.height = height.isFinite ? min(max(height, Self.heights.lowerBound), Self.heights.upperBound) : 6
        self.colour = all(colour .>= 0) && all(colour .<= 1) ? colour : Self.mist
    }

    public static let amounts: ClosedRange<Float> = 0...3
    public static let heights: ClosedRange<Float> = 1...40
    /// A cool white mist.
    public static let mist = SIMD3<Float>(0.86, 0.89, 0.93)
    /// **How thick the thickest ground fog is at its floor**, per metre: about seventy-five metres seen through.
    public static let thickest: Float = 0.04

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroundFog()
        self.init(amount: (try? c.decodeIfPresent(Float.self, forKey: .amount)) ?? d.amount,
                  height: (try? c.decodeIfPresent(Float.self, forKey: .height)) ?? d.height,
                  colour: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .colour)) ?? d.colour)
    }
}

public nonisolated extension Weather {
    /// **How thick ground fog is at its floor at `hour`** (0…24 on the world's clock), per metre: the weather's fog, the
    /// dawn's mist and the wet after rain, the thickest counting for most, thinned by wind — and never thinner than the rain
    /// falling makes it; thinned by dust, and scaled by the world's ``GroundFog/amount``. 0 for none.
    func groundFogDensity(hour: Float) -> Float {
        guard groundFog.amount > 0 else { return 0 }
        let s = settings
        let foggy = min(max(s.fogDensity / Weather.fogDensities.upperBound, 0), 1)
        let dawn = Self.dawnMist(hour: hour)
        let wet = min(max(wetness, 0), 1)
        // The thickest of the three counts for most, the others add a little.
        let parts = [foggy, dawn * 0.12, wet * 0.2].sorted(by: >)
        let base = min(parts[0] + parts[1] * 0.3 + parts[2] * 0.15, 1)
        let calm = 1 - Self.smooth(4, 13, s.windSpeed)
        // **Falling rain greys the air whatever the wind does** (2026-11-21): the wind blows lying mist away, not the rain.
        // Without it a storm, whose wind clears the mist, drew clearer than a shower.
        let falling = s.snow ? 0 : min(max(s.precipitation, 0), 1) * Self.rainHaze
        return max(base * calm, falling) * (1 - min(max(s.dust, 0), 1)) * groundFog.amount * GroundFog.thickest
    }

    /// How much of the thickest ground fog the heaviest rain makes on its own — a downpour's grey a few hundred metres off.
    internal static let rainHaze: Float = 0.3

    /// **The dawn's mist**, 0…1 by the hour: building from evening through the night, thickest just after sunrise, burnt
    /// off by late morning, none through the afternoon.
    internal static func dawnMist(hour: Float) -> Float {
        guard hour.isFinite else { return 0 }
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        if h >= 6.5, h < 11 { return 1 - smooth(6.5, 10.5, h) }
        if h >= 11, h < 19 { return 0 }
        // 19:00 → 6:30, rising.
        let t = (h >= 19 ? h - 19 : h + 5) / 11.5
        return t * t
    }

    internal static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// **Where ground fog pools** (2026-11-16): the ground smoothed over tens of metres, so fog lies ``GroundFog/height``
/// over the smoothed ground — deeper in a hollow, whose floor is below it, thinner on a rise above it — and thicker over
/// water. Made from a world's heights once, and again when the ground changes; ``texture(device:)`` is what
/// ``VolumetricFog`` reads.
public nonisolated struct FogFloor: Sendable, Equatable {
    /// The smoothed heights, metres above ``base``, row by row from the corner at ``corner``.
    public var heights: [Float]
    /// How much of each point is over water, 0…1, smoothed the same way.
    public var water: [Float]
    /// Points a side.
    public var side: Int
    /// The corner's x and z, and the map's size, metres.
    public var corner: SIMD2<Float>
    public var size: Float
    /// The height the map's heights count from, metres — kept apart so half precision holds them.
    public var base: Float

    /// The most points a side the map keeps: fog pools over tens of metres, never by the metre.
    public static let largestSide = 128
    /// How far the ground is smoothed, metres.
    public static let reach: Float = 30

    /// **The floor over a square heightfield** — `side` × `side` heights row by row along x, then z, `spacing` metres
    /// apart, its corner at `corner`. `water` gives each point's water level where water lies over it.
    public init(heights ground: [Float], side n: Int, spacing: Float, corner: SIMD2<Float>, water: [Float?]? = nil) {
        precondition(ground.count == n * n && n >= 2, "a square heightfield")
        let size = spacing * Float(n - 1)
        let m = min(n, Self.largestSide)
        // Down to `m` a side, the surface at each point: the water's level where it is over the ground.
        var surface = [Float](repeating: 0, count: m * m), wet = [Float](repeating: 0, count: m * m)
        for z in 0..<m {
            for x in 0..<m {
                let gx = Int((Float(x) / Float(m - 1) * Float(n - 1)).rounded())
                let gz = Int((Float(z) / Float(m - 1) * Float(n - 1)).rounded())
                let i = gz * n + gx
                var h = ground[i].isFinite ? ground[i] : 0
                if let level = water?[i] ?? nil, level > h { h = level; wet[z * m + x] = 1 }
                surface[z * m + x] = h
            }
        }
        let cell = size / Float(m - 1)
        let radius = max(Int((Self.reach / max(cell, 1e-3)).rounded()), 1)
        // Two box blurs each way: near enough a Gaussian.
        let smooth = Self.blur(Self.blur(surface, side: m, radius: radius), side: m, radius: radius)
        let lowest = smooth.min() ?? 0
        heights = smooth.map { $0 - lowest }
        self.water = Self.blur(wet, side: m, radius: max(radius / 2, 1))
        side = m
        self.corner = corner
        self.size = size
        base = lowest
    }

    /// The smoothed height at `xz`, metres (bilinear; held at the edge outside).
    public func height(at xz: SIMD2<Float>) -> Float {
        let g = simd_clamp((xz - corner) / size * Float(side - 1), SIMD2(repeating: 0), SIMD2(repeating: Float(side - 1)))
        let c = SIMD2<Int>(min(Int(g.x), side - 2), min(Int(g.y), side - 2))
        let f = g - SIMD2(Float(c.x), Float(c.y))
        let i = c.y * side + c.x
        let a = heights[i] + (heights[i + 1] - heights[i]) * f.x
        let b = heights[i + side] + (heights[i + side + 1] - heights[i + side]) * f.x
        return base + a + (b - a) * f.y
    }

    /// **The map as a texture** — red the smoothed height above ``base``, green the water — half precision, for
    /// ``VolumetricFog/Frame/floor``.
    public func texture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: side, height: side,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Fog Floor"
        var texels = [UInt16](repeating: 0, count: side * side * 2)
        for i in 0..<(side * side) {
            texels[i * 2] = EnvironmentMap.halfBits(heights[i])
            texels[i * 2 + 1] = EnvironmentMap.halfBits(water[i])
        }
        texels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: side * 4)
        }
        return texture
    }

    /// A box blur along x then z, held at the edges.
    static func blur(_ values: [Float], side n: Int, radius r: Int) -> [Float] {
        var along = values
        for z in 0..<n {
            for x in 0..<n {
                var sum: Float = 0
                for k in -r...r { sum += values[z * n + min(max(x + k, 0), n - 1)] }
                along[z * n + x] = sum / Float(2 * r + 1)
            }
        }
        var out = along
        for z in 0..<n {
            for x in 0..<n {
                var sum: Float = 0
                for k in -r...r { sum += along[min(max(z + k, 0), n - 1) * n + x] }
                out[z * n + x] = sum / Float(2 * r + 1)
            }
        }
        return out
    }
}

public nonisolated extension Weather {
    /// **How fast the fog's wisps drift**, metres a second: a calm night's air, which is when ground fog lies.
    static let wispSpeed: Double = 0.6

    /// **Where the fog's wisps are by `time`** — seconds on the world's clock: x, y the way they drift (a unit vector, x
    /// east, y south), z how far, metres, within ``VolumetricFog/wispPeriod`` — what ``VolumetricFog/Frame/wisps`` takes.
    /// Steadily along the world's prevailing wind (``prevailingHeading``), as the clouds travel, and read in a frame turned
    /// to it, so turning the world's heading turns them rather than throwing them elsewhere. Never the wind of the moment
    /// times the clock: a wind that changed moved the whole distance since the clock began at once, and the wisps jumped
    /// about through every change of a schedule.
    /// **A dust storm's billows**, how thick at the ground per metre at full strength (2026-11-21).
    static let dustCloudDensity: Float = 0.035
    /// How high they rise: a third as thick every this many metres up.
    static let dustCloudHeight: Float = 16
    /// How fast they roll past, metres a second — steady, as the wisps are, whatever the wind does this moment.
    static let dustBillowSpeed: Double = 9

    /// **Where a dust storm's billows have rolled to by `time`**, as ``wisps(at:)`` but at a gale's pace, within
    /// ``VolumetricFog/dustPeriod`` — what ``VolumetricFog/Frame/dustDrift`` takes.
    func dustBillows(at time: Double) -> SIMD4<Float> {
        let heading = Double(prevailingHeading) * .pi / 180
        let travelled = (time.isFinite ? time : 0) * Self.dustBillowSpeed
        let period = Double(VolumetricFog.dustPeriod)
        return SIMD4(Float(sin(heading)), Float(-cos(heading)), Float(travelled - (travelled / period).rounded(.down) * period), 0)
    }

    func wisps(at time: Double) -> SIMD4<Float> {
        let heading = Double(prevailingHeading) * .pi / 180
        let travelled = (time.isFinite ? time : 0) * Self.wispSpeed
        let period = Double(VolumetricFog.wispPeriod)
        // Toward the heading: 0 north (−z), 90 east (+x).
        return SIMD4(Float(sin(heading)), Float(-cos(heading)), Float(travelled - (travelled / period).rounded(.down) * period), 0)
    }
}

public nonisolated extension FogFloor {
    /// **Where ground fog pools over a world's ground and water**: a ground `resolution` cells a side and `size` metres
    /// across, centred on the origin, its `(resolution + 1)²` heights row by row along +X; each body of water at its level
    /// over every point its rectangles cover — a rectangle covers whole cells, so every point on or inside it.
    init(heights: [Float], resolution: Int, size: Float, waters: [WorldFile.Water]) {
        let n = resolution + 1, spacing = size / Float(resolution), half = size / 2
        var water = [Float?](repeating: nil, count: n * n)
        for body in waters {
            // **A world file is data from anyone**: a rectangle that is not four finite numbers is skipped, and each edge is
            // kept on the grid before it becomes a point's index, so no value can trap the conversion.
            guard body.level.isFinite else { continue }
            for r in body.rectangles where r.count == 4 && r.allSatisfy(\.isFinite) {
                func point(_ v: Float) -> Int { Int(min(max(((v + half) / spacing).rounded(), 0), Float(n - 1))) }
                let x0 = point(r[0]), x1 = point(r[2]), z0 = point(r[1]), z1 = point(r[3])
                guard x0 <= x1, z0 <= z1 else { continue }
                for z in z0...z1 {
                    for x in x0...x1 { water[z * n + x] = max(water[z * n + x] ?? -.infinity, body.level) }
                }
            }
        }
        self.init(heights: heights, side: n, spacing: spacing, corner: SIMD2(-half, -half), water: water)
    }
}

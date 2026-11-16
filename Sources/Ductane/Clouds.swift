//
//  Clouds.swift
//  Ductane
//

import Foundation
import Metal
import simd

/// **A world's own clouds** (2026-11-16): how high their base is, how thick they are, how fast the wind aloft carries them.
/// The weather decides how much of the sky they cover and how dark they are (``Weather/clouds(at:)``); this is what makes a
/// mountain map's low cloud differ from a desert's high wisps. Ultra Dynamic Sky and Enviro set the same per sky.
public nonisolated struct CloudShape: Sendable, Equatable, Codable {
    /// Metres above the ground their base is.
    public var height: Float
    /// Metres from base to top — a storm's towers grow taller still.
    public var thickness: Float
    /// How fast they travel: 1 the engine's, ``CloudLayer/speedAloft`` — 0 still, 3 three times as fast.
    public var speed: Float

    public init(height: Float = 1500, thickness: Float = 1200, speed: Float = 1) {
        self.height = height.isFinite ? min(max(height, Self.heights.lowerBound), Self.heights.upperBound) : 1500
        self.thickness = thickness.isFinite
            ? min(max(thickness, Self.thicknesses.lowerBound), Self.thicknesses.upperBound) : 1200
        self.speed = speed.isFinite ? min(max(speed, 0), 3) : 1
    }

    public static let heights: ClosedRange<Float> = 300...4000
    public static let thicknesses: ClosedRange<Float> = 200...4000

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudShape()
        self.init(height: (try? c.decodeIfPresent(Float.self, forKey: .height)) ?? d.height,
                  thickness: (try? c.decodeIfPresent(Float.self, forKey: .thickness)) ?? d.thickness,
                  speed: (try? c.decodeIfPresent(Float.self, forKey: .speed)) ?? d.speed)
    }
}

/// **The clouds overhead at a moment** (2026-11-16): how much of the sky they cover and how dark they are — the
/// weather's — where their layer is and how far the wind has carried them. ``CloudPass`` draws them volumetric, or as a
/// flat layer at Low quality; a renderer casts their shadows from the same coverage map (``coverageMap``).
///
/// **They travel steadily along the world's prevailing wind** (2026-11-16), at ``speedAloft`` times the world's
/// ``CloudShape/speed``, on the world's clock. Never at the wind of the moment: their place is how far they have travelled
/// since the clock began, and a wind that changed — a schedule's spell turning or strengthening it — would have moved
/// that whole distance at once, sending the clouds hundreds of kilometres each frame of the change. The wind aloft is
/// steadier than the wind at the ground in the world as well.
///
/// **One pattern everywhere**, read in a frame turned to that wind (``place(_:)``): the noise repeats every ``period``
/// metres, so the distance travelled wraps there with no seam and a clock of years stays precise, and turning the world's
/// heading turns the pattern about the world's middle rather than throwing it somewhere else.
public nonisolated struct CloudLayer: Sendable, Equatable {
    /// How much of the sky they cover, 0…1.
    public var coverage: Float
    /// How dark they are underneath, 0 white … 1 a storm's.
    public var darkness: Float
    /// **Where they are on their pattern**: x, y the way they travel (a unit vector, x east, y south); z how far they have
    /// travelled along it, metres, within one ``period``. What a shader reads them by (`duCloudPlace`), with ``place(_:)``.
    public var motion: SIMD4<Float>
    /// Their base and their thickness, metres — a storm's towers taller than the world's own.
    public var base: Float
    public var thickness: Float

    public init(coverage: Float, darkness: Float = 0, motion: SIMD4<Float> = SIMD4(0, -1, 0, 0), base: Float = 1500,
                thickness: Float = 1200) {
        self.coverage = coverage.isFinite ? min(max(coverage, 0), 1) : 0
        self.darkness = darkness.isFinite ? min(max(darkness, 0), 1) : 0
        let way = SIMD2(motion.x, motion.y)
        let length = simd_length(way)
        self.motion = length.isFinite && length > 1e-6 && motion.z.isFinite
            ? SIMD4(way.x / length, way.y / length, motion.z, 0) : SIMD4(0, -1, 0, 0)
        self.base = base.isFinite ? max(base, 0) : 1500
        self.thickness = thickness.isFinite ? max(thickness, 50) : 1200
    }

    /// The pattern repeats every this many metres in both directions: thirty cells of the coarsest noise, 2,048 m each.
    public static let period: Double = 61_440
    /// **How fast they travel at ``CloudShape/speed`` 1**, metres a second: a moderate wind aloft, about 0.3° a second
    /// overhead at their usual height.
    public static let speedAloft: Double = 8

    /// **Where a point of the world is on their pattern** (x, z metres): in a frame turned to the way they travel, moved
    /// back by how far they have come — what `duCloudPlace` works out in a shader, and what ``coverage(at:coverage:)``
    /// and the noise are read at.
    public func place(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let way = SIMD2(motion.x, motion.y)
        return SIMD2(simd_dot(p, SIMD2(-way.y, way.x)), simd_dot(p, way) - motion.z)
    }
    /// **How much of a clear sky still has clouds**: a few fair-weather ones, so a clear day is not an empty dome.
    public static let fairWeather: Float = 0.22

    /// **How much of the sun reaches the ground at `point` through the clouds**, 0…1 — their shadow, from the coverage
    /// over the point along `light` (toward the light). Patches under broken cloud; under a sky nearly covered, the weather
    /// has already dimmed the sun (``Weather/lighting(_:flash:)``), so the patches fade rather than darken it twice.
    /// A shader casting their shadows works out the same from the coverage map.
    public func shadow(at point: SIMD3<Float>, light: SIMD3<Float>) -> Float {
        let mid = base + thickness * 0.4
        let up = max(light.y, 0.08)
        let p = SIMD2(point.x, point.z) + SIMD2(light.x, light.z) / up * (mid - point.y)
        let strength = 0.75 * (1 - 0.8 * Self.smoothstep(0.6, 1, coverage))
        return 1 - strength * Self.coverage(at: place(p), coverage: coverage)
    }

    /// **The clouds' coverage at a point of their layer**, 0…1: the ``coverageMap`` read there, spread so `coverage` is
    /// about the share of the sky covered — what `duCoverage` works out in a shader from the same map.
    public static func coverage(at p: SIMD2<Float>, coverage: Float) -> Float {
        let spread = sampleMap(p)
        return smoothstep(1 - coverage - 0.12, 1 - coverage + 0.12, spread)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: The coverage map

    /// Texels a side of ``coverageMap``: 240 m each over the ``period``.
    public static let mapSize = 256

    /// **Where clouds gather**, 0…1 a texel, repeating every ``period``: three octaves of tileable value noise, spread
    /// even. Made once; a renderer reads it as a texture (``coverageTexture(device:)``) rather than working the noise out
    /// for every step through the clouds.
    public static let coverageMap: [Float] = {
        let n = mapSize
        var map = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                // The texel's centre, in metres.
                let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5) * Float(period) / Float(n)
                var v: Float = 0, amplitude: Float = 0.6, frequency: Float = 1 / 4096, cells: Int32 = 15
                for _ in 0..<3 {
                    v += amplitude * valueNoise(p * frequency, period: cells)
                    amplitude *= 0.5
                    frequency *= 2
                    cells *= 2
                }
                map[y * n + x] = smoothstep(0.3, 0.7, v / 1.05)
            }
        }
        return map
    }()

    /// The map read between its texels at `p` metres, wrapping — as a GPU's linear filter reads its texture.
    static func sampleMap(_ p: SIMD2<Float>) -> Float {
        let n = mapSize
        let g = p / Float(period) * Float(n) - 0.5
        guard g.x.isFinite, g.y.isFinite else { return 0 }
        let i = SIMD2(g.x.rounded(.down), g.y.rounded(.down)), f = g - i
        func texel(_ x: Float, _ y: Float) -> Float {
            let xi = ((Int(x.truncatingRemainder(dividingBy: Float(n))) % n) + n) % n
            let yi = ((Int(y.truncatingRemainder(dividingBy: Float(n))) % n) + n) % n
            return coverageMap[yi * n + xi]
        }
        let a = texel(i.x, i.y) + (texel(i.x + 1, i.y) - texel(i.x, i.y)) * f.x
        let b = texel(i.x, i.y + 1) + (texel(i.x + 1, i.y + 1) - texel(i.x, i.y + 1)) * f.x
        return a + (b - a) * f.y
    }

    /// **The coverage map as a texture**, `r16Float`, to read with a repeating linear sampler at `metres / period`.
    public static func coverageTexture(device: MTLDevice) -> MTLTexture? {
        let n = mapSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: n, height: n, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Cloud Coverage"
        let halves = coverageMap.map { Float16($0) }
        halves.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 2)
        }
        return texture
    }

    /// Value noise repeating every `period` cells.
    static func valueNoise(_ p: SIMD2<Float>, period: Int32) -> Float {
        let i = SIMD2(p.x.rounded(.down), p.y.rounded(.down)), f = p - i
        let u = f * f * (3 - 2 * f)
        func corner(_ dx: Int32, _ dy: Int32) -> Float {
            func wrap(_ v: Int32) -> UInt32 { UInt32(bitPattern: ((v % period) + period) % period) }
            let x = Int32(clamping: Int(max(min(i.x, 1e9), -1e9))) &+ dx
            let y = Int32(clamping: Int(max(min(i.y, 1e9), -1e9))) &+ dy
            var h = (wrap(x) &* 73_856_093) ^ (wrap(y) &* 19_349_663)
            h = h &* 747_796_405 &+ 2_891_336_453
            h ^= h >> 16
            return Float(h & 0xFFFF) / 65_535
        }
        let a = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * u.x
        let b = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * u.x
        return a + (b - a) * u.y
    }
}

public nonisolated extension Weather {

    /// **The clouds at `time`** — seconds on the weather's clock, the same one a schedule and lightning run by: covering
    /// the sky as the weather's cloud cover says, from ``CloudLayer/fairWeather`` on a clear day to all of it; dark as rain
    /// gets heavy and in a storm, whose towers rise half as tall again; carried steadily along the world's prevailing wind
    /// (``CloudLayer``, ``prevailingHeading``), so a wind that changes never throws them about.
    func clouds(at time: Double) -> CloudLayer {
        let s = settings
        let coverage = CloudLayer.fairWeather + (1 - CloudLayer.fairWeather) * s.cloudCover
        let storm: Float = kind == .storm || s.lightning > 0 ? 0.25 : 0
        let darkness = min(s.precipitation * (s.snow ? 0.35 : 0.7) + max(s.cloudCover - 0.55, 0) * 0.6 + storm, 1)
        let heading = Double(prevailingHeading) * .pi / 180
        let travelled = (time.isFinite ? time : 0) * CloudLayer.speedAloft * Double(cloudShape.speed)
        let p = CloudLayer.period
        let along = Float(travelled - (travelled / p).rounded(.down) * p)
        // Toward the heading: 0 north (−z), 90 east (+x).
        return CloudLayer(coverage: coverage, darkness: darkness,
                          motion: SIMD4(Float(sin(heading)), Float(-cos(heading)), along, 0),
                          base: cloudShape.height, thickness: cloudShape.thickness * (storm > 0 ? 1.5 : 1))
    }

    /// **The wind in a world's foliage and cloth at `time`**: x, z the way it blows (a unit vector), y how hard — 0 still
    /// air … 1 a gale, a breeze about 0.15, times the world's ``sway`` — and w seconds on the weather's clock wrapped to an
    /// hour. A renderer bends trees and grass and ripples cloth by it in its vertex stage (``Sway``), so a
    /// storm's trees thrash the way its rain slants.
    func foliageWind(at time: Double) -> SIMD4<Float> {
        let heading = windHeading * .pi / 180
        let strength = min(settings.windSpeed / 20, 1.25) * sway
        let t = time.isFinite ? time - (time / 3600).rounded(.down) * 3600 : 0
        return SIMD4(sin(heading), strength, -cos(heading), Float(t))
    }
}

/// **The sky at night** (2026-11-16): the stars and the Milky Way, turning about the pole as the hours pass, and the moon
/// with its phase — what ``SkyPass`` draws over the sky. From a ``DaySky`` (``DaySky/night``).
public nonisolated struct NightSky: Sendable, Equatable {
    /// Turns a direction in the world into the stars' own sphere: the sky's turning about the pole by the hour and the year.
    public var starRotation: simd_float3x3
    /// How bright the stars are, 0 by day … 1 deep night.
    public var stars: Float
    /// Unit vector toward the moon.
    public var moon: SIMD3<Float>
    /// Unit vector toward the sun, which lights the moon's face: its phase is where this falls.
    public var sun: SIMD3<Float>
    /// How much of the moon's face is lit, 0 new … 1 full.
    public var illumination: Float
    /// **Tonight's aurora**, 0…1, already dimmed by the dawn (``DaySky/auroraStrength``).
    public var aurora: Float = 0
    /// Toward the pole the aurora hangs over, level: north in the northern hemisphere, south in the southern.
    public var pole: SIMD3<Float> = SIMD3(0, 0, -1)
}

public nonisolated extension Weather {
    /// **How strong a rainbow is**, 0…1, with the sun `sunElevation` radians high: where physics puts one — rain falling
    /// with the sun out through broken cloud, and the sun up but under 42°, the bow being 42° from the point opposite it.
    /// A clearing shower on a schedule makes one as its rain thins and its cloud breaks.
    func rainbow(sunElevation: Float) -> Float {
        let s = settings
        guard !s.snow, kind != .dust else { return 0 }
        let degrees = sunElevation * 180 / .pi
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        return smooth(0.02, 0.3, s.precipitation) * (1 - smooth(0.7, 0.98, s.cloudCover)) * smooth(0, 4, degrees)
            * (1 - smooth(36, 42, degrees))
    }
}

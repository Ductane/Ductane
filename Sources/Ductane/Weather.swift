//
//  Weather.swift
//  Ductane
//

import Foundation
import simd

/// **A world's weather**: cloud, rain or snow, wind, fog and lightning, as a few numbers a game draws and hears the same
/// way an editor showed them.
///
/// **A kind and how severe it is** — overcast, rain, a storm — is the normal case: ``preset(_:severity:)`` turns the two
/// into ``Settings``. **Settings by hand** (``byHand``) are for matching something a preset does not reach. Either way
/// everything else — how much the clouds dim the sun (``lighting(_:flash:)``), how thick the air is
/// (``fogDensity(over:)``), how hard the rain falls and which way the wind pushes it (``wind``), when lightning strikes
/// (``strikes(from:to:)``) and how loud the rain is (``rainVolume``) — follows from the settings.
///
/// **Lightning is the same for everyone who has the same weather**: strikes come from ``seed`` and a clock, never from
/// a random generator's state, so two players on one clock see one storm. Where they strike is fixed in the world,
/// around its middle, so thunder arrives later the further away the listener stands.
///
/// What it does not do: change over time. The weather is as set until a game sets another.
public nonisolated struct Weather: Sendable, Equatable, Codable {

    /// What the sky is doing.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case clear, overcast, rain, storm, snow, fog
    }

    /// **The numbers everything is drawn and heard from.**
    public struct Settings: Sendable, Equatable, Codable {
        /// How much of the sky is cloud, 0…1: at 1 the sun is mostly gone, its shadows faint, the sky grey.
        public var cloudCover: Float
        /// How hard it rains or snows, 0 none…1 a downpour.
        public var precipitation: Float
        /// Snow rather than rain.
        public var snow: Bool
        /// Metres a second, 0…``windSpeeds``.
        public var windSpeed: Float
        /// Added to the world's own fog, in ``DaySky/fogDensity``'s units: 0.008 hides half of a thing at about 100 m.
        public var fogDensity: Float
        /// Lightning strikes a minute, on average.
        public var lightning: Float

        public init(cloudCover: Float = 0, precipitation: Float = 0, snow: Bool = false, windSpeed: Float = 0,
                    fogDensity: Float = 0, lightning: Float = 0) {
            self.cloudCover = min(max(cloudCover, 0), 1)
            self.precipitation = min(max(precipitation, 0), 1)
            self.snow = snow
            self.windSpeed = min(max(windSpeed, 0), Weather.windSpeeds.upperBound)
            self.fogDensity = min(max(fogDensity, 0), Weather.fogDensities.upperBound)
            self.lightning = min(max(lightning, 0), Weather.lightningRates.upperBound)
        }

        /// What a file leaves out is none.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(cloudCover: (try? c.decodeIfPresent(Float.self, forKey: .cloudCover)) ?? 0,
                      precipitation: (try? c.decodeIfPresent(Float.self, forKey: .precipitation)) ?? 0,
                      snow: (try? c.decodeIfPresent(Bool.self, forKey: .snow)) ?? false,
                      windSpeed: (try? c.decodeIfPresent(Float.self, forKey: .windSpeed)) ?? 0,
                      fogDensity: (try? c.decodeIfPresent(Float.self, forKey: .fogDensity)) ?? 0,
                      lightning: (try? c.decodeIfPresent(Float.self, forKey: .lightning)) ?? 0)
        }
    }

    public var kind: Kind
    /// How severe the kind is, 0 the lightest…1 the heaviest. What a preset is read at; ignored when ``byHand`` is set.
    public var severity: Float
    /// **Which way the wind blows, as a compass bearing it blows toward**: 0 north (−z), 90 east (+x).
    public var windHeading: Float
    /// Settings by hand, instead of the kind and its severity. Nil is the normal case.
    public var byHand: Settings?
    /// Where lightning's strikes start: one world, one storm.
    public var seed: UInt32

    public init(kind: Kind = .clear, severity: Float = 0.5, windHeading: Float = 60, byHand: Settings? = nil,
                seed: UInt32 = 1) {
        self.kind = kind
        self.severity = min(max(severity.isFinite ? severity : 0.5, 0), 1)
        self.windHeading = windHeading.isFinite ? windHeading : 60
        self.byHand = byHand
        self.seed = seed
    }

    /// What a file leaves out is the default, and a kind this engine does not know is clear.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Weather()
        self.init(kind: (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind,
                  severity: (try? c.decodeIfPresent(Float.self, forKey: .severity)) ?? d.severity,
                  windHeading: (try? c.decodeIfPresent(Float.self, forKey: .windHeading)) ?? d.windHeading,
                  byHand: try? c.decodeIfPresent(Settings.self, forKey: .byHand),
                  seed: (try? c.decodeIfPresent(UInt32.self, forKey: .seed)) ?? d.seed)
    }

    /// A clear sky, no wind to speak of: what a world without weather has.
    public static let clear = Weather()

    /// The wind's range, metres a second: still to a gale.
    public static let windSpeeds: ClosedRange<Float> = 0...25
    /// Weather's fog's range: none to a thick mist.
    public static let fogDensities: ClosedRange<Float> = 0...0.03
    /// Strikes a minute: none to a storm overhead.
    public static let lightningRates: ClosedRange<Float> = 0...12

    /// The settings this weather is drawn from: by hand when set, else its kind at its severity.
    public var settings: Settings { byHand ?? Self.preset(kind, severity: severity) }

    /// **A kind at a severity**: each kind's lightest and heaviest, and a straight line between.
    public static func preset(_ kind: Kind, severity: Float) -> Settings {
        let s = min(max(severity, 0), 1)
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * s }
        return switch kind {
        case .clear:
            // A clear sky is clear at any severity — only its breeze grows — so a world set to clear looks as it did.
            Settings(windSpeed: mix(0.5, 4))
        case .overcast:
            Settings(cloudCover: mix(0.55, 0.95), windSpeed: mix(2, 7), fogDensity: mix(0, 0.002))
        case .rain:
            Settings(cloudCover: mix(0.75, 1), precipitation: mix(0.25, 1), windSpeed: mix(2, 9),
                     fogDensity: mix(0.001, 0.004))
        case .storm:
            Settings(cloudCover: mix(0.9, 1), precipitation: mix(0.6, 1), windSpeed: mix(8, 20),
                     fogDensity: mix(0.002, 0.005), lightning: mix(1, 8))
        case .snow:
            Settings(cloudCover: mix(0.7, 0.95), precipitation: mix(0.2, 1), snow: true, windSpeed: mix(1, 8),
                     fogDensity: mix(0.002, 0.008))
        case .fog:
            Settings(cloudCover: mix(0.4, 0.8), windSpeed: mix(0, 1.5), fogDensity: mix(0.006, 0.025))
        }
    }

    // MARK: Wind

    /// The way the wind blows, flat, metres a second.
    public var wind: SIMD3<Float> {
        let h = windHeading * .pi / 180
        return SIMD3(sin(h), 0, -cos(h)) * settings.windSpeed
    }

    // MARK: Light

    /// **The sky under this weather**: `base` (``DaySky/lighting``) with its sun dimmed by the clouds and some of what
    /// they took spread over the sky, the sky drawn grey, and everything a little darker as the rain thickens; then
    /// lightning's `flash` (``flash(at:heardFrom:)``) added to the sky and the light it casts.
    ///
    /// The sun's direction is left as it is: under thin cloud its shadows still fall the right way, only fainter.
    public func lighting(_ base: DaySky.Lighting, flash: Float = 0) -> DaySky.Lighting {
        let s = settings
        let cover = s.cloudCover, wet = s.precipitation
        guard cover > 0 || wet > 0 || flash > 0 else { return base }
        var light = base
        let direct = 1 - 0.9 * pow(cover, 1.4)
        light.colour = base.colour * direct
        // What the cloud takes from the sun lights the sky instead — an overcast day is dim, not dark.
        let lost = Self.luminance(base.colour - light.colour)
        let darker = 1 - 0.4 * wet * (s.snow ? 0.4 : 1)
        func grey(_ c: SIMD3<Float>, _ lift: Float) -> SIMD3<Float> {
            Self.cloudGrey * max(Self.luminance(c) + lift, 0)
        }
        // An overcast sky is one even grey, about as bright as the clear sky's horizon and a little under it — never white.
        let overcast = Self.cloudGrey * Self.luminance(base.horizon)
        light.zenith = simd_mix(base.zenith, overcast * 0.78, SIMD3(repeating: cover)) * darker
        light.horizon = simd_mix(base.horizon, overcast * 0.85, SIMD3(repeating: cover)) * darker
        let sky = base.skyLight == .zero ? base.zenith : base.skyLight
        // Flat, and a little dimmer than a clear sky's light: an overcast day has no shadows and less light, not more.
        light.skyLight = simd_mix(sky, grey(sky, lost * 0.03), SIMD3(repeating: cover)) * (1 - 0.3 * cover) * darker
        light.ground = base.ground * (1 - 0.5 * cover) * darker
        light.colour *= darker
        if flash > 0 {
            let burst = Self.flashColour * flash
            light.zenith += burst * 2
            light.horizon += burst * 2.5
            light.skyLight += burst * 1.5
        }
        return light
    }

    /// **How thick the air is** under this weather: the world's own fog and the weather's, whichever is thicker
    /// counting for most — a foggy world in fog is no thinner, and rain still greys a clear one.
    public func fogDensity(over world: Float) -> Float {
        let a = max(world, 0), b = settings.fogDensity
        // Exactly the world's own with none of its own, so a clear sky changes nothing by a rounding.
        return b == 0 ? a : sqrt(a * a + b * b)
    }

    /// Clouds' grey, a little cool.
    static let cloudGrey = SIMD3<Float>(0.92, 0.95, 1.0)
    /// Lightning's light, a little blue.
    static let flashColour = SIMD3<Float>(0.85, 0.9, 1.0)

    static func luminance(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }

    // MARK: Lightning

    /// **A lightning strike**: when, in seconds on the clock the weather is drawn by, and where on the ground.
    public struct Strike: Sendable, Equatable {
        public var time: Double
        public var position: SIMD2<Float>

        public init(time: Double, position: SIMD2<Float>) {
            self.time = time
            self.position = position
        }

        /// How far it is from `listener`, metres.
        public func distance(from listener: SIMD3<Float>) -> Float {
            simd_distance(position, SIMD2(listener.x, listener.z))
        }

        /// **How long its thunder takes to arrive**: sound covers 343 m a second.
        public func thunderDelay(heardFrom listener: SIMD3<Float>) -> Double {
            Double(distance(from: listener)) / Weather.speedOfSound
        }

        /// How loud its thunder is, 0…1: full within a few hundred metres, a rumble by three kilometres.
        public func thunderVolume(heardFrom listener: SIMD3<Float>) -> Float {
            min(1, 1.3 / (1 + distance(from: listener) / 700))
        }

        /// How bright its flash is `seconds` after it, seen from `eye`: three flickers over half a second, fainter the
        /// further away.
        public func flash(after seconds: Double, seenFrom eye: SIMD3<Float>) -> Float {
            guard seconds >= 0, seconds < Weather.flashLength else { return 0 }
            let t = Float(seconds)
            var bright: Float = 0
            for (start, height) in [(Float(0), Float(1)), (0.09, 0.55), (0.24, 0.8)] where t >= start {
                bright = max(bright, height * exp(-(t - start) * 14))
            }
            let near = 1 / (1 + pow(distance(from: eye) / 1500, 2))
            return bright * near
        }
    }

    /// Metres a second.
    public static let speedOfSound: Double = 343
    /// How long a flash lasts, seconds.
    static let flashLength: Double = 0.7
    /// How near and how far from the world's middle lightning strikes, metres: rarely overhead, never out of hearing.
    public static let strikeDistances: ClosedRange<Float> = 400...3000
    /// Strikes come from one-second slots: at most one a second.
    static let slot: Double = 1

    /// **Every strike from `start` up to `end`**, seconds on the weather's clock — the same for the same seed, whoever
    /// asks and however the span is cut up.
    public func strikes(from start: Double, to end: Double) -> [Strike] {
        let rate = settings.lightning
        guard rate > 0, end > start, start.isFinite, end.isFinite else { return [] }
        let chance = Double(min(rate / 60, 1)) * Self.slot
        var strikes: [Strike] = []
        var n = Int64(max((start / Self.slot).rounded(.down), -9e15))
        let last = Int64((end / Self.slot).rounded(.down))
        while n <= last {
            if Self.unit(seed, n, 0) < chance {
                let time = (Double(n) + Self.unit(seed, n, 1)) * Self.slot
                if time >= start, time < end {
                    let angle = Float(Self.unit(seed, n, 2)) * 2 * .pi
                    let span = Self.strikeDistances
                    let distance = span.lowerBound + Float(Self.unit(seed, n, 3)) * (span.upperBound - span.lowerBound)
                    strikes.append(Strike(time: time, position: SIMD2(cos(angle), sin(angle)) * distance))
                }
            }
            n += 1
        }
        return strikes
    }

    /// **Lightning's light at `time`**, seen from `eye`: the brightest of the strikes still flashing, 0…1. What
    /// ``lighting(_:flash:)`` takes.
    public func flash(at time: Double, seenFrom eye: SIMD3<Float>) -> Float {
        strikes(from: time - Self.flashLength, to: time + 1e-9)
            .reduce(0) { max($0, $1.flash(after: time - $1.time, seenFrom: eye)) }
    }

    /// A number in 0..<1 from the seed, the slot and which number of the slot — SplitMix64 over all three.
    static func unit(_ seed: UInt32, _ slot: Int64, _ which: UInt64) -> Double {
        var z = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: slot) &* 0xBF58_476D_1CE4_E5B9
            ^ which &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    // MARK: Sound

    /// How loud the rain is, 0…1: none in snow.
    public var rainVolume: Float {
        let s = settings
        return s.snow ? 0 : pow(s.precipitation, 0.7)
    }

    /// How loud the wind is, 0…1: nothing under a breeze, full in a gale.
    public var windVolume: Float {
        min(max((settings.windSpeed - 3) / 14, 0), 1)
    }
}

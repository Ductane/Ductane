//
//  WorldSounds.swift
//  Ductane
//

import simd

extension WorldFile {

    /// **What a world sounds like**, as its editor laid it out: loops at places, ambience over areas, sounds now and then
    /// inside areas, and the world's music. ``Soundscape`` plays it as written, so a game hears what the author heard and
    /// writes no code of its own for it — **when** the world is heard (paused, in a menu, under a cutscene) and any music
    /// that follows play (a fight, danger) stay the game's.
    ///
    /// Sound files are named once, by their paths in the package, and everything else refers to them by index. Areas are
    /// outlines on the ground, `x` and `z` in metres; an empty outline is the whole world.
    public nonisolated struct Sounds: Codable, Equatable, Sendable {
        /// The sound files, by their paths in the package.
        public var files: [String]
        public var points: [Point]
        public var ambiences: [Ambience]
        public var scattered: [Scattered]
        public var music: Music?
        /// **What the weather sounds like**: rain and wind beds as loud as the weather is heavy, and thunder after each
        /// strike (``Weather``). Nil: the weather is silent.
        public var weather: WeatherSounds?

        public init(files: [String] = [], points: [Point] = [], ambiences: [Ambience] = [], scattered: [Scattered] = [],
                    music: Music? = nil, weather: WeatherSounds? = nil) {
            self.files = files
            self.points = points
            self.ambiences = ambiences
            self.scattered = scattered
            self.music = music
            self.weather = weather
        }

        /// Whether it plays nothing.
        public var isEmpty: Bool {
            points.isEmpty && ambiences.isEmpty && scattered.isEmpty && (music?.tracks.isEmpty ?? true)
                && (weather?.isEmpty ?? true)
        }

        /// **When in the day a sound is heard** (2026-11-16): always, by day, or by night — crows by day, frogs by night.
        /// The listener's daylight (``Soundscape/setDaylight(_:)``) fades one in as the other goes, over dawn and dusk.
        public enum Hours: String, Codable, Sendable, CaseIterable {
            case always, day, night

            /// How much of a sound with these hours is heard at `daylight`, 0 night … 1 day.
            public func weight(daylight: Float) -> Float {
                let d = daylight.isFinite ? min(max(daylight, 0), 1) : 1
                switch self {
                case .always: return 1
                case .day: return d
                case .night: return 1 - d
                }
            }
        }

        /// **A loop at a place** — a generator's hum, a fire, a drip: full near it, gone at its reach (``SoundReach``).
        public struct Point: Codable, Equatable, Sendable {
            /// An index into ``Sounds/files``.
            public var sound: Int
            public var position: SIMD3<Float>
            /// 0…1.
            public var volume: Float
            /// Metres: heard no further than this.
            public var reach: Float
            /// When in the day it is heard.
            public var hours: Hours
            public init(sound: Int, position: SIMD3<Float>, volume: Float = 1, reach: Float = 20, hours: Hours = .always) {
                self.sound = sound
                self.position = position
                self.volume = volume
                self.reach = reach
                self.hours = hours
            }

            /// What a file leaves out is always heard; an hour this engine does not know is too.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init(sound: try c.decode(Int.self, forKey: .sound),
                          position: try c.decode(SIMD3<Float>.self, forKey: .position),
                          volume: try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1,
                          reach: try c.decodeIfPresent(Float.self, forKey: .reach) ?? 20,
                          hours: Hours.read(c, .hours))
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(sound, forKey: .sound)
                try c.encode(position, forKey: .position)
                try c.encode(volume, forKey: .volume)
                try c.encode(reach, forKey: .reach)
                if hours != .always { try c.encode(hours, forKey: .hours) }
            }

            private enum CodingKeys: String, CodingKey { case sound, position, volume, reach, hours }
        }

        /// **A background loop over an area** — wind across a field, a marsh, a room's tone: heard the same everywhere
        /// inside its outline and in both ears, fading to nothing ``fade`` metres outside it. **With a ``night`` recording
        /// (2026-11-16)** — cicadas by day, crickets and frogs by night — one gives way to the other over dawn and dusk.
        public struct Ambience: Codable, Equatable, Sendable {
            /// The loop — by day, when there is a ``night`` one.
            public var sound: Int
            /// The loop heard at night in its place; nil plays ``sound`` day and night.
            public var night: Int?
            /// The area's corners on the ground, in order; empty for the whole world.
            public var outline: [SIMD2<Float>]
            /// Metres outside the outline over which it fades away.
            public var fade: Float
            public var volume: Float
            public init(sound: Int, night: Int? = nil, outline: [SIMD2<Float>] = [], fade: Float = 10, volume: Float = 0.6) {
                self.sound = sound
                self.night = night
                self.outline = outline
                self.fade = fade
                self.volume = volume
            }

            /// What a file leaves out is the default; no night loop plays the one loop day and night.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init(sound: try c.decode(Int.self, forKey: .sound),
                          night: try c.decodeIfPresent(Int.self, forKey: .night),
                          outline: try c.decodeIfPresent([SIMD2<Float>].self, forKey: .outline) ?? [],
                          fade: try c.decodeIfPresent(Float.self, forKey: .fade) ?? 10,
                          volume: try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.6)
            }

            private enum CodingKeys: String, CodingKey { case sound, night, outline, fade, volume }
        }

        /// **A sound now and then somewhere in an area** — a crow, a creak, distant metal: one of ``sounds`` at a time,
        /// never the same take twice running, at a random place inside the outline within its reach of the listener,
        /// every ``shortest`` to ``longest`` seconds while the listener is near enough to hear it.
        public struct Scattered: Codable, Equatable, Sendable {
            /// Indices into ``Sounds/files`` — the takes it picks from.
            public var sounds: [Int]
            public var outline: [SIMD2<Float>]
            /// Seconds between one and the next, at the least and at the most.
            public var shortest: Float
            public var longest: Float
            public var volume: Float
            /// Metres: each is heard no further than this from where it sounds.
            public var reach: Float
            /// **Up to how far above the listener's ears** a sound may be — a crow in a tree, a creak in a roof.
            public var height: Float
            /// When in the day they are heard: sounded only while it is more their time than not, as loud as it is.
            public var hours: Hours
            public init(sounds: [Int], outline: [SIMD2<Float>] = [], shortest: Float = 8, longest: Float = 20,
                        volume: Float = 0.8, reach: Float = 40, height: Float = 3, hours: Hours = .always) {
                self.sounds = sounds
                self.outline = outline
                self.shortest = shortest
                self.longest = longest
                self.volume = volume
                self.reach = reach
                self.height = height
                self.hours = hours
            }

            /// What a file leaves out is the default.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init(sounds: try c.decode([Int].self, forKey: .sounds),
                          outline: try c.decodeIfPresent([SIMD2<Float>].self, forKey: .outline) ?? [],
                          shortest: try c.decodeIfPresent(Float.self, forKey: .shortest) ?? 8,
                          longest: try c.decodeIfPresent(Float.self, forKey: .longest) ?? 20,
                          volume: try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8,
                          reach: try c.decodeIfPresent(Float.self, forKey: .reach) ?? 40,
                          height: try c.decodeIfPresent(Float.self, forKey: .height) ?? 3,
                          hours: Hours.read(c, .hours))
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(sounds, forKey: .sounds)
                try c.encode(outline, forKey: .outline)
                try c.encode(shortest, forKey: .shortest)
                try c.encode(longest, forKey: .longest)
                try c.encode(volume, forKey: .volume)
                try c.encode(reach, forKey: .reach)
                try c.encode(height, forKey: .height)
                if hours != .always { try c.encode(hours, forKey: .hours) }
            }

            private enum CodingKeys: String, CodingKey { case sounds, outline, shortest, longest, volume, reach, height, hours }
        }

        /// **The world's music**: one track looped, or several in turn (``MusicPlayer/play(playlist:)``).
        public struct Music: Codable, Equatable, Sendable {
            public var tracks: [Int]
            public var volume: Float
            public init(tracks: [Int], volume: Float = 0.45) {
                self.tracks = tracks
                self.volume = volume
            }
        }

        /// **The weather's sounds**: a rain loop and a wind loop, each heard in both ears as loud as ``Weather/rainVolume``
        /// and ``Weather/windVolume`` say, and thunder — one of ``thunder`` at a time — arriving from each strike as long
        /// after it as sound takes to cover the distance (``Weather/Strike/thunderDelay(heardFrom:)``).
        public struct WeatherSounds: Codable, Equatable, Sendable {
            /// Indices into ``Sounds/files``.
            public var rain: Int?
            public var wind: Int?
            /// The takes thunder picks from.
            public var thunder: [Int]
            /// 0…1: how loud all of it is at its heaviest.
            public var volume: Float

            public init(rain: Int? = nil, wind: Int? = nil, thunder: [Int] = [], volume: Float = 0.8) {
                self.rain = rain
                self.wind = wind
                self.thunder = thunder
                self.volume = min(max(volume, 0), 1)
            }

            public var isEmpty: Bool { rain == nil && wind == nil && thunder.isEmpty }

            /// What a file leaves out is none.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.init(rain: try c.decodeIfPresent(Int.self, forKey: .rain),
                          wind: try c.decodeIfPresent(Int.self, forKey: .wind),
                          thunder: try c.decodeIfPresent([Int].self, forKey: .thunder) ?? [],
                          volume: try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8)
            }

            private enum CodingKeys: String, CodingKey { case rain, wind, thunder, volume }
        }

        /// Every index into ``files`` the sounds name — what reading checks.
        var named: [Int] {
            points.map(\.sound) + ambiences.map(\.sound) + ambiences.compactMap(\.night) + scattered.flatMap(\.sounds)
                + (music?.tracks ?? [])
                + [weather?.rain, weather?.wind].compactMap { $0 } + (weather?.thunder ?? [])
        }

        /// What a file leaves out is empty.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
            points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
            ambiences = try c.decodeIfPresent([Ambience].self, forKey: .ambiences) ?? []
            scattered = try c.decodeIfPresent([Scattered].self, forKey: .scattered) ?? []
            music = try c.decodeIfPresent(Music.self, forKey: .music)
            weather = try c.decodeIfPresent(WeatherSounds.self, forKey: .weather)
        }

        private enum CodingKeys: String, CodingKey { case files, points, ambiences, scattered, music, weather }
    }
}

nonisolated extension WorldFile.Sounds.Hours {
    /// The hours a file names; always when it names none, or one this engine does not know.
    static func read<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Self {
        ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(Self.init(rawValue:)) ?? .always
    }
}

/// **An area's outline on the ground**: whether a point is inside, and how far it is from the edge — what ambience fades
/// by and where a scattered sound may land. Corners `x` and `z`, in order, either way round; fewer than three is the whole
/// world.
public nonisolated enum SoundArea {

    /// Whether `point` is inside `outline` — always, for the whole world.
    public static func contains(_ outline: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        guard outline.count >= 3 else { return true }
        var inside = false
        var j = outline.count - 1
        for i in outline.indices {
            let a = outline[i], b = outline[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// **How far `point` is outside `outline`**, in metres — 0 inside it, and for the whole world.
    public static func distanceOutside(_ outline: [SIMD2<Float>], _ point: SIMD2<Float>) -> Float {
        guard outline.count >= 3, !contains(outline, point) else { return 0 }
        var nearest = Float.infinity
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let ab = b - a
            let t = simd_length_squared(ab) > 0 ? min(max(simd_dot(point - a, ab) / simd_length_squared(ab), 0), 1) : 0
            nearest = min(nearest, simd_distance(point, a + ab * t))
        }
        return nearest
    }

    /// **How much of an ambience is heard at `point`, 0…1**: all of it inside the outline, easing to nothing `fade`
    /// metres outside.
    public static func presence(_ outline: [SIMD2<Float>], fade: Float, at point: SIMD2<Float>) -> Float {
        let d = distanceOutside(outline, point)
        guard d > 0 else { return 1 }
        guard fade > 0, d < fade else { return 0 }
        let t = d / fade
        return 1 - t * t * (3 - 2 * t)
    }

    /// The outline's corners at their least and most, or nil for the whole world.
    public static func bounds(_ outline: [SIMD2<Float>]) -> (minimum: SIMD2<Float>, maximum: SIMD2<Float>)? {
        guard outline.count >= 3 else { return nil }
        return (outline.reduce(outline[0], simd_min), outline.reduce(outline[0], simd_max))
    }
}

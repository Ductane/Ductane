//
//  WeatherSchedule.swift
//  Ductane
//

import Foundation
import simd

/// **Weather that changes by itself**: spells of one kind after another — clear for a while, cloud, a shower, clear
/// again — each as heavy as a pick within a range, the wind turning a little each time, one spell blending into the
/// next.
///
/// **Made of a chance per kind, how long a spell lasts and how long a change takes.** Nothing is stored as time passes:
/// the weather at any moment is worked out from ``seed`` and the time alone, so everyone with the same clock sees the
/// same sky, and a moment years into real time costs what the first one did. ``Weather/current(at:)`` is what a game
/// asks each frame, by its own clock or by ``Weather/realTime()``.
///
/// **How the spells are laid out**: boundaries sit every ``(shortest + longest) / 2`` seconds, each moved by its own
/// random amount up to a quarter of the difference either way — so every spell lasts between ``shortest`` and
/// ``longest``, and the spell at any time is one of two, found without counting from the start.
public nonisolated struct WeatherSchedule: Sendable, Equatable, Codable {

    /// Whether a game runs it. Off, the weather is as set; the schedule is kept for when it is turned on again.
    public var isOn: Bool
    /// **How likely each kind is**, as shares: they need not add up to anything. A kind left out never comes.
    public var chances: [Weather.Kind: Float]
    /// How long a spell lasts, seconds: the shortest and the longest.
    public var shortest: Double
    public var longest: Double
    /// How long one spell takes to become the next, seconds — at the start of the new one.
    public var change: Double
    /// How heavy a spell is: a pick between these, 0…1.
    public var lightest: Float
    public var heaviest: Float
    /// **How far the wind turns from the weather's heading**, degrees either way: the heading is the prevailing wind.
    public var wander: Float
    /// Where the spells start: one seed, one sequence of weather.
    public var seed: UInt32
    /// **Seasons**, when the year changes the weather: each season's own chances in place of ``chances``, and warmth.
    /// Nil is one set of chances all year.
    public var seasons: Seasons?

    public init(isOn: Bool = true, chances: [Weather.Kind: Float] = Self.standardChances,
                shortest: Double = 10 * 60, longest: Double = 30 * 60, change: Double = 2 * 60,
                lightest: Float = 0.2, heaviest: Float = 0.8, wander: Float = 45, seed: UInt32 = 1,
                seasons: Seasons? = nil) {
        self.isOn = isOn
        self.chances = chances.compactMapValues { $0.isFinite && $0 > 0 ? $0 : nil }
        let short = shortest.isFinite ? min(max(shortest, Self.spellLengths.lowerBound), Self.spellLengths.upperBound) : 600
        self.shortest = short
        self.longest = longest.isFinite ? min(max(longest, short), Self.spellLengths.upperBound) : max(short, 1800)
        self.change = change.isFinite ? min(max(change, 0), short) : min(120, short)
        let low = min(max(lightest.isFinite ? lightest : 0.2, 0), 1)
        self.lightest = low
        self.heaviest = min(max(heaviest.isFinite ? heaviest : 0.8, low), 1)
        self.wander = min(max(wander.isFinite ? wander : 45, 0), 180)
        self.seed = seed
        self.seasons = seasons
    }

    /// Clear half the time, then overcast, rain and the odd storm.
    public static let standardChances: [Weather.Kind: Float] = [.clear: 50, .overcast: 25, .rain: 15, .storm: 10]
    /// How short and how long a spell may be set, seconds: a minute to a day.
    public static let spellLengths: ClosedRange<Double> = 60...86_400

    // MARK: Spells

    /// **One stretch of one kind of weather.**
    public struct Spell: Sendable, Equatable {
        /// Which spell it is: the same number is always the same spell.
        public var index: Int64
        public var kind: Weather.Kind
        public var severity: Float
        /// Degrees from the weather's heading.
        public var windTurn: Float
        /// When it begins and ends, seconds on the schedule's clock.
        public var start: Double
        public var end: Double
    }

    /// The middle of the spells' lengths: where the boundaries sit before each is moved.
    var pitch: Double { (shortest + longest) / 2 }

    /// When spell `index` begins.
    func boundary(_ index: Int64) -> Double {
        let spread = (longest - shortest) / 4
        return Double(index) * pitch + (Weather.unit(seed, index, 10) * 2 - 1) * spread
    }

    /// Spell `index`, as it always is.
    public func spell(_ index: Int64) -> Spell {
        Spell(index: index, kind: kind(index),
              severity: lightest + Float(Weather.unit(seed, index, 12)) * (heaviest - lightest),
              windTurn: (Float(Weather.unit(seed, index, 13)) * 2 - 1) * wander,
              start: boundary(index), end: boundary(index + 1))
    }

    /// **The spell under way at `time`.**
    public func spell(at time: Double) -> Spell {
        let t = time.isFinite ? time : 0
        let guess = Int64(max(min((t / pitch).rounded(.down), 9e15), -9e15))
        // Boundaries move less than half a pitch, so the spell is the guess or the one before it.
        let index = t < boundary(guess) ? guess - 1 : (t >= boundary(guess + 1) ? guess + 1 : guess)
        return spell(index)
    }

    /// Every spell that touches `start`…`end`, in order — what a strip of the coming hours is drawn from.
    public func spells(from start: Double, to end: Double) -> [Spell] {
        guard end > start else { return [spell(at: start)] }
        var spells = [spell(at: start)]
        while let last = spells.last, last.end < end, spells.count < 10_000 {
            spells.append(spell(last.index + 1))
        }
        return spells
    }

    /// The kind spell `index` is, by the chances when it begins — the season's, with seasons — clear when none is given.
    /// **Snow falls as rain when it is warm** (``warmth(at:)`` over 0.7).
    func kind(_ index: Int64) -> Weather.Kind {
        let start = boundary(index)
        let picked = pick(index, from: chances(at: start))
        if picked == .snow, let warm = warmth(at: start), warm > 0.7 { return .rain }
        return picked
    }

    /// One kind from `chances`, by spell `index`'s own number.
    private func pick(_ index: Int64, from chances: [Weather.Kind: Float]) -> Weather.Kind {
        let shares = Weather.Kind.allCases.map { (kind: $0, share: chances[$0] ?? 0) }
        let total = shares.reduce(0) { $0 + $1.share }
        guard total > 0 else { return .clear }
        var pick = Float(Weather.unit(seed, index, 11)) * total
        for (kind, share) in shares where share > 0 {
            if pick < share { return kind }
            pick -= share
        }
        return shares.last { $0.share > 0 }?.kind ?? .clear
    }

    // MARK: The weather

    /// **The weather at `time`** under `base` — its heading the prevailing wind, its seed lightning's: the spell's kind at
    /// its severity, the wind turned, and in a spell's first ``change`` seconds a blend from the spell before.
    public func weather(at time: Double, under base: Weather) -> Weather {
        let now = spell(at: time)
        // The snow set lying is the least that lies — in winter: with seasons it thaws away toward summer.
        let cold = warmth(at: time).map { 1 - Self.smooth(0.3, 0.7, $0) } ?? 1
        let wet = builtWet(at: time)
        var weather = Weather(kind: now.kind, severity: now.severity, windHeading: base.windHeading + now.windTurn,
                              seed: base.seed, lyingSnow: max(base.lyingSnow * cold, builtSnow(at: time)),
                              snowDepth: base.snowDepth, wetness: max(base.wetness, wet.surface),
                              puddles: max(base.wetness, wet.puddles), cloudShape: base.cloudShape, sway: base.sway,
                              dustColour: base.dustColour, groundFog: base.groundFog)
        weather.windTurn = now.windTurn
        weather.addedStrikes = base.addedStrikes
        guard change > 0, time - now.start < change else { return weather }
        let before = spell(now.index - 1)
        let x = Float(min(max((time - now.start) / change, 0), 1))
        let t = x * x * (3 - 2 * x)
        let from = Weather.preset(before.kind, severity: before.severity)
        let to = Weather.preset(now.kind, severity: now.severity)
        weather.byHand = Self.blend(from, to, t)
        weather.windTurn = before.windTurn + (now.windTurn - before.windTurn) * t
        weather.windHeading = base.windHeading + weather.windTurn
        return weather
    }

    // MARK: Lying snow

    /// A share of full cover gained a second in the heaviest snow: white in twenty minutes.
    public static let snowBuilds: Double = 1.0 / 1200
    /// Lost a second with nothing falling: gone in two hours.
    public static let snowMelts: Double = 1.0 / 7200
    /// Lost a second more in the heaviest rain: rain takes it in about twenty-five minutes.
    public static let rainMelts: Double = 1.0 / 1800
    /// How far back the build-up is counted: snow older than this has long since lain or melted.
    public static let snowMemory: Double = 48 * 3600

    /// **How much snow the schedule has laid by `time`**, 0…1: built in snow spells as hard as they fall, melted after,
    /// faster in rain — counted spell by spell over the last ``snowMemory`` from none, so everyone with the clock has the
    /// same amount. The changes between spells are not counted: a few minutes either way.
    ///
    /// **Cheap to ask every frame**: a schedule with no chance of snow lays none and counts nothing, and the snow laid by the
    /// start of the spell under way is worked out once and remembered (``SnowLaid``) — counting back two days of spells on
    /// every call, ten calls a frame, took an editor showing a scheduled world from 60 frames a second to 2.
    public func builtSnow(at time: Double) -> Float {
        guard time.isFinite, mayLaySnow else { return 0 }
        let now = spell(at: time)
        let start = SnowLaid.shared.snow(of: self, atStartOf: now.index) { snowLaid(before: now) }
        return Float(Self.laid(start, in: now, for: max(time - now.start, 0), warmth: warmth(at: now.start)))
    }

    /// The snow laid by the start of `spell`, counted over the ``snowMemory`` before it.
    func snowLaid(before spell: Spell) -> Double {
        var t = spell.start - Self.snowMemory
        var each = self.spell(at: t)
        var snow = 0.0
        for _ in 0..<100_000 where each.index < spell.index {
            snow = Self.laid(snow, in: each, for: max(min(each.end, spell.start) - t, 0), warmth: warmth(at: each.start))
            t = each.end
            each = self.spell(each.index + 1)
        }
        return snow
    }

    /// `snow` after `seconds` of `spell`: built as hard as it snows, else melted, faster in rain — and, with seasons,
    /// faster as it warms (``meltFactor(warmth:)``).
    static func laid(_ snow: Double, in spell: Spell, for seconds: Double, warmth: Float? = nil) -> Double {
        let falling = Weather.preset(spell.kind, severity: spell.severity)
        let p = Double(falling.precipitation)
        if p > 0, falling.snow { return min(1, snow + p * snowBuilds * seconds) }
        return max(0, snow - (snowMelts * meltFactor(warmth: warmth) + p * rainMelts) * seconds)
    }

    /// **How much faster snow melts at a warmth** than ``snowMelts``: half as fast in the middle of winter (four hours),
    /// two and a half times in spring and autumn (under an hour), twelve and a half in summer (ten minutes). One without
    /// seasons.
    public static func meltFactor(warmth: Float?) -> Double {
        guard let warmth else { return 1 }
        return 0.5 * pow(25, Double(min(max(warmth, 0), 1)))
    }

    /// Whether any chance, in any season, is snow.
    var mayLaySnow: Bool {
        if let seasons { return seasons.chances.values.contains { ($0[.snow] ?? 0) > 0 } }
        return (chances[.snow] ?? 0) > 0
    }

    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Seasons

    /// A season of the year.
    public enum Season: String, Sendable, Codable, CaseIterable {
        case winter, spring, summer, autumn

        /// How warm its middle is, 0 the coldest … 1 the warmest.
        public var warmth: Float {
            switch self {
            case .winter: 0
            case .spring, .autumn: 0.5
            case .summer: 1
            }
        }
    }

    /// **Seasons on a schedule** (owner, 2026-11-16): each season its own chances, and the season from the real date by
    /// hemisphere — or held in one, or run by a game's own calendar. **Each season's chances and warmth are its middle's**;
    /// every day between mixes the two either side, so nothing jumps on a date.
    public struct Seasons: Sendable, Equatable {
        /// Where the season comes from.
        public enum Calendar: Sendable, Equatable {
            /// **The real date**: the schedule's clock read as seconds since 1970, UTC.
            case date
            /// Always this season.
            case held(Season)
            /// **A game's own year**: seasons this many seconds long, the northern winter's middle at the clock's zero.
            case cycle(seasonLength: Double)
        }

        public var chances: [Season: [Weather.Kind: Float]]
        public var calendar: Calendar
        /// The southern hemisphere: winter in July.
        public var southern: Bool

        public init(chances: [Season: [Weather.Kind: Float]] = Self.standardChances, calendar: Calendar = .date,
                    southern: Bool = false) {
            var kept: [Season: [Weather.Kind: Float]] = [:]
            for season in Season.allCases {
                kept[season] = (chances[season] ?? [:]).compactMapValues { $0.isFinite && $0 > 0 ? $0 : nil }
            }
            self.chances = kept
            // A season of no length, or a minute's — a file can say anything — would divide the clock into nothing.
            if case .cycle(let length) = calendar {
                self.calendar = length.isFinite && length > 0 ? .cycle(seasonLength: max(length, Self.shortestSeason)) : .date
            } else {
                self.calendar = calendar
            }
            self.southern = southern
        }

        /// The shortest a game's season may be, seconds.
        public static let shortestSeason: Double = 60

        /// Snow and fog in winter, rain in spring, clear skies and storms in summer, rain and fog in autumn.
        public static let standardChances: [Season: [Weather.Kind: Float]] = [
            .winter: [.clear: 30, .overcast: 25, .snow: 30, .fog: 15],
            .spring: [.clear: 40, .overcast: 25, .rain: 30, .fog: 5],
            .summer: [.clear: 60, .overcast: 10, .rain: 15, .storm: 15],
            .autumn: [.clear: 30, .overcast: 30, .rain: 25, .fog: 15],
        ]

        /// Where in the year `time` is, 0…4: 0 winter's middle, 1 spring's, 2 summer's, 3 autumn's, part way between.
        public func position(at time: Double) -> Double {
            let p = unguardedPosition(at: time)
            // Never anything an `Int` cannot hold: a position that is not a number is winter's middle.
            return p.isFinite ? min(max(p, 0), 3.999_999) : 0
        }

        private func unguardedPosition(at time: Double) -> Double {
            let t = time.isFinite ? time : 0
            switch calendar {
            case .held(let season):
                return Double(Season.allCases.firstIndex(of: season) ?? 0)
            case .cycle(let length):
                // Counted, as the real date is, from the northern winter's middle: south of the equator it is summer then.
                return Self.wrapped(t / (4 * length) + (southern ? 0.5 : 0)) * 4
            case .date:
                // The middle of the northern winter is about the fifteenth of January; the year is 365.2422 days.
                let year = t / 86_400 / 365.2422
                return Self.wrapped(year - 14.0 / 365.2422 + (southern ? 0.5 : 0)) * 4
            }
        }

        /// The season `time` is nearest the middle of.
        public func season(at time: Double) -> Season {
            Season.allCases[Int(position(at: time).rounded()) % 4]
        }

        /// The two seasons `time` is between, and how far from the first's middle to the second's, 0…1.
        func between(at time: Double) -> (Season, Season, Float) {
            let p = position(at: time)
            let i = Int(p.rounded(.down)) % 4
            return (Season.allCases[i], Season.allCases[(i + 1) % 4], Float(p - p.rounded(.down)))
        }

        static func wrapped(_ x: Double) -> Double { x - x.rounded(.down) }
    }

    /// **The chances at `time`**: the seasons' mixed by where in the year it is, or ``chances`` without seasons.
    public func chances(at time: Double) -> [Weather.Kind: Float] {
        guard let seasons else { return chances }
        let (a, b, t) = seasons.between(at: time)
        func share(_ season: Season) -> [Weather.Kind: Float] {
            let raw = seasons.chances[season] ?? [:]
            let total = raw.values.reduce(0, +)
            return total > 0 ? raw.mapValues { $0 / total } : [.clear: 1]
        }
        let from = share(a), to = share(b)
        var mixed: [Weather.Kind: Float] = [:]
        for kind in Weather.Kind.allCases {
            let v = (from[kind] ?? 0) * (1 - t) + (to[kind] ?? 0) * t
            if v > 0 { mixed[kind] = v }
        }
        return mixed
    }

    /// **How warm it is at `time`**, 0 the middle of winter … 1 the middle of summer, mixed between; nil without seasons.
    public func warmth(at time: Double) -> Float? {
        guard let seasons else { return nil }
        let (a, b, t) = seasons.between(at: time)
        return a.warmth * (1 - t) + b.warmth * t
    }

    // MARK: Wet ground

    /// Gained a second in the heaviest rain: surfaces soaked in four minutes, puddles full in twenty-five.
    public static let surfaceWets: Double = 1.0 / 240
    public static let puddlesFill: Double = 1.0 / 1500
    /// Lost a second with no rain: surfaces dry in twenty minutes, puddles in an hour and a half — faster when warm.
    public static let surfaceDries: Double = 1.0 / 1200
    public static let puddlesDrain: Double = 1.0 / 5400
    /// How far back the wet is counted.
    public static let wetMemory: Double = 12 * 3600

    /// **How much faster things dry at a warmth**: 0.6 in the middle of winter … 3 in the middle of summer; one without
    /// seasons.
    public static func dryFactor(warmth: Float?) -> Double {
        guard let warmth else { return 1 }
        return 0.6 * pow(5, Double(min(max(warmth, 0), 1)))
    }

    /// **How wet the schedule has made things by `time`**: surfaces and puddles, each 0…1 — wetted in rain and storms as
    /// hard as they fall, dried after, faster when warm; counted over the last ``wetMemory`` from dry, so everyone with
    /// the clock has the same. The wet by the start of the spell under way is counted once and remembered, as snow is.
    public func builtWet(at time: Double) -> (surface: Float, puddles: Float) {
        guard time.isFinite, mayRain else { return (0, 0) }
        let now = spell(at: time)
        let start = WetLaid.shared.wet(of: self, atStartOf: now.index) { wetLaid(before: now) }
        let end = Self.wetted(start, in: now, for: max(time - now.start, 0), warmth: warmth(at: now.start))
        return (Float(end.surface), Float(end.puddles))
    }

    func wetLaid(before spell: Spell) -> (surface: Double, puddles: Double) {
        var t = spell.start - Self.wetMemory
        var each = self.spell(at: t)
        var wet = (surface: 0.0, puddles: 0.0)
        for _ in 0..<100_000 where each.index < spell.index {
            wet = Self.wetted(wet, in: each, for: max(min(each.end, spell.start) - t, 0), warmth: warmth(at: each.start))
            t = each.end
            each = self.spell(each.index + 1)
        }
        return wet
    }

    /// `wet` after `seconds` of `spell`: wetted as hard as it rains, else dried — snow wets nothing.
    static func wetted(_ wet: (surface: Double, puddles: Double), in spell: Spell, for seconds: Double,
                       warmth: Float?) -> (surface: Double, puddles: Double) {
        let falling = Weather.preset(spell.kind, severity: spell.severity)
        let p = falling.snow ? 0 : Double(falling.precipitation)
        if p > 0 {
            return (min(1, wet.surface + p * surfaceWets * seconds), min(1, wet.puddles + p * puddlesFill * seconds))
        }
        let dry = dryFactor(warmth: warmth)
        return (max(0, wet.surface - surfaceDries * dry * seconds), max(0, wet.puddles - puddlesDrain * dry * seconds))
    }

    /// Whether any chance, in any season, is rain or a storm.
    var mayRain: Bool {
        let wets: (Weather.Kind) -> Bool = { $0 == .rain || $0 == .storm }
        if let seasons { return seasons.chances.values.contains { $0.contains { wets($0.key) && $0.value > 0 } } || mayLaySnow }
        return chances.contains { wets($0.key) && $0.value > 0 } || (chances[.snow] ?? 0) > 0
    }

    /// **Settings part way from one to another.** Rain turning to snow, or back, eases off before the other begins, so
    /// it never falls as half of each.
    static func blend(_ a: Weather.Settings, _ b: Weather.Settings, _ t: Float) -> Weather.Settings {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        var falling = mix(a.precipitation, b.precipitation), snow = t < 0.5 ? a.snow : b.snow
        if a.snow != b.snow, a.precipitation > 0 || b.precipitation > 0 {
            falling = t < 0.5 ? a.precipitation * (1 - 2 * t) : b.precipitation * (2 * t - 1)
        } else if a.precipitation == 0 {
            snow = b.snow
        } else if b.precipitation == 0 {
            snow = a.snow
        }
        return Weather.Settings(cloudCover: mix(a.cloudCover, b.cloudCover), precipitation: falling, snow: snow,
                                windSpeed: mix(a.windSpeed, b.windSpeed), fogDensity: mix(a.fogDensity, b.fogDensity),
                                lightning: mix(a.lightning, b.lightning))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case isOn, chances, shortest, longest, change, lightest, heaviest, wander, seed, seasons
    }

    /// Seasons as a file has them: the calendar by name, a season's chances by name, so what this engine does not know is
    /// left out.
    private struct SeasonsFile: Codable {
        var calendar: String
        var seasonLength: Double?
        var southern: Bool?
        var chances: [String: [String: Float]]
    }

    /// The chances are written by name, so a kind this engine does not know is left out rather than failing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeatherSchedule()
        let named = (try? c.decodeIfPresent([String: Float].self, forKey: .chances)) ?? nil
        var chances: [Weather.Kind: Float] = [:]
        for (name, share) in named ?? [:] {
            if let kind = Weather.Kind(rawValue: name) { chances[kind] = share }
        }
        self.init(isOn: (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? d.isOn,
                  chances: named == nil ? d.chances : chances,
                  shortest: (try? c.decodeIfPresent(Double.self, forKey: .shortest)) ?? d.shortest,
                  longest: (try? c.decodeIfPresent(Double.self, forKey: .longest)) ?? d.longest,
                  change: (try? c.decodeIfPresent(Double.self, forKey: .change)) ?? d.change,
                  lightest: (try? c.decodeIfPresent(Float.self, forKey: .lightest)) ?? d.lightest,
                  heaviest: (try? c.decodeIfPresent(Float.self, forKey: .heaviest)) ?? d.heaviest,
                  wander: (try? c.decodeIfPresent(Float.self, forKey: .wander)) ?? d.wander,
                  seed: (try? c.decodeIfPresent(UInt32.self, forKey: .seed)) ?? d.seed,
                  seasons: (try? c.decodeIfPresent(SeasonsFile.self, forKey: .seasons)).flatMap { $0.map(Self.seasons(from:)) })
    }

    private static func seasons(from file: SeasonsFile) -> Seasons {
        var chances: [Season: [Weather.Kind: Float]] = [:]
        for (name, shares) in file.chances {
            guard let season = Season(rawValue: name) else { continue }
            var kept: [Weather.Kind: Float] = [:]
            for (kind, share) in shares { if let k = Weather.Kind(rawValue: kind) { kept[k] = share } }
            chances[season] = kept
        }
        let calendar: Seasons.Calendar = switch file.calendar {
        case "cycle": .cycle(seasonLength: file.seasonLength ?? 0)
        default: Season(rawValue: file.calendar).map { .held($0) } ?? .date
        }
        return Seasons(chances: chances, calendar: calendar, southern: file.southern ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOn, forKey: .isOn)
        try c.encode(Dictionary(uniqueKeysWithValues: chances.map { ($0.key.rawValue, $0.value) }), forKey: .chances)
        try c.encode(shortest, forKey: .shortest)
        try c.encode(longest, forKey: .longest)
        try c.encode(change, forKey: .change)
        try c.encode(lightest, forKey: .lightest)
        try c.encode(heaviest, forKey: .heaviest)
        try c.encode(wander, forKey: .wander)
        try c.encode(seed, forKey: .seed)
        if let seasons {
            let (calendar, length): (String, Double?) = switch seasons.calendar {
            case .date: ("date", nil)
            case .held(let season): (season.rawValue, nil)
            case .cycle(let seconds): ("cycle", seconds)
            }
            var chances: [String: [String: Float]] = [:]
            for (season, shares) in seasons.chances {
                chances[season.rawValue] = Dictionary(uniqueKeysWithValues: shares.map { ($0.key.rawValue, $0.value) })
            }
            try c.encode(SeasonsFile(calendar: calendar, seasonLength: length, southern: seasons.southern, chances: chances),
                         forKey: .seasons)
        }
    }
}

public nonisolated extension Weather {
    /// **The weather at `time`**: the schedule's when it has one and it is on, else this weather as set. What a game draws
    /// and hears each frame; `time` is the game's clock — ``realTime()`` unless it has its own, such as a server's.
    func current(at time: Double) -> Weather {
        guard let schedule, schedule.isOn else {
            // **Rain falling now wets what it falls on** — with no schedule there is no past to count, so the rain as set
            // wets as hard as it falls, puddles a little less.
            let s = settings
            guard s.precipitation > 0, !s.snow else { return self }
            var wet = self
            wet.wetness = max(wetness, s.precipitation)
            wet.puddles = max(wetness, s.precipitation * 0.7)
            return wet
        }
        return schedule.weather(at: time, under: self)
    }

    /// **The real-world time**, seconds since 1970 (UTC): the clock a schedule runs by when a game gives none, so everyone
    /// sees one sky without a server.
    static func realTime() -> Double { Date().timeIntervalSince1970 }
}


/// **The snow laid by the start of a spell, remembered** — ``WeatherSchedule/builtSnow(at:)`` asks every frame, and the
/// count behind it covers two days of spells. A few schedules' last answers, shared by every caller; the same schedule
/// and spell always give the same snow, so a remembered one is never wrong.
nonisolated final class SnowLaid: @unchecked Sendable {
    static let shared = SnowLaid()
    private let lock = NSLock()
    private var entries: [(schedule: WeatherSchedule, index: Int64, snow: Double)] = []

    func snow(of schedule: WeatherSchedule, atStartOf index: Int64, counting: () -> Double) -> Double {
        if let known = lock.withLock({ entries.first { $0.index == index && $0.schedule == schedule }?.snow }) { return known }
        let snow = counting()
        lock.withLock {
            entries.insert((schedule, index, snow), at: 0)
            if entries.count > 8 { entries.removeLast() }
        }
        return snow
    }
}

/// **The wet laid by the start of a spell**, remembered as ``SnowLaid`` remembers snow.
nonisolated final class WetLaid: @unchecked Sendable {
    static let shared = WetLaid()
    private let lock = NSLock()
    private var entries: [(schedule: WeatherSchedule, index: Int64, wet: (surface: Double, puddles: Double))] = []

    func wet(of schedule: WeatherSchedule, atStartOf index: Int64,
             counting: () -> (surface: Double, puddles: Double)) -> (surface: Double, puddles: Double) {
        if let known = lock.withLock({ entries.first { $0.index == index && $0.schedule == schedule }?.wet }) { return known }
        let wet = counting()
        lock.withLock {
            entries.insert((schedule, index, wet), at: 0)
            if entries.count > 8 { entries.removeLast() }
        }
        return wet
    }
}

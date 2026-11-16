//
//  WorldClock.swift
//  Ductane
//

import Foundation

/// **A world's clock** (owner, 2026-11-16): the time of day running by itself, the season turning on a game calendar,
/// and the latitude the sun moves at — all from one shared time, so every player sees the same hour and season. The
/// standard set: Ultra Dynamic Sky and Enviro run a day in a set number of real minutes, nights able to pass faster, and
/// a calendar of game days; Final Fantasy XIV's world runs one clock for everyone.
///
/// **The clock is a time a game gives**: ``Weather/realTime()`` unless it has its own, such as a server's — the same
/// clock a weather schedule runs by. ``sky(_:at:)`` sets a ``DaySky``'s hour, latitude and place in the year from it;
/// ``yearPosition(at:)`` and ``seasons`` give a weather schedule the same calendar.
public nonisolated struct WorldClock: Sendable, Equatable, Codable {

    /// **Where the season comes from.**
    public enum Calendar: Sendable, Equatable {
        /// **A game's own year**: each season this many game days, the middle of winter at the clock's zero.
        case days(perSeason: Double)
        /// Always this season.
        case held(WeatherSchedule.Season)
        /// The real date.
        case realDate
    }

    /// Whether the day runs. Off, the time of day stays as the sky sets it.
    public var runsDay: Bool
    /// **How long a game day lasts**, real seconds.
    public var dayLength: Double
    /// **How many times faster night passes than day**, 1 the same.
    public var nightSpeed: Double
    public var calendar: Calendar
    /// Degrees, north positive: the sun's path, and the hemisphere — winter falls in July south of the equator.
    public var latitude: Float
    /// **Foliage through the year** on this calendar (``FallColors``): trees turning, bare in winter, grass gone straw.
    public var foliage: FallColors
    /// **How many game days the moon takes from new to new** on a game calendar. Nil keeps it in step with the year — about
    /// 12 cycles a year, as the real one has (``moonAge(at:)``). The real-date calendar always has the real moon.
    public var moonCycle: Double?

    public init(runsDay: Bool = true, dayLength: Double = 3600, nightSpeed: Double = 2,
                calendar: Calendar = .days(perSeason: 7), latitude: Float = 45, foliage: FallColors = FallColors(),
                moonCycle: Double? = nil) {
        self.foliage = foliage
        self.moonCycle = moonCycle.flatMap { $0.isFinite ? min(max($0, 0.5), 400) : nil }
        self.runsDay = runsDay
        self.dayLength = dayLength.isFinite ? min(max(dayLength, Self.dayLengths.lowerBound), Self.dayLengths.upperBound) : 3600
        self.nightSpeed = nightSpeed.isFinite ? min(max(nightSpeed, 1), 8) : 2
        if case .days(let n) = calendar {
            self.calendar = .days(perSeason: n.isFinite ? min(max(n, 1), 365) : 7)
        } else {
            self.calendar = calendar
        }
        self.latitude = latitude.isFinite ? min(max(latitude, -89), 89) : 45
    }

    /// How short and how long a game day may be, real seconds: a minute to a real day.
    public static let dayLengths: ClosedRange<Double> = 60...86_400

    public var southern: Bool { latitude < 0 }

    // MARK: The day

    /// **The share of a game day's real time that is daytime**, six to six: nights `nightSpeed` times faster.
    var dayShare: Double { nightSpeed / (nightSpeed + 1) }

    /// **The hour at `time`**, 0…24 — `held` when the day does not run. Day (six to eighteen) and night each pass at their
    /// own pace through every game day; midnight at the clock's zero.
    public func timeOfDay(at time: Double, held: Float) -> Float {
        guard runsDay, time.isFinite else { return held }
        // Midnight, the middle of the night share, at the clock's zero.
        let cycle = Self.wrapped(time / dayLength + 0.5 * (1 + dayShare))
        // From six in the morning: the day share runs six to eighteen, the rest eighteen to six.
        let hours = cycle < dayShare ? 6 + 12 * cycle / dayShare : 18 + 12 * (cycle - dayShare) / (1 - dayShare)
        return Float(hours.truncatingRemainder(dividingBy: 24))
    }

    /// Game days since the clock's zero.
    public func gameDays(at time: Double) -> Double { time.isFinite ? time / dayLength : 0 }

    // MARK: The year

    /// **Where in the year `time` is**, 0…4 on the northern calendar, as ``DaySky/yearPosition`` reads it.
    public func yearPosition(at time: Double) -> Double {
        let p: Double
        switch calendar {
        case .days(let perSeason):
            p = Self.wrapped(gameDays(at: time) / (4 * perSeason)) * 4
        case .held(let season):
            let local = Double(WeatherSchedule.Season.allCases.firstIndex(of: season) ?? 0)
            p = Self.wrapped((local + (southern ? 2 : 0)) / 4) * 4
        case .realDate:
            p = WeatherSchedule.Seasons(calendar: .date).position(at: time)
        }
        return p.isFinite ? min(max(p, 0), 3.999_999) : 0
    }

    /// **The season at `time`** where the world is — south of the equator, half a year on from the north.
    public func season(at time: Double) -> WeatherSchedule.Season {
        let local = Self.wrapped((yearPosition(at: time) + (southern ? 2 : 0)) / 4) * 4
        return WeatherSchedule.Season.allCases[Int(local.rounded()) % 4]
    }

    /// **A weather schedule's seasons on this calendar**: the same chances, the clock's calendar and hemisphere.
    public func seasons(_ chances: [WeatherSchedule.Season: [Weather.Kind: Float]]) -> WeatherSchedule.Seasons {
        let calendar: WeatherSchedule.Seasons.Calendar = switch self.calendar {
        case .days(let perSeason): .cycle(seasonLength: perSeason * dayLength)
        case .held(let season): .held(season)
        case .realDate: .date
        }
        return WeatherSchedule.Seasons(chances: chances, calendar: calendar, southern: southern)
    }

    /// **The sky at `time`**: `base` with its hour, latitude and place in the year from the clock.
    public func sky(_ base: DaySky, at time: Double) -> DaySky {
        var sky = base
        sky.timeOfDay = timeOfDay(at: time, held: base.timeOfDay)
        sky.latitude = latitude
        sky.yearPosition = yearPosition(at: time)
        sky.moonAge = moonAge(at: time)
        return sky
    }

    /// **The moon's age at `time`**, 0 new … 0.5 full … 1 (``DaySky/moonAge``): the real moon on the real date; on a game
    /// calendar ``moonCycle`` game days a month, or in step with its year — 12.37 months a year, as the real one has — so
    /// the moon changes from night to night as the seasons run by fast; held in a season, a real month of game days.
    public func moonAge(at time: Double) -> Double {
        let month: Double
        switch calendar {
        case .realDate:
            // Days since a known new moon, 6 January 2000 18:14 UTC, over the synodic month.
            let days = (time - 947_182_440) / 86_400
            return Self.wrapped(days / 29.530_588)
        case .days(let perSeason): month = moonCycle ?? 4 * perSeason / Self.monthsAYear
        case .held: month = moonCycle ?? 29.530_588
        }
        return Self.wrapped(gameDays(at: time) / month)
    }

    static func wrapped(_ x: Double) -> Double { x - x.rounded(.down) }

    /// The moon's months in a real year.
    public static let monthsAYear = 12.368

    /// **Where foliage is in its year at `time`** (``FallColors/phase(yearPosition:southern:)``): 0 midsummer, 1 the
    /// middle of autumn, 2 of winter, 3 of spring, where the world is.
    public func foliagePhase(at time: Double) -> Float {
        FallColors.phase(yearPosition: yearPosition(at: time), southern: southern)
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case runsDay, dayLength, nightSpeed, calendar, daysPerSeason, latitude, foliage, moonCycle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorldClock()
        let name = (try? c.decodeIfPresent(String.self, forKey: .calendar)) ?? "days"
        let calendar: Calendar = switch name {
        case "realDate": .realDate
        case "days": .days(perSeason: (try? c.decodeIfPresent(Double.self, forKey: .daysPerSeason)) ?? 7)
        default: WeatherSchedule.Season(rawValue: name).map { .held($0) } ?? .days(perSeason: 7)
        }
        self.init(runsDay: (try? c.decodeIfPresent(Bool.self, forKey: .runsDay)) ?? d.runsDay,
                  dayLength: (try? c.decodeIfPresent(Double.self, forKey: .dayLength)) ?? d.dayLength,
                  nightSpeed: (try? c.decodeIfPresent(Double.self, forKey: .nightSpeed)) ?? d.nightSpeed,
                  calendar: calendar, latitude: (try? c.decodeIfPresent(Float.self, forKey: .latitude)) ?? d.latitude,
                  foliage: (try? c.decodeIfPresent(FallColors.self, forKey: .foliage)) ?? d.foliage,
                  moonCycle: (try? c.decodeIfPresent(Double.self, forKey: .moonCycle)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runsDay, forKey: .runsDay)
        try c.encode(dayLength, forKey: .dayLength)
        try c.encode(nightSpeed, forKey: .nightSpeed)
        switch calendar {
        case .days(let n):
            try c.encode("days", forKey: .calendar)
            try c.encode(n, forKey: .daysPerSeason)
        case .held(let season): try c.encode(season.rawValue, forKey: .calendar)
        case .realDate: try c.encode("realDate", forKey: .calendar)
        }
        try c.encode(latitude, forKey: .latitude)
        try c.encode(foliage, forKey: .foliage)
        try c.encodeIfPresent(moonCycle, forKey: .moonCycle)
    }
}

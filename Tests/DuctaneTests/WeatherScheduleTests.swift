//
//  WeatherScheduleTests.swift
//  DuctaneTests
//

import Foundation
import Testing
@testable import Ductane

@Suite("Weather schedule")
struct WeatherScheduleTests {

    private static let base = Weather(kind: .overcast, severity: 0.3, windHeading: 90, seed: 9,
                                      schedule: WeatherSchedule(seed: 42))
    /// A moment in real time, seconds since 1970: a schedule must work there as at zero.
    private static let now: Double = 1_794_787_000

    @Test("The weather at a moment is the same whoever asks, at zero or years into real time; another seed differs")
    func deterministic() throws {
        let schedule = try #require(Self.base.schedule)
        for t in [0, 12_345.6, Self.now, Self.now + 86_400 * 365] {
            #expect(Self.base.current(at: t) == Self.base.current(at: t))
            #expect(schedule.spell(at: t) == WeatherSchedule(seed: 42).spell(at: t))
        }
        let other = WeatherSchedule(seed: 43)
        let differs = (0..<50).contains { other.spell(Int64($0)).kind != schedule.spell(Int64($0)).kind }
        #expect(differs)
    }

    @Test("Every spell lasts between the shortest and the longest, and the spells follow on with no gap")
    func lengths() {
        let schedule = WeatherSchedule(shortest: 300, longest: 1500, seed: 3)
        let spells = schedule.spells(from: Self.now, to: Self.now + 86_400 * 7)
        #expect(spells.count > 100)
        for (a, b) in zip(spells, spells.dropFirst()) {
            #expect(a.end == b.start && b.index == a.index + 1)
            #expect(a.end - a.start >= 300 - 1e-6 && a.end - a.start <= 1500 + 1e-6)
        }
        // The spell found at a time holds it.
        for t in stride(from: Self.now, to: Self.now + 20_000, by: 137) {
            let spell = schedule.spell(at: t)
            #expect(spell.start <= t && t < spell.end)
        }
    }

    @Test("Kinds come about as often as their chances say; a kind with no chance never comes")
    func chances() {
        let schedule = WeatherSchedule(chances: [.clear: 50, .rain: 30, .snow: 20], seed: 11)
        var counts: [Weather.Kind: Int] = [:]
        for i in 0..<4000 { counts[schedule.spell(Int64(i)).kind, default: 0] += 1 }
        #expect(abs(Double(counts[.clear] ?? 0) / 4000 - 0.5) < 0.04)
        #expect(abs(Double(counts[.rain] ?? 0) / 4000 - 0.3) < 0.04)
        #expect(abs(Double(counts[.snow] ?? 0) / 4000 - 0.2) < 0.04)
        #expect(counts[.storm] == nil && counts[.fog] == nil && counts[.overcast] == nil)
        #expect(WeatherSchedule(chances: [:]).spell(at: 100).kind == .clear)
    }

    @Test("Each spell is as heavy as a pick within the range, and the wind turns no further than it may")
    func severityAndWind() {
        let schedule = WeatherSchedule(lightest: 0.3, heaviest: 0.6, wander: 20, seed: 5)
        let spells = (0..<500).map { schedule.spell(Int64($0)) }
        #expect(spells.allSatisfy { (0.3...0.6).contains($0.severity) && abs($0.windTurn) <= 20 })
        #expect(Set(spells.map { Int($0.severity * 100) }).count > 10, "not one severity")
        for spell in spells.prefix(40) where spell.end - spell.start > schedule.change + 1 {
            let w = schedule.weather(at: spell.start + schedule.change + 0.5, under: Self.base)
            #expect(w.byHand == nil && w.kind == spell.kind && w.severity == spell.severity)
            #expect(abs(w.windHeading - (90 + spell.windTurn)) < 1e-3)
            #expect(w.seed == 9, "lightning keeps the weather's seed")
        }
    }

    @Test("A change blends from the spell before: no jump at a boundary, the new spell's own once the change is over")
    func blend() throws {
        let schedule = try #require(Self.base.schedule)
        var checked = 0
        for i in Int64(1_000)..<1_200 {
            let now = schedule.spell(i), before = schedule.spell(i - 1)
            guard now.kind != before.kind else { continue }
            let atStart = schedule.weather(at: now.start, under: Self.base).settings
            let justBefore = schedule.weather(at: now.start - 0.001, under: Self.base).settings
            #expect(abs(atStart.cloudCover - justBefore.cloudCover) < 0.01)
            #expect(abs(atStart.windSpeed - justBefore.windSpeed) < 0.05)
            #expect(abs(atStart.precipitation - justBefore.precipitation) < 0.01)
            let after = schedule.weather(at: now.start + schedule.change, under: Self.base).settings
            #expect(after == Weather.preset(now.kind, severity: now.severity))
            checked += 1
        }
        #expect(checked > 20)
        // Rain to snow eases off before snow begins: never both, never more than either end.
        let rain = Weather.preset(.rain, severity: 1), snow = Weather.preset(.snow, severity: 1)
        for step in 0...20 {
            let mid = WeatherSchedule.blend(rain, snow, Float(step) / 20)
            #expect(mid.precipitation <= max(rain.precipitation, snow.precipitation))
            #expect(mid.snow == (step >= 10))
        }
        #expect(WeatherSchedule.blend(rain, snow, 0.5).precipitation == 0)
    }

    @Test("Off, or none, the weather is as set; the real-time clock is now")
    func off() {
        var weather = Self.base
        weather.schedule?.isOn = false
        #expect(weather.current(at: Self.now) == weather)
        #expect(Weather.clear.current(at: Self.now) == .clear)
        #expect(abs(Weather.realTime() - Date().timeIntervalSince1970) < 5)
    }

    @Test("Settings out of range are brought in: a change no longer than the shortest spell, the range in order")
    func clamped() {
        let s = WeatherSchedule(shortest: 5, longest: 1, change: 900, lightest: 0.9, heaviest: 0.1, wander: 400)
        #expect(s.shortest == 60 && s.longest == 60 && s.change == 60)
        #expect(s.lightest == 0.9 && s.heaviest == 0.9 && s.wander == 180)
        #expect(WeatherSchedule(chances: [.rain: -3, .clear: .nan, .fog: 2]).chances == [.fog: 2])
    }

    @Test("Written and read back as it was, in a world file too; a kind this engine does not know is left out")
    func coding() throws {
        let data = try JSONEncoder().encode(Self.base)
        #expect(try JSONDecoder().decode(Weather.self, from: data) == Self.base)
        let world = WorldFile(name: "T", props: [], placements: [], weather: Self.base)
        let read = try JSONDecoder().decode(WorldFile.self, from: JSONEncoder().encode(world))
        #expect(read.weather == Self.base)
        let text = #"{"isOn":true,"chances":{"clear":2,"hail":5},"shortest":120}"#
        let odd = try JSONDecoder().decode(WeatherSchedule.self, from: Data(text.utf8))
        #expect(odd.chances == [.clear: 2] && odd.shortest == 120 && odd.longest == 1800)
        // A weather written before schedules reads with none.
        let old = try JSONDecoder().decode(Weather.self, from: Data(#"{"kind":"rain","severity":0.4}"#.utf8))
        #expect(old.schedule == nil && old.kind == .rain)
    }

    @Test("Snow builds in snow spells and melts after, faster in rain; never less than the snow set lying")
    func lyingSnow() throws {
        // Snow only: it builds to full and stays.
        let snowy = WeatherSchedule(chances: [.snow: 1], seed: 4)
        #expect(snowy.builtSnow(at: Self.now) == 1)
        // Clear only: none lies.
        #expect(WeatherSchedule(chances: [.clear: 1]).builtSnow(at: Self.now) == 0)
        // Snow then clear: find a snow spell followed by a clear one, and watch it build and melt.
        let mixed = WeatherSchedule(chances: [.snow: 1, .clear: 1, .rain: 1], shortest: 1800, longest: 3600, seed: 21)
        var found = false
        for i in Int64(400_000)..<400_400 {
            let a = mixed.spell(i), b = mixed.spell(i + 1)
            guard a.kind == .snow, b.kind != .snow else { continue }
            let start = mixed.builtSnow(at: a.start), peak = mixed.builtSnow(at: a.end)
            #expect(peak > start, "builds while it snows")
            let later = mixed.builtSnow(at: min(b.end, a.end + 1200))
            #expect(later < peak, "melts after")
            if b.kind == .rain {
                let melt = Double(peak - later) / min(b.end - a.end, 1200)
                #expect(melt > WeatherSchedule.snowMelts * 0.99, "rain melts faster")
            }
            found = true
            break
        }
        #expect(found)
        // The weather at a moment carries the amount; the snow set lying is the least it shows.
        var weather = Weather(lyingSnow: 0.4, snowDepth: true)
        weather.schedule = WeatherSchedule(chances: [.clear: 1])
        #expect(weather.current(at: Self.now).lyingSnow == 0.4 && weather.current(at: Self.now).snowDepth)
        weather.schedule = snowy
        #expect(weather.current(at: Self.now).lyingSnow == 1)
        // Without a schedule, the snow as set.
        #expect(Weather(lyingSnow: 0.7).current(at: Self.now).lyingSnow == 0.7)
        #expect(Weather(lyingSnow: 3).lyingSnow == 1 && Weather(lyingSnow: .nan).lyingSnow == 0)
        // The same for everyone.
        #expect(mixed.builtSnow(at: Self.now + 77) == mixed.builtSnow(at: Self.now + 77))
        // Written and read back; a weather from before snow has none.
        let read = try JSONDecoder().decode(Weather.self, from: JSONEncoder().encode(Weather(lyingSnow: 0.6, snowDepth: true)))
        #expect(read.lyingSnow == 0.6 && read.snowDepth)
        let old = try JSONDecoder().decode(Weather.self, from: Data(#"{"kind":"snow"}"#.utf8))
        #expect(old.lyingSnow == 0 && !old.snowDepth)
        // Low graphics turn the depth off.
        #expect(GraphicsSettings().snowDepth && !GraphicsSettings.Preset.low.settings.snowDepth)
    }
}

//
//  WorldClockTests.swift
//  DuctaneTests
//

import Foundation
import Testing
@testable import Ductane

@Suite("World clock and the sun by date")
struct WorldClockTests {

    @Test("The sun is high and the day long in summer, low and short in winter, at 45° north; reversed in the south")
    func sunByDate() throws {
        func noon(_ latitude: Float, _ year: Double) -> Float {
            DaySky.sunDirection(at: 12, latitude: latitude, yearPosition: year).elevation * 180 / .pi
        }
        #expect(abs(noon(45, 2) - 68.44) < 0.1 && abs(noon(45, 0) - 21.56) < 0.1 && abs(noon(45, 1) - 45) < 0.1)
        #expect(noon(-45, 0) > 60, "midwinter north is midsummer south")
        let summer = try #require(DaySky.daylight(latitude: 45, yearPosition: 2))
        let winter = try #require(DaySky.daylight(latitude: 45, yearPosition: 0))
        #expect(summer.set - summer.rise > 15 && winter.set - winter.rise < 9)
        #expect(DaySky.daylight(latitude: 80, yearPosition: 2) == nil, "the midnight sun")
        // East in the morning, south at noon, west in the evening — in the north.
        #expect(DaySky.sunDirection(at: 7, latitude: 45, yearPosition: 1).direction.x > 0)
        #expect(DaySky.sunDirection(at: 12, latitude: 45, yearPosition: 1).direction.z > 0.5)
        #expect(DaySky.sunDirection(at: 17, latitude: 45, yearPosition: 1).direction.x < 0)
        // In the south the noon sun is to the north.
        #expect(DaySky.sunDirection(at: 12, latitude: -45, yearPosition: 1).direction.z < -0.5)
        // Without a latitude, the engine's equinox day as before.
        #expect(DaySky(timeOfDay: 12).lighting == DaySky(timeOfDay: 12, yearPosition: 3).lighting)
        #expect(DaySky(timeOfDay: 12, latitude: 45, yearPosition: 2).lighting.elevation > DaySky(timeOfDay: 12).lighting.elevation)
    }

    @Test("A day runs in its length: midnight at zero, six and eighteen where the share says, nights faster")
    func day() {
        let clock = WorldClock(dayLength: 3600, nightSpeed: 2)
        #expect(abs(clock.timeOfDay(at: 0, held: 9) - 0) < 0.01 || abs(clock.timeOfDay(at: 0, held: 9) - 24) < 0.01)
        // Night is a third of the real hour: midnight to six takes ten minutes, six to noon twenty.
        #expect(abs(clock.timeOfDay(at: 600, held: 9) - 6) < 0.01)
        #expect(abs(clock.timeOfDay(at: 1800, held: 9) - 12) < 0.01)
        #expect(abs(clock.timeOfDay(at: 3000, held: 9) - 18) < 0.01)
        #expect(abs(clock.timeOfDay(at: 3600 * 5 + 1800, held: 9) - 12) < 0.01, "every day the same")
        var stopped = clock
        stopped.runsDay = false
        #expect(stopped.timeOfDay(at: 1234, held: 9) == 9)
        // No jump across the day.
        var last = clock.timeOfDay(at: 0, held: 0)
        for s in stride(from: 1.0, through: 3600, by: 1) {
            let now = clock.timeOfDay(at: s, held: 0)
            let step = (now - last + 24).truncatingRemainder(dividingBy: 24)
            #expect(step < 0.05)
            last = now
        }
    }

    @Test("The calendar: a season a set number of game days, held, or the real date; the south half a year on")
    func calendar() {
        let week = WorldClock(dayLength: 3600, calendar: .days(perSeason: 7))
        #expect(week.season(at: 0) == .winter)
        #expect(week.season(at: 7 * 3600) == .spring && week.season(at: 14 * 3600) == .summer && week.season(at: 28 * 3600) == .winter)
        let south = WorldClock(dayLength: 3600, calendar: .days(perSeason: 7), latitude: -30)
        #expect(south.season(at: 0) == .summer)
        let held = WorldClock(calendar: .held(.summer), latitude: -30)
        #expect(held.season(at: 99_999) == .summer && abs(held.yearPosition(at: 0) - 0) < 1e-9, "southern summer is northern winter")
        // A weather schedule on the same calendar has the same season.
        let seasons = week.seasons(WeatherSchedule.Seasons.standardChances)
        for t in stride(from: 0.0, to: 28 * 3600, by: 5000) { #expect(seasons.season(at: t) == week.season(at: t)) }
        #expect(WorldClock(calendar: .realDate).seasons([:]).calendar == .date)
        // The sky from the clock.
        let sky = week.sky(DaySky(timeOfDay: 9), at: 1800)
        #expect(sky.latitude == 45 && abs(sky.timeOfDay - 12) < 0.01)
    }

    @Test("Written and read back; a file can say anything and is brought in range")
    func coding() throws {
        for calendar: WorldClock.Calendar in [.days(perSeason: 3), .held(.autumn), .realDate] {
            let clock = WorldClock(runsDay: false, dayLength: 900, nightSpeed: 3, calendar: calendar, latitude: -12)
            #expect(try JSONDecoder().decode(WorldClock.self, from: JSONEncoder().encode(clock)) == clock)
        }
        let odd = #"{"dayLength":0.0001,"nightSpeed":1e9,"calendar":"monsoon","latitude":400}"#
        let read = try JSONDecoder().decode(WorldClock.self, from: Data(odd.utf8))
        #expect(read.dayLength == 60 && read.nightSpeed == 8 && read.latitude == 89 && read.calendar == .days(perSeason: 7))
        for t in [0, 1e300, -1e300, .infinity, .nan] {
            _ = read.timeOfDay(at: t, held: 3)
            #expect((0..<4).contains(read.yearPosition(at: t)))
        }
        // A world file carries it.
        let world = WorldFile(name: "T", props: [], placements: [], sky: WorldFile.Sky(clock: WorldClock()))
        #expect(try JSONDecoder().decode(WorldFile.self, from: JSONEncoder().encode(world)).sky.clock == WorldClock())
    }
}

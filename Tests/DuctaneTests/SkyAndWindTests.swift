//
//  SkyAndWindTests.swift
//  DuctaneTests
//

import Foundation
import Testing
import simd
@testable import Ductane

@Suite("Clouds, the night sky, wind and snow caps")
struct SkyAndWindTests {

    @Test("A clear sky has a few clouds, overcast nearly all; storms are dark; clouds drift with the wind and wrap")
    func clouds() {
        let clear = Weather.clear.clouds(at: 0)
        #expect(abs(clear.coverage - CloudLayer.fairWeather) < 1e-5)
        let overcast = Weather(kind: .overcast, severity: 1).clouds(at: 0)
        #expect(overcast.coverage > 0.9)
        #expect(Weather(kind: .storm, severity: 1).clouds(at: 0).darkness > 0.8)
        // Toward the heading: east at 90°.
        let east = Weather(kind: .clear, windHeading: 90).clouds(at: 100)
        // A hair below zero wraps to the far end of the period: the same place on the pattern.
        let north = min(abs(east.drift.y), Float(CloudLayer.period) - abs(east.drift.y))
        #expect(east.drift.x > 0 && north < 1)
        // Years on the clock stay inside one period.
        let far = Weather(kind: .storm, severity: 1).clouds(at: 1.8e9)
        #expect(abs(far.drift.x) <= Float(CloudLayer.period) && abs(far.drift.y) <= Float(CloudLayer.period))
    }

    @Test("Coverage is about the share of the sky covered, repeats every period, and casts shadows")
    func coverage() {
        func share(_ c: Float) -> Float {
            var covered: Float = 0
            for i in 0..<4096 {
                let p = SIMD2(Float(i % 64) * 960, Float(i / 64) * 960)
                covered += CloudLayer.coverage(at: p, coverage: c)
            }
            return covered / 4096
        }
        #expect(share(0.22) < 0.4)
        #expect(share(0.95) > 0.8)
        #expect(share(0.6) > share(0.3))
        let p = SIMD2<Float>(1234, 5678)
        #expect(abs(CloudLayer.coverage(at: p, coverage: 0.5)
                    - CloudLayer.coverage(at: p + SIMD2(Float(CloudLayer.period), 0), coverage: 0.5)) < 1e-3)
        let layer = CloudLayer(coverage: 0.5)
        let shadows = (0..<200).map { layer.shadow(at: SIMD3(Float($0) * 300, 0, 0), light: SIMD3(0, 1, 0)) }
        #expect(shadows.min()! < 0.6 && shadows.max()! > 0.99)
    }

    @Test("The moon: full opposite the sun without an age; new beside it; its light follows its phase")
    func moon() {
        var sky = DaySky(timeOfDay: 0)
        let full = sky.moonPosition
        #expect(full.illumination > 0.99)
        #expect(simd_dot(full.direction, sky.sunPosition.direction) < -0.99)
        sky.moonAge = 0
        #expect(sky.moonPosition.illumination < 0.01)
        sky.moonAge = 0.5
        let fullNight = sky.lighting.colour
        sky.moonAge = 0.02
        #expect(simd_reduce_max(sky.lighting.colour) < simd_reduce_max(fullNight))
        // By day the sun's light is the same whatever the moon.
        var day = DaySky(timeOfDay: 12)
        let noon = day.lighting.colour
        day.moonAge = 0
        #expect(day.lighting.colour == noon)
    }

    @Test("Stars show at night, not by day, and turn with the hours")
    func stars() {
        #expect(DaySky(timeOfDay: 0).night.stars > 0.99)
        #expect(DaySky(timeOfDay: 12).night.stars == 0)
        let a = DaySky(timeOfDay: 0).night.starRotation, b = DaySky(timeOfDay: 3).night.starRotation
        #expect(simd_length(a * SIMD3(1, 0, 0) - b * SIMD3(1, 0, 0)) > 0.1)
    }

    @Test("A game calendar's moon is in step with its year unless set; the real date has the real moon")
    func moonCycle() {
        let clock = WorldClock(dayLength: 600, calendar: .days(perSeason: 7))
        let month = 28 / WorldClock.monthsAYear
        #expect(abs(clock.moonAge(at: month * 600 * 0.5) - 0.5) < 1e-6)
        let set = WorldClock(dayLength: 600, calendar: .days(perSeason: 7), moonCycle: 10)
        #expect(abs(set.moonAge(at: 5 * 600) - 0.5) < 1e-6)
        // 2000-01-21 04:40 UTC, a full moon.
        let real = WorldClock(calendar: .realDate)
        #expect(abs(real.moonAge(at: 948_429_600) - 0.5) < 0.03)
        #expect(clock.sky(DaySky(), at: 0).moonAge != nil)
        let coded = try? JSONDecoder().decode(WorldClock.self, from: JSONEncoder().encode(set))
        #expect(coded?.moonCycle == 10)
    }

    @Test("What moves in the wind is guessed from a name")
    func sway() {
        #expect(Sway.guess(name: "SM_Env_Tree_Pine_01") == .tree)
        #expect(Sway.guess(name: "SM_Env_Tree_Dead_02") == .tree)
        #expect(Sway.guess(name: "SM_Env_Reeds_04") == .plant)
        #expect(Sway.guess(name: "SM_Env_Bush_01") == .plant)
        #expect(Sway.guess(name: "SM_Prop_Flag_01") == .cloth)
        #expect(Sway.guess(name: "SM_Bld_Awning_02") == .cloth)
        #expect(Sway.guess(name: "SM_Env_Log_01") == .still)
        #expect(Sway.guess(name: "SM_Prop_Crate_01") == .still)
        let wind = Weather(kind: .storm, severity: 1, sway: 0.5).foliageWind(at: 10)
        #expect(wind.y > 0.3 && wind.y < 0.7)
        #expect(Weather(sway: 0).foliageWind(at: 0).y == 0)
    }

    @Test("A snow cap covers what faces up, with a skirt round its open edges, and nothing for what does not")
    func snowCap() {
        // A flat square roof, two triangles, and a wall facing sideways.
        let roof: [SIMD3<Float>] = [SIMD3(0, 2, 0), SIMD3(0, 2, 1), SIMD3(1, 2, 1), SIMD3(0, 2, 0), SIMD3(1, 2, 1), SIMD3(1, 2, 0)]
        let wall: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 2, 0)]
        let cap = SnowCap.make(roof + wall)
        // Four welded corners and four open edges with two vertices at each end.
        #expect(cap.vertices.count == 4 + 4 * 4)
        #expect(cap.indices.count == 6 + 4 * 6)
        // The rim leans out; its top and its skirt's top lean the same way.
        let rim = cap.vertices.prefix(4)
        #expect(rim.allSatisfy { $0.push >= 1 && $0.lift > 0.5 })
        for corner in rim {
            let skirtTop = cap.vertices.dropFirst(4).first { $0.position == corner.position && $0.lift > 0 }
            #expect(skirtTop?.push == corner.push)
            // Outward: away from the roof's middle.
            #expect(simd_dot(corner.leaning, corner.position - SIMD3(0.5, 2, 0.5)) > 0)
        }
        #expect(SnowCap.make(wall).vertices.isEmpty)
    }

    @Test("A world file carries how props move, and what clouds and sway a world has")
    func worldFile() throws {
        var weather = Weather(kind: .overcast, cloudShape: CloudShape(height: 800, thickness: 600, speed: 2), sway: 1.4)
        let file = WorldFile(name: "W", props: ["a", "b"], sway: [1: .cloth], placements: [], weather: weather)
        let back = try WorldFile.read(JSONEncoder().encode(file))
        #expect(back.sway == [1: .cloth])
        #expect(back.weather?.cloudShape == weather.cloudShape && back.weather?.sway == 1.4)
        weather.schedule = WeatherSchedule()
        #expect(weather.current(at: 1000).cloudShape == weather.cloudShape)
    }
}

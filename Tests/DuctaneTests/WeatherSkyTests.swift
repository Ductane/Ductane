//
//  WeatherSkyTests.swift
//  DuctaneTests
//

import Foundation
import Testing
import simd
@testable import Ductane

@Suite("Lightning bolts, dust storms, rainbows, aurora and ground fog")
struct WeatherSkyTests {

    @Test("Strikes: some close, some in the clouds, each with its own number, the same for the same seed")
    func strikes() {
        let storm = Weather(kind: .storm, severity: 1, seed: 7)
        let all = storm.strikes(from: 0, to: 6 * 3600)
        #expect(all.count > 200)
        let close = all.filter(\.isClose), inCloud = all.filter(\.inCloud)
        #expect(Double(close.count) / Double(all.count) > 0.05 && Double(close.count) / Double(all.count) < 0.15)
        #expect(Double(inCloud.count) / Double(all.count) > 0.25)
        #expect(close.allSatisfy { simd_length($0.position) <= Weather.closeDistances.upperBound + 1 && !$0.inCloud })
        #expect(Set(all.map(\.seed)).count > all.count * 9 / 10)
        #expect(storm.strikes(from: 0, to: 6 * 3600) == all)
    }

    @Test("A bolt runs from the cloud base to where it lands, branching thinner and dimmer, the same every time")
    func bolt() throws {
        let strike = Weather.Strike(time: 0, position: SIMD2(100, 0), seed: 42)
        let landing = SIMD3<Float>(100, 3, 0)
        let bolt = LightningBolt.make(strike, cloudBase: 1500, landing: landing)
        #expect(bolt == LightningBolt.make(strike, cloudBase: 1500, landing: landing))
        let trunk = bolt.segments.filter { $0.brightness == 1 }
        #expect(trunk.count > 60)
        #expect(try #require(trunk.first).a.y >= 1500)
        #expect(simd_distance(try #require(trunk.last).b, landing) < 1e-3)
        // **Jagged at the scale it is seen at**: its path well longer than a straight line, and a good share of its
        // turns sharp — a bolt drawn nearly straight read as a generic streak (2026-11-20).
        let path = trunk.reduce(Float(0)) { $0 + simd_distance($1.a, $1.b) }
        #expect(path > simd_distance(try #require(trunk.first).a, landing) * 1.25)
        let turns = zip(trunk, trunk.dropFirst()).map { acos(min(simd_dot(simd_normalize($0.b - $0.a),
                                                                            simd_normalize($1.b - $1.a)), 1)) }
        #expect(Float(turns.filter { $0 > 0.35 }.count) > Float(turns.count) * 0.3)
        // **Branching**: several branches, and tips fading.
        #expect(bolt.segments.filter { $0.brightness < 1 }.count > 40)
        #expect(bolt.segments.contains { $0.brightness < 0.15 })
        // Within what a renderer draws for a few strikes at once (``WeatherRenderer/maxBoltSegments``).
        #expect(bolt.segments.count < WeatherRenderer.maxBoltSegments / 3, "\(bolt.segments.count) pieces")
        #expect(bolt.segments.contains { $0.brightness < 1 && $0.width < 1 })
        #expect(bolt != LightningBolt.make(Weather.Strike(time: 0, position: SIMD2(100, 0), seed: 43), cloudBase: 1500,
                                           landing: landing))
        // In the clouds: along under their base, never down to the ground.
        let sheet = LightningBolt.make(Weather.Strike(time: 0, position: .zero, inCloud: true, seed: 5), cloudBase: 1200,
                                       landing: .zero)
        #expect(sheet.segments.allSatisfy { min($0.a.y, $0.b.y) > 900 })
        #expect(strike.boltBrightness(after: 0) == 1 && strike.boltBrightness(after: 2) == 0)
    }

    @Test("A game's own strikes come with the seeded ones, under any sky, through a schedule, and are never saved")
    func addedStrikes() throws {
        var clear = Weather.clear
        let mine = Weather.Strike(time: 10, position: SIMD2(300, -400), seed: 9)
        clear.addedStrikes = [mine]
        #expect(clear.strikes(from: 9, to: 11) == [mine])
        #expect(clear.strikes(from: 10.5, to: 12).isEmpty)
        #expect(clear.flash(at: 10.05, seenFrom: .zero) > 0)
        var storm = Weather(kind: .storm, severity: 1)
        storm.addedStrikes = [mine]
        let both = storm.strikes(from: 0, to: 600)
        #expect(both.contains(mine) && both.count > 1)
        #expect(zip(both, both.dropFirst()).allSatisfy { $0.time <= $1.time })
        var scheduled = clear
        scheduled.schedule = WeatherSchedule()
        #expect(scheduled.current(at: 10).addedStrikes == [mine])
        let back = try JSONDecoder().decode(Weather.self, from: JSONEncoder().encode(clear))
        #expect(back.addedStrikes.isEmpty)
    }

    @Test("A dust storm: dust in the air, the sky its colour, the sun dimmed; its colour kept through a file and a schedule")
    func dust() throws {
        let storm = Weather(kind: .dust, severity: 1, dustColour: SIMD3(0.5, 0.2, 0.1))
        #expect(storm.settings.dust == 1 && storm.settings.precipitation == 0)
        #expect(storm.dustVolume == 1 && Weather.clear.dustVolume == 0)
        let day = DaySky(timeOfDay: 12).lighting
        let dusty = storm.lighting(day)
        #expect(dusty.horizon.x > dusty.horizon.z)
        #expect(simd_reduce_max(dusty.colour) < simd_reduce_max(day.colour))
        let back = try JSONDecoder().decode(Weather.self, from: JSONEncoder().encode(storm))
        #expect(back.dustColour == storm.dustColour)
        var scheduled = storm
        scheduled.schedule = WeatherSchedule()
        #expect(scheduled.current(at: 5000).dustColour == storm.dustColour)
    }

    @Test("A rainbow needs rain and the sun out, under 42°")
    func rainbow() {
        let shower = Weather(byHand: Weather.Settings(cloudCover: 0.4, precipitation: 0.5, snow: false, windSpeed: 2,
                                                      fogDensity: 0, lightning: 0, dust: 0))
        let low: Float = 20 * .pi / 180, high: Float = 60 * .pi / 180, set: Float = -5 * .pi / 180
        #expect(shower.rainbow(sunElevation: low) > 0.5)
        #expect(shower.rainbow(sunElevation: high) == 0)
        #expect(shower.rainbow(sunElevation: set) == 0)
        #expect(Weather.clear.rainbow(sunElevation: low) == 0)
        var snow = shower
        snow.byHand?.snow = true
        #expect(snow.rainbow(sunElevation: low) == 0)
    }

    @Test("Aurora: often near the poles, now and then at mid-latitudes, never near the equator; none without a clock")
    func aurora() {
        func nights(_ latitude: Float, amount: Float = 1) -> Int {
            (0..<1000).filter { n in
                var sky = DaySky(timeOfDay: 0)
                sky.latitude = latitude
                sky.nightNumber = n
                sky.aurora = amount
                return sky.auroraStrength > 0
            }.count
        }
        #expect(nights(70) > 650)
        #expect(nights(45) > 30 && nights(45) < 200)
        #expect(nights(10) == 0)
        #expect(nights(-70) > 650)
        #expect(nights(70, amount: 0) == 0)
        #expect(nights(10, amount: 2) == 1000)
        // Without a clock, the same night every night: none unless the world asks for more.
        var still = DaySky(timeOfDay: 0)
        still.latitude = 70
        #expect(still.auroraStrength == 0)
        still.aurora = 2
        #expect(still.auroraStrength > 0)
        // Only on a dark night.
        var noon = DaySky(timeOfDay: 12)
        noon.latitude = 70
        noon.aurora = 2
        #expect(noon.night.aurora == 0)
    }

    @Test("Ground fog comes before dawn and burns off by late morning, thick in fog weather, cleared by wind")
    func groundFog() {
        let calm = Weather()
        #expect(calm.groundFogDensity(hour: 6.5) > 0)
        #expect(calm.groundFogDensity(hour: 6.5) > calm.groundFogDensity(hour: 2))
        #expect(calm.groundFogDensity(hour: 14) == 0)
        #expect(calm.groundFogDensity(hour: 11) == 0)
        let fog = Weather(kind: .fog, severity: 1)
        #expect(fog.groundFogDensity(hour: 14) > calm.groundFogDensity(hour: 6.5) * 3)
        #expect(fog.groundFogDensity(hour: 14) <= GroundFog.thickest + 1e-6)
        let gale = Weather(byHand: Weather.Settings(cloudCover: 0, precipitation: 0, snow: false, windSpeed: 20,
                                                    fogDensity: Weather.fogDensities.upperBound, lightning: 0, dust: 0))
        #expect(gale.groundFogDensity(hour: 6.5) == 0)
        var none = fog
        none.groundFog.amount = 0
        #expect(none.groundFogDensity(hour: 6.5) == 0)
        var more = fog
        more.groundFog.amount = 2
        #expect(abs(more.groundFogDensity(hour: 14) - fog.groundFogDensity(hour: 14) * 2) < 1e-6)
        // After rain, more.
        var wet = calm
        wet.wetness = 1
        #expect(wet.groundFogDensity(hour: 14) > 0)
    }

    @Test("A world's ground fog travels through a file and a schedule")
    func groundFogKept() throws {
        let own = GroundFog(amount: 2.5, height: 12, colour: SIMD3(0.5, 0.7, 0.4))
        var weather = Weather(groundFog: own)
        let back = try JSONDecoder().decode(Weather.self, from: JSONEncoder().encode(weather))
        #expect(back.groundFog == own)
        weather.schedule = WeatherSchedule()
        #expect(weather.current(at: 9000).groundFog == own)
        #expect(GroundFog(amount: 9, height: -1).amount == GroundFog.amounts.upperBound)
        #expect(GroundFog(amount: 9, height: -1).height == GroundFog.heights.lowerBound)
        let file = try JSONDecoder().decode(GroundFog.self, from: Data("{}".utf8))
        #expect(file == GroundFog())
    }

    @Test("The fog's floor is the ground smoothed: lower in a hollow than on a rise, water at its level")
    func floor() {
        // 65 points a side, a metre apart: a hollow 10 m deep at one side, a rise 10 m high at the other.
        let n = 65
        var heights = [Float](repeating: 0, count: n * n)
        var water = [Float?](repeating: nil, count: n * n)
        for z in 0..<n {
            for x in 0..<n {
                let i = z * n + x
                if x < 12 { heights[i] = -10 }
                if x > 52 { heights[i] = 10 }
                if x < 6 { water[i] = -4 }
            }
        }
        let floor = FogFloor(heights: heights, side: n, spacing: 4, corner: SIMD2(-128, -128), water: water)
        let hollow = floor.height(at: SIMD2(-120, 0)), rise = floor.height(at: SIMD2(120, 0))
        #expect(hollow < rise)
        // The rise's floor sits below its top, so fog thins on it; the hollow's sits above its bottom, so fog fills it.
        #expect(rise < 10 && hollow > -10)
        #expect(floor.water[(n / 2) * floor.side] > 0.3)
        #expect(floor.water[(n / 2) * floor.side + floor.side - 1] == 0)
    }

    @Test("The sky reads the volume where the world's fog has hidden most of what is behind, or at its far end")
    func skyDistance() {
        #expect(VolumetricFog.skyDistance(fogDensity: 0, fogStart: 10) == VolumetricFog.far)
        let d = VolumetricFog.skyDistance(fogDensity: 0.01, fogStart: 20)
        #expect(abs(d - 125) < 0.01)
        #expect(VolumetricFog.grid(.low) == nil)
        #expect(VolumetricFog.grid(.high)!.pixels < VolumetricFog.grid(.medium)!.pixels)
        #expect(GraphicsSettings.Preset.low.settings.fog == .low)
        #expect(GraphicsSettings.Preset.high.settings.fog == .high)
    }
}

/// **A storm is the heaviest weather and looks it** (2026-11-21): darker and thicker-aired than rain at every severity,
/// whatever its wind does to lying mist — it drew clearer than a shower, its wind having blown rain's mist away.
@Test func aStormIsDarkerAndThickerThanRain() {
    let noon = DaySky(timeOfDay: 12).lighting
    func brightness(_ l: DaySky.Lighting) -> Float { simd_reduce_add(l.horizon + l.zenith + l.skyLight + l.colour) }
    for severity in stride(from: Float(0), through: 1, by: 0.25) {
        let rain = Weather(kind: .rain, severity: severity), storm = Weather(kind: .storm, severity: severity)
        #expect(brightness(storm.lighting(noon)) < brightness(rain.lighting(noon)) * 0.9, "severity \(severity)")
        #expect(storm.settings.fogDensity > rain.settings.fogDensity, "severity \(severity)")
        #expect(storm.groundFogDensity(hour: 14) >= rain.groundFogDensity(hour: 14), "severity \(severity)")
    }
    // A gale does not clear the rain out of the air; it does clear dry mist.
    let windyRain = Weather(byHand: Weather.Settings(cloudCover: 1, precipitation: 1, snow: false, windSpeed: 20,
                                                     fogDensity: 0, lightning: 0, dust: 0))
    #expect(windyRain.groundFogDensity(hour: 14) > 0)
    let windySnow = Weather(byHand: Weather.Settings(cloudCover: 1, precipitation: 1, snow: true, windSpeed: 20,
                                                     fogDensity: 0, lightning: 0, dust: 0))
    #expect(windySnow.groundFogDensity(hour: 14) == 0)
    // Clear weather is still exactly as it was.
    #expect(Weather().lighting(noon) == noon)
}

/// **Exposure follows the hour, not the cloud** (2026-11-21): a storm's dark sky opened the exposure two stops and drew it as
/// bright as a clear day. Cloud opens it at most ``Weather/cloudExposure``; a clear sky not at all.
@Test func exposureFollowsTheHourNotTheCloud() {
    let noon = DaySky(timeOfDay: 12).lighting
    let storm = Weather(kind: .storm, severity: 1).lighting(noon)
    #expect(Weather.exposureStops(under: noon, clear: noon) == noon.exposureStops)
    let opened = Weather.exposureStops(under: storm, clear: noon) - noon.exposureStops
    #expect(opened > 0 && opened <= Weather.cloudExposure + 1e-6)
    #expect(storm.exposureStops - noon.exposureStops > 1)   // what it was: well over a stop
    // Night keeps its own adjustment.
    let night = DaySky(timeOfDay: 1).lighting
    #expect(Weather.exposureStops(under: night, clear: night) == night.exposureStops)
}

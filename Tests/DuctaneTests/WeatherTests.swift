//
//  WeatherTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import Testing
import simd
@testable import Ductane

@Suite("Weather")
struct WeatherTests {

    // MARK: Presets

    @Test("A heavier preset rains harder and clouds more; clear has neither; a storm has lightning")
    func presets() {
        for kind in Weather.Kind.allCases {
            let light = Weather.preset(kind, severity: 0), heavy = Weather.preset(kind, severity: 1)
            #expect(heavy.cloudCover >= light.cloudCover, "\(kind)")
            #expect(heavy.precipitation >= light.precipitation, "\(kind)")
            #expect(heavy.windSpeed >= light.windSpeed, "\(kind)")
        }
        let clear = Weather.preset(.clear, severity: 1)
        #expect(clear.precipitation == 0 && clear.lightning == 0 && clear.fogDensity == 0)
        #expect(Weather.preset(.storm, severity: 0.5).lightning > 0)
        #expect(Weather.preset(.rain, severity: 0.5).lightning == 0)
        #expect(Weather.preset(.snow, severity: 0.5).snow)
        #expect(!Weather.preset(.rain, severity: 0.5).snow)
        #expect(Weather.preset(.fog, severity: 1).fogDensity > Weather.preset(.overcast, severity: 1).fogDensity)
        // Severity out of range is held in it.
        #expect(Weather(kind: .rain, severity: 4).severity == 1)
        #expect(Weather(kind: .rain, severity: .nan).severity == 0.5)
    }

    @Test("Settings by hand win over the kind, and are held in their ranges")
    func byHand() {
        let hand = Weather.Settings(cloudCover: 2, precipitation: 0.3, snow: true, windSpeed: 99, fogDensity: -1,
                                    lightning: 100)
        #expect(hand.cloudCover == 1 && hand.windSpeed == Weather.windSpeeds.upperBound && hand.fogDensity == 0)
        #expect(hand.lightning == Weather.lightningRates.upperBound)
        let weather = Weather(kind: .clear, byHand: hand)
        #expect(weather.settings == hand)
        #expect(weather.rainVolume == 0, "snow is not rain")
    }

    @Test("The wind blows toward its heading")
    func wind() {
        let east = Weather(kind: .storm, severity: 1, windHeading: 90).wind
        #expect(east.x > 15 && abs(east.z) < 0.01 && east.y == 0)
        let north = Weather(kind: .storm, severity: 1, windHeading: 0).wind
        #expect(north.z < -15 && abs(north.x) < 0.01)
    }

    // MARK: Light

    private let noon = DaySky(timeOfDay: 12).lighting

    @Test("Clouds dim the sun and grey the sky, without darkening the world to black")
    func clouds() {
        let clear = Weather.clear.lighting(noon)
        #expect(clear.colour == noon.colour, "a clear sky changes nothing")
        let overcast = Weather(kind: .overcast, severity: 1).lighting(noon)
        #expect(overcast.colour.max() < noon.colour.max() * 0.3, "the sun mostly gone: \(overcast.colour)")
        func saturation(_ c: SIMD3<Float>) -> Float { (c.max() - c.min()) / max(c.max(), 1e-6) }
        #expect(saturation(overcast.zenith) < saturation(noon.zenith) * 0.4, "grey: \(overcast.zenith) against \(noon.zenith)")
        #expect(Weather.luminance(overcast.skyLight) > Weather.luminance(noon.skyLight) * 0.6,
                "an overcast day is dim, not dark")
        let rain = Weather(kind: .rain, severity: 1).lighting(noon)
        #expect(Weather.luminance(rain.skyLight) < Weather.luminance(overcast.skyLight), "rain darker still")
        #expect(overcast.direction == noon.direction, "shadows still fall the same way")
    }

    @Test("Lightning's flash lights the sky")
    func flashLight() {
        let storm = Weather(kind: .storm, severity: 1)
        let dark = storm.lighting(noon), lit = storm.lighting(noon, flash: 1)
        #expect(Weather.luminance(lit.skyLight) > Weather.luminance(dark.skyLight) + 1)
        #expect(Weather.luminance(lit.horizon) > Weather.luminance(dark.horizon) + 1)
    }

    @Test("Weather's fog thickens the world's, and never thins it")
    func fog() {
        let fog = Weather(kind: .fog, severity: 1)
        #expect(fog.fogDensity(over: 0) == fog.settings.fogDensity)
        #expect(fog.fogDensity(over: 0.01) > 0.01)
        #expect(Weather.clear.fogDensity(over: 0.004) == 0.004)
    }

    // MARK: Lightning

    private let storm = Weather(kind: .storm, byHand: Weather.Settings(cloudCover: 1, precipitation: 1, lightning: 6),
                                seed: 7)

    @Test("Strikes are the same however the time is cut up, and different for another seed")
    func strikesAgree() {
        let whole = storm.strikes(from: 0, to: 600)
        var pieces: [Weather.Strike] = []
        var t = 0.0
        while t < 600 { pieces += storm.strikes(from: t, to: min(t + 0.016, 600)); t += 0.016 }
        #expect(!whole.isEmpty)
        #expect(pieces == whole)
        var other = storm
        other.seed = 8
        #expect(other.strikes(from: 0, to: 600) != whole)
        #expect(Weather(kind: .rain).strikes(from: 0, to: 600).isEmpty)
    }

    @Test("About as many strikes as the rate says, at the distances lightning keeps")
    func strikeRate() {
        let hour = storm.strikes(from: 0, to: 3600)
        #expect(abs(Float(hour.count) - 360) < 60, "\(hour.count) in an hour at 6 a minute")
        for strike in hour {
            let d = simd_length(strike.position)
            // Far ones out at lightning's distances; a close one within the world (``Weather/closeDistances``).
            let span = strike.isClose ? Weather.closeDistances : Weather.strikeDistances
            #expect(span.contains(d) || abs(d - span.upperBound) < 0.01)
        }
        #expect(zip(hour, hour.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test("Thunder takes as long as sound does, quieter far off; a flash fades and is gone")
    func thunderAndFlash() {
        let strike = Weather.Strike(time: 10, position: SIMD2(686, 0))
        #expect(abs(strike.thunderDelay(heardFrom: .zero) - 2) < 1e-6)
        #expect(strike.thunderVolume(heardFrom: SIMD3(600, 0, 0)) == 1)
        #expect(strike.thunderVolume(heardFrom: SIMD3(-2500, 0, 0)) < 0.3)
        #expect(strike.flash(after: 0, seenFrom: .zero) > 0.5)
        #expect(strike.flash(after: 0.4, seenFrom: .zero) < 0.1)
        #expect(strike.flash(after: 1, seenFrom: .zero) == 0)
        #expect(strike.flash(after: -0.1, seenFrom: .zero) == 0)
        let first = storm.strikes(from: 0, to: 600)[0]
        #expect(storm.flash(at: first.time + 0.01, seenFrom: .zero) > 0)
    }

    // MARK: Files

    @Test("Written and read back; what is left out, or unknown, is the default")
    func coding() throws {
        let weather = Weather(kind: .snow, severity: 0.7, windHeading: 200,
                              byHand: Weather.Settings(cloudCover: 0.5, precipitation: 0.4, snow: true, windSpeed: 3),
                              seed: 42)
        let data = try JSONEncoder().encode(weather)
        #expect(try JSONDecoder().decode(Weather.self, from: data) == weather)
        #expect(try JSONDecoder().decode(Weather.self, from: Data("{}".utf8)) == Weather())
        let unknown = try JSONDecoder().decode(Weather.self, from: Data(#"{"kind":"hail","severity":0.9}"#.utf8))
        #expect(unknown.kind == .clear && unknown.severity == 0.9)
    }

    @Test("A world file carries its weather and the weather's sounds; one without has none")
    func worldFile() throws {
        var file = WorldFile(name: "Wet", props: [], placements: [])
        file.weather = Weather(kind: .storm, severity: 0.8)
        file.sounds = WorldFile.Sounds(files: ["rain.caf", "wind.caf", "thunder.caf"],
                                       weather: .init(rain: 0, wind: 1, thunder: [2], volume: 0.7))
        let read = try JSONDecoder().decode(WorldFile.self, from: JSONEncoder().encode(file))
        #expect(read.weather == file.weather)
        #expect(read.sounds?.weather == file.sounds?.weather)
        #expect(read.sounds?.named.sorted() == [0, 1, 2])
        #expect(read.sounds?.isEmpty == false)
        let bare = try JSONDecoder().decode(WorldFile.self, from: Data(#"{"name":"Dry","props":[],"placements":[]}"#.utf8))
        #expect(bare.weather == nil)
    }

    // MARK: Cover

    @Test("The cover looks straight down: its top is depth 1, its floor depth 0, the eye in the middle")
    func coverMatrix() {
        let m = WeatherCover.matrix(centre: SIMD2(10, -4), halfExtent: 24, top: 50)
        let top = m * SIMD4<Float>(10, 50, -4, 1), floor = m * SIMD4<Float>(10, 50 - WeatherCover.depthRange, -4, 1)
        #expect(abs(top.z - 1) < 1e-5 && abs(floor.z) < 1e-5)
        #expect(abs(top.x) < 1e-5 && abs(top.y) < 1e-5)
        let east = m * SIMD4<Float>(34, 0, -4, 1), north = m * SIMD4<Float>(10, 0, -28, 1)
        #expect(abs(east.x - 1) < 1e-5)
        #expect(abs(north.y - 1) < 1e-5, "north is up")
    }

    @Test("The cover keeps to whole texels as the eye moves, and reads heights back")
    @MainActor
    func coverSnaps() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let cover = try WeatherCover(device: device, resolution: 256, halfExtent: 16)
        let a = cover.update(around: SIMD3(1.01, 0, 2.02)), b = cover.update(around: SIMD3(1.02, 0, 2.03))
        #expect(a == b, "a hundredth of a metre is inside one texel")
        cover.update(around: SIMD3(0, 3, 0))
        #expect(abs(cover.height(atDepth: 1) - cover.top) < 1e-4)
        #expect(abs(cover.height(atDepth: 0) - (cover.top - WeatherCover.depthRange)) < 1e-3)
    }

    // MARK: Drawing

    private final class Draws: GameLoop {
        let renderer: WeatherRenderer
        let weather: Weather
        var drew = false
        init(_ renderer: WeatherRenderer, _ weather: Weather) {
            self.renderer = renderer
            self.weather = weather
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let eye = SIMD3<Float>(0, 1.7, 0)
            let view = Camera(position: eye, yaw: 0, pitch: 0).viewMatrix
            let projection = simd_float4x4(perspectiveFovY: 60 * .pi / 180, aspectRatio: 1, nearZ: 0.1)
            let light = weather.lighting(DaySky(timeOfDay: 12).lighting)
            drew = renderer.draw(weather, into: encoder, frameSlot: frameSlot, viewProjection: projection * view,
                                 eye: eye, time: 3, lighting: light, pixelAngle: 1.05 / 64)
        }
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @MainActor
    private func brightness(of weather: Weather, device: MTLDevice) throws -> (sum: Int, drew: Bool) {
        let frames = try FrameRenderer(device: device)
        let renderer = try WeatherRenderer(device: device, sampleCount: frames.effectiveSampleCount)
        frames.residencySet.addAllocations(renderer.allocations)
        let game = Draws(renderer, weather)
        frames.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        frames.residencySet.addAllocation(target)
        frames.commitResidency()
        frames.render(into: target)
        var p = [UInt8](repeating: 0, count: 64 * 64 * 4)
        target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return (p.reduce(0) { $0 + Int($1) }, game.drew)
    }

    /// Rain over flat ground under a cover, seen straight down from a camera that stays put while `eye` — where the
    /// drops and splashes are made round — is wherever it is given.
    private final class Splashes: GameLoop {
        let renderer: WeatherRenderer
        let cover: WeatherCover
        let eye: SIMD3<Float>
        init(_ renderer: WeatherRenderer, _ cover: WeatherCover, eye: SIMD3<Float>) {
            self.renderer = renderer
            self.cover = cover
            self.eye = eye
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {
            cover.update(around: eye)
            // Flat ground at height 0 everywhere: the depth that reads back as it.
            let descriptor = MTL4RenderPassDescriptor()
            let attachment = MTLRenderPassDepthAttachmentDescriptor()
            attachment.texture = cover.texture
            attachment.loadAction = .clear
            attachment.clearDepth = Double(1 - (cover.top - 0) / WeatherCover.depthRange)
            attachment.storeAction = .store
            descriptor.depthAttachment = attachment
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let camera = SIMD3<Float>(0, 6, 0)
            let view = Camera(position: camera, yaw: 0, pitch: -Camera.pitchLimit).viewMatrix
            let projection = simd_float4x4(perspectiveFovY: 70 * .pi / 180, aspectRatio: 1, nearZ: 0.1)
            let weather = Weather(kind: .rain, severity: 1)
            renderer.draw(weather, into: encoder, frameSlot: frameSlot, viewProjection: projection * view, eye: eye,
                          time: 3.1, lighting: weather.lighting(DaySky(timeOfDay: 12).lighting), cover: cover,
                          pixelAngle: 1.2 / 256, brightness: 8)
        }
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @MainActor
    private func splashPixels(eye: SIMD3<Float>, device: MTLDevice) throws -> Set<Int> {
        let frames = try FrameRenderer(device: device)
        let renderer = try WeatherRenderer(device: device, sampleCount: frames.effectiveSampleCount)
        let cover = try WeatherCover(device: device)
        frames.residencySet.addAllocations(renderer.allocations)
        frames.residencySet.addAllocations(cover.allocations)
        let game = Splashes(renderer, cover, eye: eye)
        frames.game = game
        let size = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: size, height: size, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        frames.residencySet.addAllocation(target)
        frames.commitResidency()
        frames.render(into: target)
        var p = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&p, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let background = p[0..<4].map(Int.init)
        var lit = Set<Int>()
        for i in 0..<(size * size) where (0..<3).contains(where: { abs(Int(p[i * 4 + $0]) - background[$0]) > 6 }) {
            lit.insert(i)
        }
        return lit
    }

    @Test("A splash stays where its drop landed while the eye moves on")
    @MainActor
    func splashesStay() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let a = try splashPixels(eye: SIMD3(0, 1.7, 0), device: device)
        let b = try splashPixels(eye: SIMD3(0.5, 1.7, 0.3), device: device)
        #expect(a.count > 200, "something drew: \(a.count)")
        let overlap = Double(a.intersection(b).count) / Double(max(a.union(b).count, 1))
        #expect(overlap > 0.6, "the same pixels with the eye half a metre on: \(overlap), \(a.count) and \(b.count) lit")
    }

    @Test("Rain and snow draw over the scene; a clear sky draws nothing")
    @MainActor
    func draws() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let clear = try brightness(of: .clear, device: device)
        #expect(!clear.drew)
        let rain = try brightness(of: Weather(kind: .rain, severity: 1), device: device)
        #expect(rain.drew)
        #expect(rain.sum > clear.sum + 2_000, "rain: \(rain.sum) against \(clear.sum)")
        let snow = try brightness(of: Weather(kind: .snow, severity: 1), device: device)
        #expect(snow.drew)
        #expect(snow.sum > clear.sum + 2_000, "snow: \(snow.sum) against \(clear.sum)")
        #expect(WeatherRenderer.counts(Weather(kind: .rain, severity: 1)).splashes > 0)
        #expect(WeatherRenderer.counts(Weather(kind: .snow, severity: 1)).splashes == 0)
        #expect(WeatherRenderer.counts(Weather(kind: .overcast)).falling == 0)
    }
}

/// **The weather heard** through ``Soundscape``: rain and wind as heavy as it is, thunder after each strike.
@MainActor
@Suite("Weather — sound")
struct WeatherSoundTests {

    private static let rate = 48_000.0

    private func scape() async throws -> (Soundscape, AudioEngine) {
        let audio = try AudioEngine(offlineSampleRate: Self.rate)
        var state: UInt32 = 99
        let noise = (0..<24_000).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
        for name in ["rain", "wind", "thunder"] { try audio.load(name, samples: noise, sampleRate: Self.rate) }
        let scape = Soundscape(audio: audio)
        await scape.play(WorldFile.Sounds(files: ["rain", "wind", "thunder"],
                                          weather: .init(rain: 0, wind: 1, thunder: [2], volume: 1))) {
            URL(filePath: "/nonexistent/\($0)")
        }
        return (scape, audio)
    }

    @Test("Rain and wind play as beds in rain, and stop when it clears")
    func beds() async throws {
        let (scape, _) = try await scape()
        scape.setWeather(Weather(kind: .rain, severity: 1), at: 0)
        scape.update(listener: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), elapsed: 0.016)
        #expect(scape.playingCount == 2)
        scape.setWeather(Weather(kind: .snow, severity: 1), at: 1)
        #expect(scape.playingCount == 1, "snow has wind, not rain")
        scape.setWeather(.clear, at: 2)
        #expect(scape.playingCount == 0)
    }

    @Test("Thunder is sent on its way at each strike and heard once sound has covered the distance")
    func thunder() async throws {
        let (scape, _) = try await scape()
        let storm = Weather(kind: .storm, byHand: Weather.Settings(cloudCover: 1, lightning: 12), seed: 3)
        let first = try #require(storm.strikes(from: 0.5, to: 600).first)
        let delay = first.thunderDelay(heardFrom: .zero)
        var t = 0.0
        func step(to end: Double) {
            while t < end {
                t += 0.05
                scape.setWeather(storm, at: t)
                scape.update(listener: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), elapsed: 0.05)
            }
        }
        step(to: first.time + 0.1)
        #expect(scape.thundersOnTheirWay >= 1, "the first strike's thunder is on its way")
        step(to: first.time + delay + 0.1)
        let later = storm.strikes(from: first.time + 0.01, to: t + 0.001).count
        #expect(scape.thundersOnTheirWay <= later, "the first has arrived")
    }
}

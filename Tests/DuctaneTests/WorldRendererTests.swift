//
//  WorldRendererTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import Testing
import ImageIO
import CoreGraphics
import simd
@testable import Ductane

/// **A world drawn**: a scene package turned into what ``WorldRenderer`` draws (``WorldScene``), its ground written as
/// the renderer reads it, the effects' wind and seasons, the lights a frame lights with — and a package drawn off screen.
@Suite("Drawing a world")
@MainActor
struct WorldRendererTests {

    /// A package as a world editor writes one, as a folder: a textured prop placed once and scattered twice, a 2 × 2 ground,
    /// an effect of falling leaves, a light, a stream.
    private static func package(waters: [WorldFile.Water] = [], leaves falling: Bool = true) throws -> (WorldPackage, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WorldRendererTests-\(UUID().uuidString)")
        let props = folder.appending(path: "props/1_textured-quad")
        try FileManager.default.createDirectory(at: props, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "game"), withIntermediateDirectories: true)
        try Data(contentsOf: #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda")))
            .write(to: props.appending(path: "textured-quad.usda"))
        try Data(contentsOf: #require(Bundle.module.url(forResource: "material-map", withExtension: "png")))
            .write(to: props.appending(path: "material-map.png"))
        var placed = matrix_identity_float4x4
        placed.columns.3 = SIMD4(0, 0, -1, 1)
        var scattered = placed
        scattered.columns.3 = SIMD4(1, 0, 1, 1)
        let leaves = WorldRendererTests.recipe
        let world = WorldFile(
            name: "Clearing", props: ["props/1_textured-quad/textured-quad.usda"], foliage: [0: .turns], sway: [0: .plant],
            groundCover: [0: false],
            placements: [WorldFile.Placement(prop: 0, transform: placed),
                         WorldFile.Placement(prop: 0, transform: scattered, scattered: true),
                         WorldFile.Placement(prop: 0, transform: placed, scattered: true)],
            ground: WorldFile.Ground(size: 4, resolution: 2), sky: WorldFile.Sky(timeOfDay: 12),
            lights: [WorldFile.Light(position: [0, 2, 0], colour: [1, 0.5, 0.2], intensity: 3, reach: 6)],
            waters: waters,
            effects: !falling ? [] : [WorldFile.Effect(kind: "leaves", variety: 0, position: SIMD3(0, 3, 0), rate: 2, radius: 1,
                                       direction: SIMD3(0, 1, 0), prewarm: 1, followsSun: false, recipe: leaves)])
        try world.data().write(to: folder.appending(path: WorldPackage.descriptionPath))
        try WorldFile.Ground.heightsData((0..<9).map { Float($0 % 3) * 0.25 }).write(to: folder.appending(path: "game/ground.f32"))
        try WorldFile.Ground.coloursData([SIMD3<Float>](repeating: SIMD3(0.2, 0.4, 0.1), count: 9))
            .write(to: folder.appending(path: "game/ground.rgb"))
        return (try WorldPackage(contentsOf: folder), folder)
    }

    @Test("A package's scene: placements on their own, scattered copies grouped by prop, the season and the wind by file")
    func sceneFromPackage() throws {
        let (package, folder) = try Self.package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = WorldScene(package)
        let prop = package.propURL(0)
        #expect(scene.placements.count == 1)
        #expect(scene.placements[0].prop == prop)
        #expect(scene.placements[0].transform.columns.3 == SIMD4(0, 0, -1, 1))
        #expect(scene.scatters.count == 1, "both scattered copies of the one prop are one group")
        #expect(scene.scatters[0].prototypes == [prop])
        #expect(scene.scatters[0].copies.map(\.transform.columns.3) == [SIMD4(1, 0, 1, 1), SIMD4(0, 0, -1, 1)])
        #expect(scene.foliage(of: prop) == .turns)
        #expect(scene.sway(of: prop) == .plant)
        #expect(scene.groundCover[prop] == false, "what a person decided about ground cover comes through by file")
        #expect(scene.foliage(of: URL(filePath: "/elsewhere/Pine.usda")) == .unchanged, "a world file lists every prop that changes")
        #expect(scene.effects.count == 1)
        #expect(scene.effects[0].turnedVariety == 1, "falling leaves take their turned look")
        #expect(!scene.effects[0].blowsWithWind, "an export's effects are blown by its weather already")
        #expect(scene.lights == [WorldScene.Light(position: SIMD3(0, 2, 0), colour: SIMD3(1, 0.5, 0.2), intensity: 3, reach: 6)])
        #expect(scene.sky.timeOfDay == 12)
    }

    @Test("A package's ground is written as the renderer reads it: the world file's own points, normals and colours")
    func groundVertices() throws {
        let (package, folder) = try Self.package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try #require(try package.groundSource())
        let ground = try #require(try package.ground())
        var written = [Float](repeating: .nan, count: 9 * WorldGroundVertices.floatsPerPoint)
        written.withUnsafeMutableBufferPointer { source.writeVertices(xs: 0...2, zs: 0...2, into: $0.baseAddress!) }
        let mesh = ground.mesh().vertices
        for point in 0..<9 {
            for k in 0..<11 { #expect(written[point * 12 + k] == mesh[point * 12 + k], "point \(point), float \(k)") }
            #expect(written[point * 12 + 11] == 0, "nowhere soft")
        }
        #expect(source.lineage == source.lineage && source.revision == 0)
    }

    @Test("Wind thickens and turns what it blows, within an effect's range; still air and clear weather change nothing")
    func effectsInTheWind() {
        let wind = WorldScene.Effect(kind: "wind", position: .zero, rate: 40, radius: 4, recipe: WorldRendererTests.recipe,
                                     blowsWithWind: true)
        var weather = Weather(kind: .storm, severity: 1)
        weather.windHeading = 90
        let blown = wind.blown(by: weather)
        #expect(blown.rate > wind.rate && blown.rate <= WorldScene.Effect.rates.upperBound)
        #expect(simd_distance(blown.direction, SIMD3(1, 0, 0)) < 1e-5, "blowing toward east")
        #expect(wind.blown(by: .clear) == wind)
        let smoke = WorldScene.Effect(kind: "smoke", position: .zero, rate: 4, radius: 1, recipe: WorldRendererTests.recipe)
        #expect(smoke.blown(by: weather) == smoke, "smoke is not one that moves with the wind here")
    }

    @Test("Butterflies keep to fine days: full on a clear summer afternoon, fewer in spring, none in winter, snow, rain or at night")
    func butterfliesKeepToFineDays() {
        let butterflies = WorldScene.Effect(kind: "butterflies", position: .zero, rate: 10, radius: 4,
                                            recipe: WorldRendererTests.recipe, keepsToFineDays: true)
        let afternoon: Float = 0.6                                           // the sun about 34° up
        func rate(_ weather: Weather, sun: Float = afternoon, year: Double? = 2) -> Float {
            butterflies.living(in: weather, sunElevation: sun, yearPosition: year).rate
        }
        #expect(rate(.clear) == 10, "a clear summer afternoon changes nothing")
        #expect(rate(.clear, year: nil) == 10, "a scene with no calendar has no season")
        #expect(rate(.clear, year: 1) > 2 && rate(.clear, year: 1) < 8, "spring has fewer")
        #expect(rate(.clear, year: 0) == 0, "winter has none")
        #expect(rate(.clear, year: 4) == 0 && rate(.clear, year: 6) == 10, "the calendar wraps")
        #expect(rate(.clear, sun: -0.2) == 0, "night has none")
        #expect(rate(Weather(kind: .rain, severity: 0.6)) == 0, "rain has none")
        #expect(rate(Weather(kind: .storm, severity: 0.8)) == 0)
        #expect(rate(Weather(kind: .dust, severity: 0.8)) == 0)
        var snowy = Weather.clear
        snowy.lyingSnow = 0.8
        #expect(rate(snowy) == 0, "lying snow has none")
        let smoke = WorldScene.Effect(kind: "smoke", position: .zero, rate: 4, radius: 1, recipe: WorldRendererTests.recipe)
        #expect(smoke.living(in: snowy, sunElevation: -0.5, yearPosition: 0) == smoke, "only what keeps to fine days")
    }

    @Test("A frame lights with the lights nearest the view, nearest first, none out of reach")
    func nearestLights() {
        let lights = [WorldScene.Light(position: SIMD3(50, 0, 0), colour: .one, intensity: 1, reach: 5),
                      WorldScene.Light(position: SIMD3(3, 0, 0), colour: .one, intensity: 1, reach: 5),
                      WorldScene.Light(position: SIMD3(200, 0, 0), colour: .one, intensity: 1, reach: 5)]
        let near = WorldScene.Light.nearest(lights, to: .zero, radius: 60, limit: 16)
        #expect(near.map(\.position.x) == [3, 50])
    }

    @Test("Ground fog's floor takes water from anyone's file without trapping: bad rectangles are skipped, far ones kept on the grid")
    func fogFloorFromUntrustedWater() {
        let heights = [Float](repeating: 0, count: 9)
        let water = WorldFile.Water(level: 1, colour: .zero, opacity: 1, rectangles: [
            SIMD4(.nan, 0, 1, 1), SIMD4(-.infinity, -1e30, .infinity, 1e30), SIMD4(-1e38, -1e38, 1e38, 1e38)])
        let floor = FogFloor(heights: heights, resolution: 2, size: 4, waters: [water])
        let open = FogFloor(heights: heights, resolution: 2, size: 4, waters: [])
        #expect(floor != open, "the far rectangle, kept on the grid, covers it")
        _ = FogFloor(heights: heights, resolution: 2, size: 4,
                     waters: [WorldFile.Water(level: .nan, colour: .zero, opacity: 1, rectangles: [SIMD4(-1, -1, 1, 1)])])
    }

    @Test("The sky on a world's clock keeps the hour set unless it runs")
    func skyOnTheClock() {
        var sky = WorldFile.Sky(timeOfDay: 9)
        #expect(sky.daySky(at: 1_794_000_000, running: true) == sky.daySky, "no clock: the hour as set")
        sky.clock = WorldClock(runsDay: true, latitude: 45)
        let held = sky.daySky(at: 1_794_000_000, running: false)
        #expect(held.timeOfDay == 9)
        #expect(held.latitude == 45)
    }

    private static let recipe = ParticleRecipe(count: 1, speed: 0.5, spread: 0.2, lifetime: 4, size: 0.1, color: SIMD3(0.8, 0.5, 0.1))

    /// The renderer as the whole game: draws the package and nothing else.
    @Test("A package is drawn off screen: its ground lit under the noon sky, its prop loaded")
    func drawsAPackage() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let (package, folder) = try Self.package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try FrameRenderer(device: device)
        let world = try WorldRenderer(engine: engine, textureCache: nil)
        engine.game = world
        world.scheduleTime = 1_794_000_000
        var failures: [(URL, Error)]?
        try world.show(package) { failures = $0 }
        // The props load in the background, as in a game: wait for them.
        for _ in 0..<500 where failures == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(failures?.isEmpty == true)
        #expect(!world.isLoadingProps)
        #expect(world.bounds(of: package.propURL(0)) != nil)
        #expect(world.groundHeight(x: 0, z: 0) == 0.25, "the middle point, from the heights drawn")
        world.camera = WorldRenderer.View(eye: SIMD3(0, 3, 6), target: .zero)
        let png = try #require(world.pngFrame(width: 64, height: 40))
        #expect(png.count > 100)
        #expect(world.drawn.view > 0, "the ground and the prop were drawn")
    }

    /// With reflections on, the water mirrors the scene drawn behind it — the solid pass's colour is kept for it — and with
    /// them off it reflects the sky alone, as before, in one pass.
    @Test("Water reflects the scene with reflections on, and only the sky with them off")
    func waterReflects() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let pond = WorldFile.Water(level: 0.6, colour: SIMD3(0.05, 0.1, 0.12), opacity: 0.9, rectangles: [SIMD4(-2, 0, 2, 2)])
        let (package, folder) = try Self.package(waters: [pond], leaves: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try FrameRenderer(device: device)
        let world = try WorldRenderer(engine: engine, textureCache: nil)
        engine.game = world
        world.scheduleTime = 1_794_000_000
        var failures: [(URL, Error)]?
        try world.show(package) { failures = $0 }
        for _ in 0..<500 where failures == nil { try await Task.sleep(for: .milliseconds(20)) }
        // Low over the pond, looking across it at the quad standing behind.
        world.camera = WorldRenderer.View(eye: SIMD3(0, 0.9, 3.5), target: SIMD3(0, 0.4, -1))

        // Off first, on a renderer that has never reflected: the water's textures must be bound all the same, or Metal's
        // validation refuses the draw (it did, in an editor, before the stand-ins).
        world.graphicsSettings.reflections = false
        #expect(!world.waterReflects && !world.wantsOpaqueColour)
        let skyOnly = try #require(world.pngFrame(width: 160, height: 100))
        let skyOnlyAgain = try #require(world.pngFrame(width: 160, height: 100))
        world.graphicsSettings.reflections = true
        #expect(world.waterReflects && world.wantsOpaqueTextures && world.wantsOpaqueColour)
        let mirrored = try #require(world.pngFrame(width: 160, height: 100))
        // Frames drift a little on their own (the sky's adaptation, the weather's clock): the reflection's change must
        // stand well above that drift.
        let drift = try Self.difference(skyOnly, skyOnlyAgain), change = try Self.difference(mirrored, skyOnly)
        #expect(change > drift * 4 + 0.2, "turning reflections on changed the water by \(change), against \(drift) drift")
        // A scene without water never pays for the colour.
        let (dry, dryFolder) = try Self.package()
        defer { try? FileManager.default.removeItem(at: dryFolder) }
        world.graphicsSettings.reflections = true
        try world.show(dry) { _ in }
        #expect(!world.waterReflects && !world.wantsOpaqueColour)
    }

    /// The mean difference between two frames' pixels, 0–255 a channel.
    private static func difference(_ a: Data, _ b: Data) throws -> Double {
        func rgba(_ png: Data) throws -> [UInt8] {
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let x = try rgba(a), y = try rgba(b)
        return zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(x.count, 1))
    }

    @Test("A walker meets the props near it, placed and scattered, and none it passes through")
    func solidsNearAWalker() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let (package, folder) = try Self.package()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try WorldRenderer(engine: FrameRenderer(device: device), textureCache: nil)
        #expect(world.solids(around: .zero, reach: 10).isEmpty, "nothing is solid before it is shown")
        var failures: [(URL, Error)]?
        try world.show(package) { failures = $0 }
        for _ in 0..<500 where failures == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(world.walkedThrough.isEmpty)
        let near = world.solids(around: .zero, reach: 10)
        #expect(near.count == 3, "the placement and both scattered copies")
        #expect(near.allSatisfy { !$0.triangles.isEmpty })
        #expect(world.solids(around: SIMD2(100, 100), reach: 10).isEmpty, "nothing within reach of a far point")
        world.walkedThrough = [package.propURL(0)]
        #expect(world.solids(around: .zero, reach: 10).isEmpty, "a prop walked through is never solid")
    }
}

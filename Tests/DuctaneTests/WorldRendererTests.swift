//
//  WorldRendererTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import Testing
import simd
@testable import Ductane

/// **A world drawn**: a scene package turned into what ``WorldRenderer`` draws (``WorldScene``), its ground written as
/// the renderer reads it, the effects' wind and seasons, the lights a frame lights with — and a package drawn off screen.
@Suite("Drawing a world")
@MainActor
struct WorldRendererTests {

    /// A package as a world editor writes one, as a folder: a textured prop placed once and scattered twice, a 2 × 2 ground,
    /// an effect of falling leaves, a light, a stream.
    private static func package() throws -> (WorldPackage, URL) {
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
            placements: [WorldFile.Placement(prop: 0, transform: placed),
                         WorldFile.Placement(prop: 0, transform: scattered, scattered: true),
                         WorldFile.Placement(prop: 0, transform: placed, scattered: true)],
            ground: WorldFile.Ground(size: 4, resolution: 2), sky: WorldFile.Sky(timeOfDay: 12),
            lights: [WorldFile.Light(position: [0, 2, 0], colour: [1, 0.5, 0.2], intensity: 3, reach: 6)],
            effects: [WorldFile.Effect(kind: "leaves", variety: 0, position: SIMD3(0, 3, 0), rate: 2, radius: 1,
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
}

import Foundation
import Testing
import simd
@testable import Ductane

/// **The world description's contract.** A description outlives the editor that wrote it, so what is guarded here is
/// round-tripping, defaults, and refusing a file this build cannot honestly read.
@Suite("A world as a game reads it")
struct WorldFileTests {

    private func world() -> WorldFile {
        var turned = matrix_identity_float4x4
        turned.columns.3 = SIMD4(3, 0.5, -2, 1)
        return WorldFile(name: "Test", props: ["props/1_A/A.usda", "props/2_B/_material_B.usda"],
                         placements: [WorldFile.Placement(prop: 0, transform: turned),
                                      WorldFile.Placement(prop: 0, transform: matrix_identity_float4x4,
                                                          materials: ["Atlas01": .init(prop: 1, name: "Atlas03")])],
                         ground: WorldFile.Ground(size: 4, resolution: 2),
                         markers: [WorldFile.Marker(kind: "Spawn", name: "Start", position: SIMD3(1, 2, 3), yaw: 0.5),
                                   WorldFile.Marker(kind: "encounter", name: "Village", position: SIMD3(9, 0, 9),
                                                    values: ["radius": 25, "order": 1])])
    }

    @Test("Written and read back, it is the same world")
    func roundTrip() throws {
        let file = world()
        let read = try WorldFile.read(file.data())
        #expect(read == file)
        #expect(read.placements[0].transform.columns.3 == SIMD4(3, 0.5, -2, 1))
    }

    /// A player's grass setting thins ground cover: what an editor's person decided comes through the file and wins over
    /// the shape, and a prop nobody decided is judged by its shape.
    @Test("Ground cover: decided by a person and carried by the file, else by its shape")
    func groundCover() throws {
        var file = WorldFile(name: "Meadow", props: ["grass.usda", "sunflowers.usda", "tree.usda"], groundCover: [1: true, 2: false],
                             placements: [WorldFile.Placement(prop: 0, transform: matrix_identity_float4x4)])
        #expect(try WorldFile.read(file.data()).groundCover == [1: true, 2: false])
        // Written by something that knows nothing of it: none decided.
        let older = try WorldFile.read(WorldFile(name: "w", props: [], placements: []).data())
        #expect(older.groundCover.isEmpty)
        // An index into props it lacks is refused, as every other.
        file.groundCover = [7: true]
        #expect(throws: WorldFile.ReadError.badProp(7)) { try WorldFile.read(file.data()) }

        // The shape: all cut-out cards, and low or spread wide.
        #expect(GroundCover.byShape(size: SIMD3(1, 0.5, 1), cutOut: true))
        #expect(GroundCover.byShape(size: SIMD3(34, 2, 34), cutOut: true), "a wide patch")
        #expect(!GroundCover.byShape(size: SIMD3(3, 6, 3), cutOut: true), "a tree's cards")
        #expect(!GroundCover.byShape(size: SIMD3(1, 0.5, 1), cutOut: false), "a solid rock")

        file.groundCover = [1: true, 2: false]
        let urls = file.props.map { URL(filePath: "/w/\($0)") }
        let scene = WorldScene(groundCover: [urls[1]: true, urls[2]: false])
        #expect(scene.isGroundCover(urls[0], size: SIMD3(1, 0.4, 1), cutOut: true), "undecided: by its shape")
        #expect(scene.isGroundCover(urls[1], size: SIMD3(1, 2.4, 1), cutOut: true), "decided over a shape just over the line")
        #expect(!scene.isGroundCover(urls[2], size: SIMD3(1, 0.4, 1), cutOut: true), "decided against a low shape")
    }

    @Test("Markers come through whole, and are found by kind in any case")
    func markers() throws {
        let read = try WorldFile.read(world().data())
        #expect(read.markers("spawn").map(\.position) == [SIMD3(1, 2, 3)])
        #expect(read.markers("ENCOUNTER").first?.values["radius"] == 25)
        #expect(read.markers("objective").isEmpty)
    }

    @Test("A liquid comes through by prop and material, and its colour follows its two gradients")
    func liquids() throws {
        let look = try JSONDecoder().decode(WorldFile.Liquid.Look.self, from: Data(Self.goopJSON.utf8))
        var file = world()
        file.liquids = [WorldFile.Liquid(prop: 0, material: "Goop01Water2", look: look)]
        let read = try WorldFile.read(file.data())
        #expect(read.liquids == file.liquids)
        #expect(look.colour(atDepth: 0) == look.shallow)
        #expect(look.colour(atDepth: 1.03) == look.veryDeep, "full at half the very-deep height")
        #expect(look.textureFiles == ["textures/Goop02.png", "textures/NoiseSmall.png", "textures/WaterNormals01.png"])
        #expect(try WorldFile.read(world().data()).liquids == [], "none, written as none")
    }

    @Test("Effect meshes, followers and grime come through, and a file without them has none")
    func effectsAndGrime() throws {
        var file = world()
        var leap = ParticleRecipe(count: 1, speed: 8, spread: 3, lifetime: 5, size: 1, color: .one)
        leap.mesh = "Frog_Jump_Mesh"; leap.lands = true; leap.then = 1; leap.generations = 13
        var sit = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 1.25, size: 1, color: .one)
        sit.mesh = "Frog_Idle_Mesh"; sit.then = 0; sit.generations = 13
        file.effects = [WorldFile.Effect(kind: "frogs", variety: 0, position: .zero, rate: 0.5, radius: 4,
                                         direction: SIMD3(0, 1, 0), prewarm: 7, followsSun: false, recipe: leap,
                                         followers: [sit])]
        file.effectMeshes = ["Frog_Jump_Mesh": 0, "Frog_Idle_Mesh": 1]
        let json = #"{"albedoTiling":7,"colour":[1,0.7,0.39],"falloff":2,"intensity":0.133,"texture":"textures/Grunge03.png","tiling":0.03}"#
        let grime = try JSONDecoder().decode(WorldFile.Grime.Look.self, from: Data(json.utf8))
        file.grime = [WorldFile.Grime(prop: 0, material: "SaltFlatTriplanar02", look: grime)]
        let read = try WorldFile.read(file.data())
        #expect(read == file)
        #expect(read.effects[0].followers.first?.mesh == "Frog_Idle_Mesh" && read.effects[0].recipe.lands)
        #expect(read.grime.first?.look.albedoTiling == 7)
        let bare = try WorldFile.read(world().data())
        #expect(bare.effectMeshes == [:] && bare.grime == [])
    }

    /// A look with every key, as an editor writes it.
    static let goopJSON = """
    {"baseOpacity":0.941,"deep":[0.07,0.17,0.013],"deepHeight":2.58,"foamOpacity":0.38,"foamTiling":2.5,
     "foamTint":[0.003,0.31,0],"metallic":0.414,"noiseTexture":"textures/NoiseSmall.png","normalIntensity":0.122,
     "normalNoiseIntensity":0.23,"normalNoiseTiling":1,"normalPanSpeed":1,"normalTexture":"textures/WaterNormals01.png",
     "normalTiling":5,"ripples":true,"scrollDirection":[0,-0.01],"scrollOpacity":0.502,"scrollTexture":"textures/Goop02.png",
     "scrollTiling":[1.4,1.4],"scrollTint":[0.26,0.52,0.18],"scrolling":true,"shallow":[0.144,0.314,0.061],
     "shallowsOpacity":0.99,"shoreBand":true,"shoreEdgeNoiseScale":0.1,"shoreEdgeOpacity":0.296,"shoreEdgeThickness":0.832,
     "shoreFoam":true,"shoreFoamNoiseScale":2,"shoreTint":[0.094,0.406,0.09],"shoreWaveReturn":0.273,
     "shoreWaveThickness":0.346,"smoothness":0.385,"veryDeep":[0.18,0.346,0],"veryDeepHeight":2.06}
    """

    @Test("A point is under water below the level and over a rectangle, and nowhere else")
    func underWater() {
        let water = WorldFile.Water(level: 0, colour: SIMD3(0.04, 0.05, 0.02), opacity: 0.9,
                                    rectangles: [SIMD4(-10, -10, 0, 0), SIMD4(5, 5, 6, 6)])
        #expect(water.covers(SIMD3(-5, -0.5, -5)))
        #expect(water.covers(SIMD3(5.5, -2, 5.5)))
        #expect(!water.covers(SIMD3(-5, 0.5, -5)), "above the surface")
        #expect(!water.covers(SIMD3(2, -0.5, 2)), "below the level, but over dry ground")
    }

    @Test("The world's edge comes through as the scene set it, and a world without one has none")
    func boundary() throws {
        var file = world()
        #expect(try WorldFile.read(file.data()).boundary == nil)
        file.boundary = WorldBoundary(profile: .walls, center: SIMD2(1, 2), halfSize: SIMD2(40, 30), roundness: 0.2,
                                      base: -15, height: 60, look: .forceField)
        #expect(try WorldFile.read(file.data()).boundary == file.boundary)
    }

    @Test("The waymark look survives the file, and a file without one has none")
    func waymark() throws {
        var file = world()
        #expect(try WorldFile.read(file.data()).waymark == nil)
        var look = Waymark.Look(pattern: .chevrons, color: SIMD3(0.2, 0.9, 0.4), width: 0.3)
        look.beam.height = 45
        file.waymark = look
        #expect(try WorldFile.read(file.data()).waymark == look)
    }

    @Test("The sky becomes the day sky it describes, a hand-set sun included")
    func sky() {
        let set = WorldFile.Sky(timeOfDay: 16.5, fogDensity: 0.006,
                                sun: .init(heading: 120, height: 30, colour: [1, 0.9, 0.8], brightness: 2))
        let sky = set.daySky
        #expect(sky.timeOfDay == 16.5 && sky.fogDensity == 0.006)
        #expect(sky.sun?.heading == 120 && sky.sun?.colour == SIMD3(1, 0.9, 0.8))
        #expect(WorldFile.Sky().daySky.sun == nil)
    }

    @Test("What is walked through and which props have a shape of their own come through")
    func walkingAndShapes() throws {
        var file = WorldFile(name: "Marsh", props: ["props/1_Rock/Rock.usda", "props/2_Reeds/Reeds.usda", "props/3_Grass/Grass.usda"],
                             walkedThrough: [2, 1], collisionShapes: [0: "game/collision/0.f32"], placements: [])
        file = try WorldFile.read(file.data())
        #expect(file.passesThrough == [false, true, true])
        #expect(file.collisionShapes == [0: "game/collision/0.f32"])
    }

    @Test("Painted weights, a stream's course and the characters come through")
    func paintStreamsCharacters() throws {
        var file = world()
        file.ground?.weights = "game/ground.weights"
        file.ground?.layers = ["Grass", "Mud"]
        file.streams = [WorldFile.Stream(length: 12, corners: [], course: [SIMD3(0, 1, 0), SIMD3(4, 0.8, -6)], width: 3)]
        file.characters = [1]
        let read = try WorldFile.read(file.data())
        #expect(read.ground?.layers == ["Grass", "Mud"] && read.streams[0].course.count == 2 && read.streams[0].width == 3)
        #expect(read.characters == [1])
        let bytes = Data((0..<2).flatMap { _ in [200, 55, 0, 0, 0, 0, 0, 0] as [UInt8] })
        #expect(WorldFile.Ground.weights(bytes, points: 2)?.map { $0[1] } == [55, 55])
        #expect(WorldFile.Ground.weights(bytes, points: 3) == nil, "the wrong size for the grid")
    }

    @Test("A file that leaves lists out reads them as empty: only a name, props and placements are needed")
    func lenient() throws {
        let bare = #"{"name":"Bare","props":["a.usda"],"placements":[{"prop":0,"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}],"streams":[{"length":3,"corners":[]}],"ground":{"size":2,"resolution":2,"heights":"h","colours":"c"}}"#
        let read = try WorldFile.read(Data(bare.utf8))
        #expect(read.version == WorldFile.version && read.markers.isEmpty && read.characters.isEmpty && read.sky == WorldFile.Sky())
        #expect(read.streams[0].course.isEmpty && read.ground?.layers == [] && read.ground?.weights == nil)
    }

    @Test("A placement's turn, lean, size and place come back out of its matrix")
    func turnAndLean() {
        for yaw: Float in [0, 0.7, -2.5, 3] {
            let up = simd_normalize(SIMD3<Float>(0.2, 1, -0.1))
            let rotation = WorldFile.Placement.lean(onto: up) * simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            var m = simd_float4x4(rotation)
            m.columns.0 *= 1.5; m.columns.1 *= 1.5; m.columns.2 *= 1.5
            m.columns.3 = SIMD4(3, 4, 5, 1)
            let placed = WorldFile.Placement(prop: 0, transform: m)
            let read = placed.turnAndLean
            // The same turn, whichever way round it is written.
            let apart = remainder(read.yaw - yaw, 2 * .pi)
            #expect(abs(apart) < 1e-4 && simd_distance(read.up, up) < 1e-4, "yaw \(yaw) read as \(read.yaw)")
            #expect(abs(placed.scale - 1.5) < 1e-5 && placed.position == SIMD3(3, 4, 5))
        }
        let c = cos(Float(0.5)), s = sin(Float(0.5))
        let upright = simd_float4x4(columns: (SIMD4(c * 2, 0, -s * 2, 0), SIMD4(0, 2, 0, 0), SIMD4(s * 2, 0, c * 2, 0), SIMD4(0, 0, 0, 1)))
        let read = WorldFile.Placement(prop: 0, transform: upright).turnAndLean
        #expect(abs(read.yaw - 0.5) < 1e-5 && read.up == SIMD3(0, 1, 0))
    }

    @Test("A placement wearing its own materials says nothing about them")
    func emptyMaterialsAreLeftOut() throws {
        let json = String(decoding: try world().data(), as: UTF8.self)
        #expect(json.components(separatedBy: "\"materials\"").count == 2, "one placement wears another material")
    }

    @Test("The same world writes the same bytes")
    func stable() throws {
        #expect(try world().data() == world().data())
    }

    @Test("A placement naming a prop the file does not list is refused, as is a newer file")
    func refusals() throws {
        var bad = world()
        bad.placements.append(.init(prop: 7, matrix: WorldFile.numbers(matrix_identity_float4x4)))
        #expect(throws: WorldFile.ReadError.badPlacement(7)) { try WorldFile.read(bad.data()) }
        var newer = world()
        newer.version = WorldFile.version + 1
        #expect(throws: WorldFile.ReadError.newer(WorldFile.version + 1)) { try WorldFile.read(newer.data()) }
    }

    @Test("Every index a file names must be a prop it lists, and its ground a size the engine reads")
    func refusesBadIndices() throws {
        func refused(_ change: (inout WorldFile) -> Void) -> Bool {
            var file = world()
            change(&file)
            return (try? WorldFile.read(file.data())) == nil
        }
        #expect(refused { $0.characters = [9] })
        #expect(refused { $0.effectMeshes = ["Frog": 5] })
        #expect(refused { $0.walkedThrough = [-1] })
        #expect(refused { $0.collisionShapes = [7: "game/collision/7.f32"] })
        #expect(refused { $0.placements[1].materials = ["Atlas01": .init(prop: 3, name: "X")] })
        let look = try JSONDecoder().decode(WorldFile.Liquid.Look.self, from: Data(Self.goopJSON.utf8))
        #expect(refused { $0.liquids = [WorldFile.Liquid(prop: 4, material: "M", look: look)] })
        #expect(refused { $0.ground = WorldFile.Ground(size: 4, resolution: Int.max / 2) })
        #expect(refused { $0.ground = WorldFile.Ground(size: 4, resolution: 0) })
        #expect(!refused { $0.characters = [1] }, "an index it lists reads")
        // Every path stays inside the package — props, the ground's files, and textures beside their prop.
        #expect(refused { $0.props[0] = "../A.usda" })
        #expect(refused { $0.props[0] = "/Users/someone/A.usda" })
        #expect(refused { $0.ground?.weights = "game/../../w" })
        var outside = look
        outside.noiseTexture = "../../../etc/noise.png"
        #expect(refused { $0.liquids = [WorldFile.Liquid(prop: 0, material: "M", look: outside)] })
        let grime = WorldFile.Grime.Look(texture: "/etc/grime.png", colour: .one, intensity: 1, tiling: 1, falloff: 1, albedoTiling: 1)
        #expect(refused { $0.grime = [WorldFile.Grime(prop: 0, material: "M", look: grime)] })
        #expect(!refused { $0.liquids = [WorldFile.Liquid(prop: 0, material: "M", look: look)] }, "textures beside the prop read")
        #expect(throws: WorldGroundError.self) {
            try WorldGround(WorldFile.Ground(size: 4, resolution: Int.max / 2), heights: Data(), colours: Data())
        }
    }

    @Test("A collision shape is written and read back as whole triangles; a torn file is refused")
    func collisionShape() throws {
        let ramp: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1.5, -2.5)]
        #expect(try WorldFile.CollisionShape.triangles(WorldFile.CollisionShape.data(ramp)) == ramp)
        #expect(WorldFile.CollisionShape.data(ramp).count == 36)
        #expect(throws: WorldFile.ReadError.notWholeTriangles(bytes: 35)) {
            try WorldFile.CollisionShape.triangles(WorldFile.CollisionShape.data(ramp).prefix(35))
        }
    }
}

@Suite("A world's ground")
struct WorldGroundTests {

    /// 2 m square, 2 cells a side: heights rise 1 m a metre along +X.
    private func slope() throws -> WorldGround {
        let description = WorldFile.Ground(size: 2, resolution: 2)
        let heights: [Float] = (0..<3).flatMap { _ in [0, 1, 2] }
        let colours = [SIMD3<Float>](repeating: SIMD3(0.5, 0.25, 0.1), count: 9)
        return try WorldGround(description, heights: WorldFile.Ground.heightsData(heights),
                               colours: WorldFile.Ground.coloursData(colours))
    }

    @Test("Its files are read back as written, colours within a byte's step")
    func files() throws {
        let ground = try slope()
        #expect(ground.heights == (0..<3).flatMap { _ in [0, 1, 2] })
        #expect(simd_distance(ground.colours[4], SIMD3(0.5, 0.25, 0.1)) < 0.01)
    }

    @Test("Heights between points are interpolated, and held at the edge beyond it")
    func height() throws {
        let ground = try slope()
        #expect(ground.height(x: 0, z: 0) == 1)
        #expect(abs(ground.height(x: 0.5, z: 0.3) - 1.5) < 1e-5)
        #expect(ground.height(x: 50, z: 0) == 2)
    }

    @Test("The mesh has a vertex a point and two triangles a cell, facing up")
    func mesh() throws {
        let ground = try slope()
        let (vertices, indices) = ground.mesh()
        let n = WorldGround.floatsPerVertex
        #expect(vertices.count == 9 * n)
        #expect(indices.count == 2 * 2 * 6)
        func position(_ i: UInt32) -> SIMD3<Float> { SIMD3(vertices[Int(i) * n], vertices[Int(i) * n + 1], vertices[Int(i) * n + 2]) }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = position(indices[t]), b = position(indices[t + 1]), c = position(indices[t + 2])
            #expect(simd_cross(b - a, c - a).y > 0, "triangle \(t / 3) faces down")
        }
        #expect(vertices[4 * n + 3] < 0, "the slope rises along +X, so its normal leans back")
    }

    @Test("A hole is no ground: nothing drawn over it, and a walker falls through to what is below")
    func holes() throws {
        let description = WorldFile.Ground(size: 2, resolution: 2, holes: "game/ground.holes")
        let heights = WorldFile.Ground.heightsData([Float](repeating: 0, count: 9))
        let colours = WorldFile.Ground.coloursData([SIMD3<Float>](repeating: .one, count: 9))
        let cut = [false, false, false, true]   // the cell at +X, +Z
        let ground = try WorldGround(description, heights: heights, colours: colours, holes: WorldFile.Ground.holesData(cut))
        #expect(ground.isHole(1, 1) && !ground.isHole(0, 0))
        #expect(ground.mesh().indices.count == 3 * 6)
        #expect(ground.height(x: 0.5, z: 0.5) == WorldGround.underHole)
        #expect(ground.height(x: -0.5, z: -0.5) == 0)
        #expect(ground.heightIgnoringHoles(x: 0.5, z: 0.5) == 0, "filled, it is the ground round it")
        #expect(ground.contains(x: 1, z: -1) && !ground.contains(x: 1.1, z: 0))
        #expect(throws: WorldGroundError.self) {
            try WorldGround(description, heights: heights, colours: colours, holes: Data(count: 3))
        }
    }

    @Test("Files the wrong size for the grid are refused")
    func wrongSize() {
        #expect(throws: WorldGroundError.self) {
            try WorldGround(WorldFile.Ground(size: 2, resolution: 2), heights: Data(count: 8), colours: Data(count: 27))
        }
    }
}

import Foundation
import Testing
import simd
@testable import Ductane

/// A box as a loose piece: eight corners, twelve triangles, turned and placed.
private func box(_ size: SIMD3<Float>, at centre: SIMD3<Float>, turned: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                 into positions: inout [SIMD3<Float>], indices: inout [UInt32]) {
    let base = UInt32(positions.count)
    for i in 0..<8 {
        let corner = SIMD3<Float>(i & 1 == 0 ? -0.5 : 0.5, i & 2 == 0 ? -0.5 : 0.5, i & 4 == 0 ? -0.5 : 0.5) * size
        positions.append(centre + turned.act(corner))
    }
    let faces: [[UInt32]] = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
    for f in faces { indices += [f[0], f[1], f[2], f[0], f[2], f[3]].map { base + $0 } }
}

/// A windmill: a tower, four braces round it (a ring of identical pieces running round the tower), and six sails round
/// a hub at the top, facing +z, each pointing out from it.
private func windmill() -> (positions: [SIMD3<Float>], indices: [UInt32], sailTriangles: Range<Int>) {
    var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
    box(SIMD3(0.6, 6, 0.6), at: SIMD3(0, 3, 0), into: &positions, indices: &indices)
    for k in 0..<4 {
        let a = Float(k) * .pi / 2
        box(SIMD3(1.6, 0.1, 0.1), at: SIMD3(cos(a), 2, sin(a)) * SIMD3(0.8, 1, 0.8) + SIMD3(0, 0, 0),
            turned: simd_quatf(angle: -a + .pi / 2, axis: SIMD3(0, 1, 0)), into: &positions, indices: &indices)
    }
    let firstSail = indices.count / 3
    let hub = SIMD3<Float>(0, 6, 0.5)
    for k in 0..<6 {
        let a = Float(k) * .pi / 3
        let out = SIMD3<Float>(cos(a), sin(a), 0)
        box(SIMD3(2, 0.4, 0.05), at: hub + out * 1.2, turned: simd_quatf(angle: a, axis: SIMD3(0, 0, 1)),
            into: &positions, indices: &indices)
    }
    return (positions, indices, firstSail..<(indices.count / 3))
}

@Test func aWindmillsSailsAreFoundAndNothingElse() throws {
    let mill = windmill()
    let part = try #require(TurningPart.find(meshes: [(mill.positions, [mill.indices])]))
    #expect(abs(abs(part.axis.z) - 1) < 1e-3)
    #expect(simd_distance(part.hub, SIMD3(0, 6, 0.5)) < 1e-3)
    let turns = part.turns[0][0]
    for t in turns.indices { #expect(turns[t] == mill.sailTriangles.contains(t), "triangle \(t)") }
}

@Test func aRingOfBracesAloneDoesNotTurn() {
    var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
    box(SIMD3(0.6, 6, 0.6), at: SIMD3(0, 3, 0), into: &positions, indices: &indices)
    for k in 0..<4 {
        let a = Float(k) * .pi / 2
        box(SIMD3(1.6, 0.1, 0.1), at: SIMD3(cos(a) * 0.8, 2, sin(a) * 0.8),
            turned: simd_quatf(angle: -a + .pi / 2, axis: SIMD3(0, 1, 0)), into: &positions, indices: &indices)
    }
    #expect(TurningPart.find(meshes: [(positions, [indices])]) == nil)
}

@Test func theTurnGoesRoundTheHubAndTheSpeedFollowsTheWind() throws {
    let mill = windmill()
    let part = try #require(TurningPart.find(meshes: [(mill.positions, [mill.indices])]))
    let tip = part.hub + SIMD3(0, 2, 0)
    let half = part.transform(angle: .pi) * SIMD4(tip, 1)
    #expect(simd_distance(SIMD3(half.x, half.y, half.z), part.hub - SIMD3(0, 2, 0)) < 1e-4)
    let hub = part.transform(angle: 1.3) * SIMD4(part.hub, 1)
    #expect(simd_distance(SIMD3(hub.x, hub.y, hub.z), part.hub) < 1e-5)
    #expect(TurningPart.speed(windSpeed: 0) == 0)
    #expect(TurningPart.speed(windSpeed: 10) > TurningPart.speed(windSpeed: 5))
    #expect(TurningPart.speed(windSpeed: 1000) <= 12)
}

@Test func aWindmillIsGuessedToTurn() {
    #expect(Sway.guess(name: "SM_Prop_Windmill_01") == .turns)
    #expect(Sway.guess(name: "windmill") == .turns)
}

@Test func windCarriesParticlesByTheirShare() {
    var still = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 0.1, gravity: 0, drag: 2,
                               color: SIMD3(1, 1, 1))
    var carried = still
    carried.windResponse = 1
    still.windResponse = 0
    var system = ParticleSystem(recipes: [still, carried], capacity: 4)
    system.burst(0, at: .zero, seed: 1)
    system.burst(1, at: .zero, seed: 2)
    system.wind = SIMD3(10, 0, 0)
    for _ in 0..<120 { system.step(deltaTime: 1.0 / 60) }
    let live = system.live
    let unmoved = live.first { $0.recipe == 0 }!, blown = live.first { $0.recipe == 1 }!
    #expect(abs(unmoved.position.x) < 0.01)
    #expect(blown.position.x > 5)
    #expect(blown.velocity.x > 9)
}

/// Sails each made differently — four of different lengths and widths round one hub, as a pack's patched sails are —
/// still turn, found as spokes.
@Test func sailsMadeDifferentlyStillTurn() throws {
    var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
    box(SIMD3(0.6, 6, 0.6), at: SIMD3(0, 3, 0), into: &positions, indices: &indices)
    let firstSail = indices.count / 3
    let hub = SIMD3<Float>(0, 6, 0.5)
    for (k, (length, width)) in [(Float(2.0), Float(0.4)), (1.7, 0.5), (2.3, 0.35), (1.9, 0.45)].enumerated() {
        let a = Float(k) * .pi / 2
        box(SIMD3(length, width, 0.05), at: hub + SIMD3(cos(a), sin(a), 0) * (length / 2 + 0.2),
            turned: simd_quatf(angle: a, axis: SIMD3(0, 0, 1)), into: &positions, indices: &indices)
    }
    let part = try #require(TurningPart.find(meshes: [(positions, [indices])]))
    #expect(abs(abs(part.axis.z) - 1) < 1e-2)
    #expect(simd_distance(part.hub, hub) < 0.05)
    for t in part.turns[0][0].indices { #expect(part.turns[0][0][t] == (t >= firstSail), "triangle \(t)") }
}

@Test func tumbleweedsRollAndStiffPlantsSwayAsTrees() {
    #expect(Sway.guess(name: "tumbleweed") == .rolls)
    #expect(Sway.guess(name: "SM_Prop_Tumbleweed_02") == .rolls)
    #expect(Sway.guess(name: "yucca") == .tree)
    #expect(Sway.guess(name: "agave") == .tree)
    #expect(WorldRenderer.rollSpeed(windSpeed: 4) == 0)
    #expect(WorldRenderer.rollSpeed(windSpeed: 20) > WorldRenderer.rollSpeed(windSpeed: 10))
}

@Test func aPartOfAPropMovesApartFromIt() throws {
    #expect(Sway.isCloth(material: "WagonCanvas"))
    #expect(Sway.isCloth(material: "Tarp_01"))
    #expect(!Sway.isCloth(material: "Wood"))
    let wagon = URL(filePath: "/p/wagon.usda")
    var scene = WorldScene(guessesByName: true)
    #expect(scene.sway(of: wagon, material: "Canvas") == .cloth)
    #expect(scene.sway(of: wagon, material: "Material") == nil)
    scene.materialSway = [wagon: ["Material": .cloth, "Canvas": .still]]
    #expect(scene.sway(of: wagon, material: "Material") == .cloth)
    #expect(scene.sway(of: wagon, material: "Canvas") == .still)
    // A world file carries it, by prop, and a scene read from it has it.
    var file = WorldFile(name: "w", props: ["wagon.usda"], placements: [])
    file.materialSway = [0: ["Material": .cloth]]
    let read = try JSONDecoder().decode(WorldFile.self, from: JSONEncoder().encode(file))
    #expect(read.materialSway == [0: ["Material": .cloth]])
}

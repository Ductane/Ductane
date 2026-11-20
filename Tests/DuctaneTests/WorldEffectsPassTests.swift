import Metal
import Testing
import simd
@testable import Ductane

/// A world's effects follow a running clock without starting again: a rate that moves with the season, a direction with
/// the wind and a sunbeam with the sun change in place, and only a new, removed or reshaped effect builds and prewarms.
@MainActor
struct WorldEffectsPassTests {

    private static let recipe = ParticleRecipe(count: 1, speed: 0.5, spread: 0.2, lifetime: 4, size: 0.1, color: SIMD3(0.8, 0.5, 0.1))

    @Test("A rate, a direction or the sun changing follows in place; a new effect builds again")
    func followsInPlace() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pass = try WorldEffectsPass(device: device, sampleCount: 1)
        var leaves = WorldScene.Effect(kind: "leaves", position: .zero, rate: 8, radius: 4, prewarm: 2,
                                       recipe: Self.recipe, seed: 1)
        let beams = WorldScene.Effect(kind: "sunbeams", position: SIMD3(5, 0, 0), rate: 2, radius: 3, prewarm: 2,
                                      followsSun: true, recipe: Self.recipe, seed: 2)
        pass.sync([leaves, beams], lighting: DaySky(timeOfDay: 9).lighting)
        #expect(pass.builds == 1)
        for hour in stride(from: Float(9.1), through: 12, by: 0.1) {
            leaves.rate += 0.25
            leaves.direction = simd_normalize(SIMD3(sin(hour), 1, cos(hour)))
            pass.sync([leaves, beams], lighting: DaySky(timeOfDay: hour).lighting)
            pass.step(deltaTime: 1.0 / 60)
        }
        #expect(pass.builds == 1, "a frame's rate, direction or sun must not build and prewarm every effect again")
        pass.sync([leaves], lighting: DaySky(timeOfDay: 12).lighting)
        #expect(pass.builds == 2, "an effect removed builds again")
    }
}

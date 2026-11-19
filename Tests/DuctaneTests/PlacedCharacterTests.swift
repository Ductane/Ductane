import Foundation
import Testing
import simd
@testable import Ductane

/// **Characters stood in a world**: told apart from props by the world file, and idling in whatever clip their file calls
/// an idle, a row of the same figure out of step.
@Suite("Placed characters")
struct PlacedCharacterTests {

    private static func clip(_ name: String, length: Float = 1) throws -> AnimationClip {
        try AnimationClip(name: name, jointPaths: ["hips"],
                          translation: JointTrack(times: [0, length], values: [.zero, SIMD3(0, 0.1, 0)], jointCount: 1),
                          rotation: .empty(jointCount: 1), scale: .empty(jointCount: 1))
    }

    private static func rig(_ names: [String]) throws -> Rig {
        let skeleton = try Skeleton(jointPaths: ["hips"], restTransforms: [matrix_identity_float4x4],
                                    bindTransforms: [matrix_identity_float4x4])
        return Rig(skeleton: skeleton, clips: try names.map { try clip($0) })
    }

    @Test("A standing idle is chosen over any other idle, an idle over anything else, and the first clip otherwise",
          arguments: [
              (["Walk", "Idle_Crouch", "Idle_Standing_01", "Run"], "Idle_Standing_01"),
              (["Walk", "Crouch_Idle", "STAND_IDLE"], "STAND_IDLE"),
              (["Walk", "Breathing Idle", "Run"], "Breathing Idle"),
              (["Walk", "Step"], "Walk"),
          ])
    func idleClip(names: [String], expected: String) throws {
        #expect(try Self.rig(names).idleClip?.name == expected)
    }

    @Test("A rig with no clips has no idle, and no playhead")
    func noClips() throws {
        let rig = try Self.rig([])
        #expect(rig.idleClip == nil && rig.idlePlayhead() == nil)
    }

    @Test("The idle loops, each neighbour started a stagger further in")
    func staggered() throws {
        let rig = try Self.rig(["Walk", "Idle"])
        let first = try #require(rig.idlePlayhead()), third = try #require(rig.idlePlayhead(staggeredBy: 2))
        #expect(first.clip.name == "Idle" && first.isLooping && first.time == 0)
        #expect(third.time == 2 * Rig.idleStagger && third.time > 0)
    }

    @Test("A world's placements split into characters and props, every placement in exactly one, in placed order")
    func split() {
        let at = { (x: Float) -> simd_float4x4 in
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(x, 0, 0, 1)
            return m
        }
        let world = WorldFile(name: "Yard", props: ["props/crate.usda", "props/guard.glb", "props/dog.usdz"],
                              characters: [1, 2],
                              placements: [.init(prop: 0, transform: at(0)), .init(prop: 1, transform: at(1)),
                                           .init(prop: 0, transform: at(2)), .init(prop: 2, transform: at(3)),
                                           .init(prop: 1, transform: at(4))])
        #expect(world.characterPlacements.map(\.position.x) == [1, 3, 4])
        #expect(world.propPlacements.map(\.position.x) == [0, 2])
        let none = WorldFile(name: "Empty", props: ["props/crate.usda"], placements: [.init(prop: 0, transform: at(0))])
        #expect(none.characterPlacements.isEmpty && none.propPlacements == none.placements)
    }

    @Test("A glTF character stood in a package reads with its rig, and idles in its first clip when it has no idle")
    func gltfInPackage() throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "PlacedCharacterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let figure = try #require(Bundle.module.url(forResource: "walker", withExtension: "glb"))
        try FileManager.default.createDirectory(at: work.appending(path: "props/1_Walker"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: figure, to: work.appending(path: "props/1_Walker/Walker.glb"))
        try FileManager.default.createDirectory(at: work.appending(path: "game"), withIntermediateDirectories: true)
        let world = WorldFile(name: "Yard", props: ["props/1_Walker/Walker.glb"], characters: [0],
                              placements: [.init(prop: 0, transform: matrix_identity_float4x4)])
        try world.data().write(to: work.appending(path: WorldPackage.descriptionPath))

        let package = try WorldPackage(contentsOf: work)
        let placed = try #require(package.world.characterPlacements.first)
        let rig = try RigLoader.load(url: package.propURL(placed.prop))
        #expect(rig.skeleton.jointCount > 1)
        #expect(rig.idlePlayhead()?.clip.name == rig.clips.first?.name && !rig.clips.isEmpty)
    }
}

//
//  GLTFCharacterTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import ModelIO
import Testing
import simd
@testable import Ductane

/// Skinned, animated glTF characters: the skeleton, the skin and the clips, held to the same character read from USD.
///
/// **The fixtures.** `walker.glb` and `walker.usda` are one studio-made test character — a person 1.85 m tall with a
/// body, a head and a backpack on twelve joints, and two clips, a one-second walk and its first half — exported by a
/// character creator to glTF and to USD from the same character, so each reader can be held to the other. The USD
/// export welds and renumbers corners where the glTF one keeps one vertex per face corner, so the two agree point for
/// point, not vertex for vertex: posed vertices are compared as sets of points, each one's nearest in the other.
/// The compressed files are the same character, with hair, through gltfpack and Blender's Draco export — see
/// ``GLTFReaderTests``. The small files written here say exactly what is in them.
@MainActor
struct GLTFCharacterTests {

    private func fixture(_ name: String) throws -> URL { try GLTFReaderTests.fixture(name) }
    private let layout = SkinnedModelTests.gameLayout()
    private let semantics = SkinnedModelTests.semantics

    /// A character read whole, as a game reads one.
    private func character(_ name: String) throws -> (rig: Rig, geometry: SkinnedGeometry) {
        let source = try SkinnedModel.read(url: fixture(name), vertexDescriptor: layout, semantics: semantics)
        return (source.rig, source.geometry)
    }

    /// Every vertex posed by `clip` at `time`, in the file's own space — the rig's place applied — skinned here as the
    /// skinning pass skins on the GPU.
    static func posed(_ rig: Rig, _ geometry: SkinnedGeometry, clip: AnimationClip?, at time: Float) -> [SIMD3<Float>] {
        var pose = SkeletonPose(skeleton: rig.skeleton)
        if let clip { pose.set(to: AnimationPlayhead(clip: clip, skeleton: rig.skeleton, looping: false, time: time)) }
        let palette = pose.skinningMatrices
        return (0..<geometry.vertexCount).map { v in
            var skin = simd_float4x4()
            for lane in 0..<4 { skin += palette[Int(geometry.joints[v][lane])] * geometry.weights[v][lane] }
            let p = rig.nodeTransform * skin * SIMD4(geometry.restPositions[v], 1)
            return SIMD3(p.x, p.y, p.z)
        }
    }

    /// The farthest any point of `points` is from its nearest in `others` — zero when every point of the one set is a
    /// point of the other. A grid of 2 cm cells finds the nearest; a point with nothing in the cells around it is
    /// measured against every point, so a far one is never missed.
    static func farthest(_ points: [SIMD3<Float>], from others: [SIMD3<Float>]) -> Float {
        let cell: Float = 0.02
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / cell).rounded(.down)) }
        var grid: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for p in others { grid[key(p), default: []].append(p) }
        var worst: Float = 0
        for p in points {
            let k = key(p)
            var best = Float.infinity
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for q in grid[k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] { best = min(best, simd_distance(p, q)) }
            } } }
            if best > cell { best = others.map { simd_distance(p, $0) }.min() ?? .infinity }
            worst = max(worst, best)
        }
        return worst
    }

    static func close(_ a: simd_float4x4, _ b: simd_float4x4, _ tolerance: Float) -> Bool {
        (0..<4).allSatisfy { c in simd_distance(a[c], b[c]) <= tolerance }
    }

    // MARK: One character, two formats

    @Test("A character exported to glTF and to USD gives the same skeleton")
    func sameSkeleton() throws {
        let gltf = try RigLoader.load(url: fixture("walker.glb")), usd = try RigLoader.load(url: fixture("walker.usda"))
        #expect(gltf.skeleton.jointCount == 12)
        #expect(gltf.skeleton.jointPaths == usd.skeleton.jointPaths)
        #expect(gltf.skeleton.parentIndices == usd.skeleton.parentIndices)
        for j in 0..<usd.skeleton.jointCount {
            #expect(Self.close(gltf.skeleton.restTransforms[j], usd.skeleton.restTransforms[j], 1e-5),
                    "rest \(usd.skeleton.jointPaths[j])")
            #expect(Self.close(gltf.skeleton.inverseBindTransforms[j], usd.skeleton.inverseBindTransforms[j], 1e-5),
                    "inverse bind \(usd.skeleton.jointPaths[j])")
        }
        #expect(Self.close(gltf.nodeTransform, usd.nodeTransform, 1e-6))
    }

    @Test("…the same clips, by name and length, posing every joint alike")
    func sameClips() throws {
        let gltf = try RigLoader.load(url: fixture("walker.glb")), usd = try RigLoader.load(url: fixture("walker.usda"))
        #expect(gltf.clips.map(\.name) == ["Walk", "Step"], "in the file's order")
        // Model I/O lists a USD file's clips in an order of its own, so they are paired by name.
        #expect(gltf.clips.map(\.name).sorted() == usd.clips.map(\.name).sorted())
        for a in gltf.clips {
            let b = try #require(usd.clip(named: a.name))
            #expect(abs(a.duration - b.duration) < 1e-5, "\(a.name): \(a.duration) and \(b.duration)")
            #expect(gltf.joints(notDrivenBy: a).isEmpty, "\(a.name) drives every joint")
            for time: Float in [0, 0.1, 0.25, 0.37, 0.5, 0.8, 1] where time <= b.duration {
                var p = SkeletonPose(skeleton: gltf.skeleton), q = SkeletonPose(skeleton: usd.skeleton)
                p.set(to: AnimationPlayhead(clip: a, skeleton: gltf.skeleton, looping: false, time: time))
                q.set(to: AnimationPlayhead(clip: b, skeleton: usd.skeleton, looping: false, time: time))
                for j in 0..<usd.skeleton.jointCount {
                    #expect(Self.close(p.modelTransform(ofJoint: j), q.modelTransform(ofJoint: j), 1e-4),
                            "\(a.name) at \(time): \(usd.skeleton.jointPaths[j])")
                }
            }
        }
    }

    @Test("…and the same posed vertices, at rest and through both clips")
    func samePosedVertices() throws {
        let gltf = try character("walker.glb"), usd = try character("walker.usda")
        #expect(gltf.geometry.meshCount == 6)
        #expect(simd_distance(gltf.geometry.bounds.minimum, usd.geometry.bounds.minimum) < 1e-4)
        #expect(simd_distance(gltf.geometry.bounds.maximum, usd.geometry.bounds.maximum) < 1e-4)
        let rest = (Self.posed(gltf.rig, gltf.geometry, clip: nil, at: 0), Self.posed(usd.rig, usd.geometry, clip: nil, at: 0))
        #expect(Self.farthest(rest.0, from: rest.1) < 1e-4)
        #expect(Self.farthest(rest.1, from: rest.0) < 1e-4)
        for name in ["Walk", "Step"] {
            let a = try #require(gltf.rig.clip(named: name)), b = try #require(usd.rig.clip(named: name))
            for time: Float in [0.1, 0.25, 0.4, 0.75] where time <= a.duration {
                let p = Self.posed(gltf.rig, gltf.geometry, clip: a, at: time)
                let q = Self.posed(usd.rig, usd.geometry, clip: b, at: time)
                // A pose that moved nothing would pass this; the walk moves the feet far more than the tolerance.
                #expect(Self.farthest(p, from: rest.0) > 0.02, "\(name) at \(time) moves the character")
                #expect(Self.farthest(p, from: q) < 1e-4, "\(name) at \(time): glTF to USD")
                #expect(Self.farthest(q, from: p) < 1e-4, "\(name) at \(time): USD to glTF")
            }
        }
    }

    @Test("A glTF character is skinned on the GPU where the USD one is posed")
    func skinsOnTheGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
              let queue = device.makeMTL4CommandQueue(), let allocator = device.makeCommandAllocator(),
              let commands = device.makeCommandBuffer(), let event = device.makeSharedEvent() else { return }
        let model = try SkinnedModel(url: fixture("walker.glb"), device: device, vertexDescriptor: layout,
                                     semantics: semantics)
        #expect(model.partCount == 6)
        #expect(model.materials.count == 6, "a draw per surface: canvas, leather, boots, skin, tunic, face")
        let tunic = try #require(model.materials.first { $0.name == "Tunic" })
        #expect(tunic.textures[.baseColor] != nil, "the tunic keeps its texture")
        let instance = try model.makeInstance()
        let walk = try #require(model.rig.clip(named: "Walk"))
        instance.pose.set(to: AnimationPlayhead(clip: walk, skeleton: model.rig.skeleton, looping: false, time: 0.3))

        let pass = try SkinningPass(device: device)
        let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        residency.addAllocations(model.allocations + instance.allocations)
        residency.commit()
        queue.addResidencySet(residency)
        commands.beginCommandBuffer(allocator: allocator)
        pass.encode(into: commands, frameSlot: 0, instances: [instance])
        commands.endCommandBuffer()
        queue.commit([commands])
        queue.signalEvent(event, value: 1)
        #expect(event.wait(untilSignaledValue: 1, timeoutMS: 5000))

        let positions = try #require(instance.posedBuffer(0, frameSlot: 0)).contents()
        let drawn = (0..<model.vertexCount).map { v in
            let p = positions.advanced(by: v * 12).loadUnaligned(as: (Float, Float, Float).self)
            let world = model.rig.nodeTransform * SIMD4(p.0, p.1, p.2, 1)
            return SIMD3(world.x, world.y, world.z)
        }
        let usd = try character("walker.usda")
        let expected = Self.posed(usd.rig, usd.geometry, clip: try #require(usd.rig.clip(named: "Walk")), at: 0.3)
        #expect(Self.farthest(drawn, from: expected) < 1e-4)
        #expect(Self.farthest(expected, from: drawn) < 1e-4)
    }

    // MARK: Compressed

    /// gltfpack quantizes positions and folds the way back to metres into every inverse bind matrix, resamples the walk
    /// at 30 a second and drops the channels that never move; Blender's Draco export writes its joints in its own order
    /// and its unmoving channels as steps. None of it may show in the character.
    @Test("Draco-, meshopt- and quantized glTF characters pose as the plain one does",
          arguments: ["gltfpack-quantized.glb", "gltfpack-meshopt-khr.glb", "blender-character-draco.glb"])
    func compressed(_ name: String) throws {
        let packed = try character(name), usd = try character("walker.usda")
        #expect(Set(packed.rig.skeleton.jointPaths) == Set(usd.rig.skeleton.jointPaths))
        for (j, path) in usd.rig.skeleton.jointPaths.enumerated() {
            let k = try #require(packed.rig.skeleton.index(ofJoint: path))
            #expect(Self.close(packed.rig.skeleton.restTransforms[k], usd.rig.skeleton.restTransforms[j], 1e-4), "rest \(path)")
            #expect(Self.close(packed.rig.skeleton.inverseBindTransforms[k], usd.rig.skeleton.inverseBindTransforms[j], 1e-4),
                    "inverse bind \(path)")
        }
        #expect(packed.rig.clips.map(\.name) == ["Walk"])
        let walk = try #require(packed.rig.clip(named: "Walk")), reference = try #require(usd.rig.clip(named: "Walk"))
        #expect(abs(walk.duration - reference.duration) < 1e-4)
        #expect(packed.geometry.bounds.maximum.y > 1.8 && packed.geometry.bounds.maximum.y < 2,
                "in metres, standing up — not quantized integers")
        // The compressed files carry hair the plain export does not, so every plain point must be on the packed
        // character, and not the other way round.
        for time: Float in [0, 0.2, 0.5, 0.9] {
            let p = Self.posed(packed.rig, packed.geometry, clip: walk, at: time)
            let q = Self.posed(usd.rig, usd.geometry, clip: reference, at: time)
            #expect(Self.farthest(q, from: p) < 0.003, "\(name) at \(time)")
        }
    }

    // MARK: Small files

    /// A rig in centimetres under an armature scaled by 0.01, with a node between two joints that is not a joint, a
    /// skinned triangle (one corner with eight influences), a sword hung under the arm with no skin, and three clips: a
    /// step and a slerp, a cubic spline, and one whose keys do not pair with its values.
    ///
    /// Nodes: 0 Armature (0.01) → 1 Root (0, 100, 0) → 2 Offset (0, 10, 0) → 3 Arm (0, 50, 0) → 5 Sword (10, 0, 0);
    /// 4 Body, skinned, at the scene's root. The skin's joints are Root and Arm.
    /// - Parameter offsetIsJoint: the skin names Offset as a joint too.
    static func centimetreRig(clipsOnly: Bool = false, offsetIsJoint: Bool = false,
                              animations: [String] = ["Swing", "Bob", "Broken"]) -> Builder {
        var b = Builder()
        let scale = simd_float4x4(diagonal: SIMD4(0.01, 0.01, 0.01, 1))
        func translate(_ y: Float) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(0, y, 0, 1)
            return m
        }
        b.append("nodes", ["name": "Armature", "scale": [0.01, 0.01, 0.01], "children": [1]])
        b.append("nodes", ["name": "Root", "translation": [0, 100, 0], "children": [2]])
        b.append("nodes", ["name": "Offset", "translation": [0, 10, 0], "children": [3]])
        b.append("nodes", clipsOnly ? ["name": "Arm", "translation": [0, 50, 0]]
                                    : ["name": "Arm", "translation": [0, 50, 0], "children": [5]])
        var sceneNodes = [0]
        if !clipsOnly {
            // The body: corners at (0.1, 1, 0) on Root, (0.1, 1.6, 0) on Arm, and (0.2, 1.3, 0) on eight influences —
            // Root 0.3 + 0.06, Arm 0.2 + 0.4 + 0.04, of which the weakest (Arm 0.04) is dropped.
            let body: [Float] = [0.1, 1, 0, 0.1, 1.6, 0, 0.2, 1.3, 0]
            let a: UInt16 = offsetIsJoint ? 2 : 1   // the arm, in the skin's list
            let joints0: [UInt16] = [0, 0, 0, 0, a, 0, 0, 0, 0, a, 0, 0]
            let weights0: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 0.3, 0.2, 0, 0]
            let joints1: [UInt16] = [0, 0, 0, 0, 0, 0, 0, 0, a, 0, a, 0]
            let weights1: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0.4, 0.06, 0.04, 0]
            let attributes: [String: Int] = [
                "POSITION": b.accessor(body, type: "VEC3"),
                "JOINTS_0": b.accessor(joints0.withUnsafeBytes { Data($0) }, componentType: 5123, type: "VEC4", count: 3),
                "WEIGHTS_0": b.accessor(weights0, type: "VEC4"),
                "JOINTS_1": b.accessor(joints1.withUnsafeBytes { Data($0) }, componentType: 5123, type: "VEC4", count: 3),
                "WEIGHTS_1": b.accessor(weights1, type: "VEC4"),
            ]
            b.append("meshes", ["name": "Body", "primitives": [["attributes": attributes, "indices": b.indices([0, 1, 2])]]])
            b.append("nodes", ["name": "Body", "mesh": 0, "skin": 0])
            // The sword, in centimetres in the arm's space.
            let sword: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
            b.append("meshes", ["name": "Sword", "primitives": [["attributes": ["POSITION": b.accessor(sword, type: "VEC3")],
                                                                 "indices": b.indices([0, 1, 2])]]])
            b.append("nodes", ["name": "Sword", "mesh": 1, "translation": [10, 0, 0]])
            sceneNodes.append(4)
            // Bound where the joints stand: each one's world transform, inverted.
            let binds = (offsetIsJoint ? [scale * translate(100), scale * translate(110), scale * translate(160)]
                                       : [scale * translate(100), scale * translate(160)]).map(\.inverse)
            b.append("skins", ["joints": offsetIsJoint ? [1, 2, 3] : [1, 3], "inverseBindMatrices": b.accessor(binds.flatMap { m in
                (0..<4).flatMap { c in [m[c].x, m[c].y, m[c].z, m[c].w] } }, type: "MAT4")])
        }
        b.json["scenes"] = [["nodes": sceneNodes]]
        b.json["scene"] = 0

        var list: [[String: Any]] = []
        func sampler(_ times: [Float], _ values: [Float], _ type: String, _ interpolation: String,
                     into samplers: inout [[String: Any]]) -> Int {
            samplers.append(["input": b.accessor(times, type: "SCALAR"), "output": b.accessor(values, type: type),
                             "interpolation": interpolation])
            return samplers.count - 1
        }
        for animation in animations {
            var samplers: [[String: Any]] = [], channels: [[String: Any]] = []
            switch animation {
            case "Swing":
                // The root steps up 20 cm at one second; the arm turns a quarter about z. Keys from 2 s: a clip starts
                // at zero wherever its keys do.
                let root = sampler([2, 3], [0, 100, 0, 0, 120, 0], "VEC3", "STEP", into: &samplers)
                let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)).vector
                let arm = sampler([2, 3], [0, 0, 0, 1, quarter.x, quarter.y, quarter.z, quarter.w], "VEC4", "LINEAR",
                                  into: &samplers)
                channels = [["sampler": root, "target": ["node": 1, "path": "translation"]],
                            ["sampler": arm, "target": ["node": 3, "path": "rotation"]]]
            case "Bob":
                // In-tangent, value, out-tangent per key: 100 → 100 with tangents 40 and −40, so 110 at half time.
                let root = sampler([0, 1], [0, 0, 0, 0, 100, 0, 0, 40, 0, 0, -40, 0, 0, 100, 0, 0, 0, 0], "VEC3",
                                   "CUBICSPLINE", into: &samplers)
                channels = [["sampler": root, "target": ["node": 1, "path": "translation"]]]
            case "Broken":
                let root = sampler([0, 0.5, 1], [0, 100, 0, 0, 110, 0], "VEC3", "LINEAR", into: &samplers)
                channels = [["sampler": root, "target": ["node": 1, "path": "translation"]]]
            default:
                // Any other name: a clip moving the arm, named as asked.
                let arm = sampler([0, 1], [0, 0, 0, 1, 0, 0, 0.7071068, 0.7071068], "VEC4", "LINEAR", into: &samplers)
                channels = [["sampler": arm, "target": ["node": 3, "path": "rotation"]]]
            }
            list.append(["name": animation, "samplers": samplers, "channels": channels])
        }
        b.json["animations"] = list
        return b
    }

    @Test("A centimetre rig keeps its centimetres under its armature's scale, as a USD one does")
    func centimetreRig() throws {
        var warnings: [RigLoader.Warning] = []
        let url = try Self.centimetreRig().write(to: GLTFReaderTests.folder(), name: "centimetres", as: .glb)
        let rig = try RigLoader.load(url: url) { warnings.append($0) }
        #expect(rig.skeleton.jointPaths == ["Root", "Root/Arm"], "Offset is not a joint; Armature is the rig's place")
        #expect(Self.close(rig.nodeTransform, simd_float4x4(diagonal: SIMD4(0.01, 0.01, 0.01, 1)), 1e-7))
        #expect(simd_distance(rig.skeleton.restTransforms[0].columns.3, SIMD4(0, 100, 0, 1)) < 1e-4, "centimetres")
        #expect(simd_distance(rig.skeleton.restTransforms[1].columns.3, SIMD4(0, 60, 0, 1)) < 1e-4,
                "the node between folded into the arm")
        #expect(simd_distance(rig.skeleton.inverseBindTransforms[1].columns.3, SIMD4(0, -160, 0, 1)) < 1e-3,
                "bound where it stands, in skeleton space")
        #expect(rig.clips.map(\.name) == ["Swing", "Bob"])
        #expect(warnings.count == 1)
        guard case .clipDropped(let file, let clip, let reason)? = warnings.first else {
            Issue.record("expected the broken clip reported, got \(warnings)")
            return
        }
        #expect(file == "centimetres.glb" && clip == "Broken")
        #expect(reason.contains("3 key times and 2 values"), "\(reason)")
    }

    @Test("Steps stay steps, cubic splines bend, and a clip starts at zero")
    func interpolation() throws {
        let rig = try RigLoader.load(url: Self.centimetreRig().write(to: GLTFReaderTests.folder(), name: "keys"))
        let swing = try #require(rig.clip(named: "Swing")), bob = try #require(rig.clip(named: "Bob"))
        #expect(swing.duration == 1, "keys at 2 and 3 seconds play from 0 to 1")
        func root(_ clip: AnimationClip, _ time: Float) -> SIMD3<Float> {
            var pose = SkeletonPose(skeleton: rig.skeleton)
            pose.set(to: AnimationPlayhead(clip: clip, skeleton: rig.skeleton, looping: false, time: time))
            let t = pose.modelTransform(ofJoint: 0).columns.3
            return SIMD3(t.x, t.y, t.z)
        }
        #expect(abs(root(swing, 0.5).y - 100) < 1e-4, "held until the step")
        #expect(abs(root(swing, 0.999).y - 100) < 1e-4, "held right up to it")
        #expect(abs(root(swing, 1).y - 120) < 1e-4, "and taken at it")
        #expect(abs(root(bob, 0.5).y - 110) < 1e-3, "the curve, not the straight line between its keys")
        #expect(abs(root(bob, 0.25).y - (0.84375 * 100 + 0.140625 * 40 + 0.15625 * 100 + 0.046875 * 40)) < 0.05,
                "a quarter of the way: the Hermite basis, sampled thirty times a second")
    }

    /// Skinned by hand as glTF says — each joint's world transform times its inverse bind, by weight — against the
    /// engine's skeleton-space skinning with the rig's place in front.
    @Test("A skinned glTF vertex goes where glTF says, eight influences and rigid attachments included")
    func skinnedAsGLTFSays() throws {
        let url = try Self.centimetreRig().write(to: GLTFReaderTests.folder(), name: "skinned", as: .glb)
        let source = try SkinnedModel.read(url: url, vertexDescriptor: layout, semantics: semantics)
        let rig = source.rig, g = source.geometry
        #expect(g.vertexCount == 6 && g.meshCount == 2, "the body and the sword")
        func vertex(at p: SIMD3<Float>) throws -> Int {
            try #require((0..<g.vertexCount).first { simd_distance(rig.nodeTransform * SIMD4(g.restPositions[$0], 1),
                                                                   SIMD4(p, 1)) < 1e-5 }, "a vertex at \(p)")
        }
        let blended = try vertex(at: SIMD3(0.2, 1.3, 0))
        var share: [UInt16: Float] = [:]
        for lane in 0..<4 { share[g.joints[blended][lane], default: 0] += g.weights[blended][lane] }
        #expect(abs((share[0] ?? 0) - 0.375) < 1e-5 && abs((share[1] ?? 0) - 0.625) < 1e-5,
                "the four strongest of eight, summing to one: \(share)")
        #expect(!(0..<4).contains { g.weights[blended][$0] > 0.03 && g.weights[blended][$0] < 0.05 },
                "the weakest, 0.04, is the one dropped")
        let swordTip = try vertex(at: SIMD3(0.1, 1.61, 0))
        #expect(g.weights[swordTip].x == 1 && g.joints[swordTip].x == 1, "the sword is bound wholly to the arm")

        let swing = try #require(rig.clip(named: "Swing"))
        let scale = simd_float4x4(diagonal: SIMD4(0.01, 0.01, 0.01, 1))
        func translate(_ x: Float, _ y: Float) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(x, y, 0, 1)
            return m
        }
        let binds = [scale * translate(0, 100), scale * translate(0, 160)].map(\.inverse)
        for time: Float in [0.5, 1] {
            let rootWorld = scale * translate(0, time < 1 ? 100 : 120)
            let turn = simd_float4x4(simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)), time))
            let armWorld = rootWorld * translate(0, 60) * turn
            let posed = Self.posed(rig, g, clip: swing, at: time)
            let expected: [(SIMD3<Float>, simd_float4x4)] = [
                (SIMD3(0.1, 1, 0), rootWorld * binds[0]),
                (SIMD3(0.1, 1.6, 0), armWorld * binds[1]),
                (SIMD3(0.2, 1.3, 0), (rootWorld * binds[0]) * 0.375 + (armWorld * binds[1]) * 0.625),
            ]
            for (rest, skin) in expected {
                let want = skin * SIMD4(rest, 1)
                #expect(simd_distance(posed[try vertex(at: rest)], SIMD3(want.x, want.y, want.z)) < 1e-5,
                        "\(rest) at \(time)")
            }
            // The sword's tip, a centimetre up from its node, ten along the arm.
            let tip = armWorld * translate(10, 0) * SIMD4(0, 1, 0, 1)
            #expect(simd_distance(posed[swordTip], SIMD3(tip.x, tip.y, tip.z)) < 1e-5, "sword at \(time)")
        }
    }

    @Test("A glTF clip file's only clip takes the file's name; its skeleton is ignored")
    func clipFile() throws {
        let folder = try GLTFReaderTests.folder()
        let base = try Self.centimetreRig(animations: []).write(to: folder, name: "base", as: .glb)
        let wave = try Self.centimetreRig(animations: ["exporter_take_001"]).write(to: folder, name: "Wave")
        var warnings: [RigLoader.Warning] = []
        let rig = try RigLoader.load(url: base, clipURLs: [wave]) { warnings.append($0) }
        #expect(rig.clips.map(\.name) == ["Wave"])
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(rig.joints(notDrivenBy: try #require(rig.clip(named: "Wave"))) == ["Root"], "it moves the arm")
    }

    /// A file of animation alone has no skin to say which nodes are joints, so the nodes its clips move and every node
    /// between two of them are taken: a joint mid-chain that never moves — whose channel an exporter like gltfpack
    /// drops — is still a joint, and the paths below it still match the skinned rig's. The clip itself names only the
    /// joints it moves, and leaves the unmoving one at rest.
    @Test("An animation-only glTF file's clips drive the skinned rig's joints, an unmoving one between them kept")
    func animationOnly() throws {
        let folder = try GLTFReaderTests.folder()
        let clipsURL = try Self.centimetreRig(clipsOnly: true, animations: ["Swing"]).write(to: folder, name: "moves")
        let clips = try RigLoader.clips(url: clipsURL)
        #expect(clips.first?.jointPaths == ["Root", "Root/Offset/Arm"])
        let base = try RigLoader.load(url: Self.centimetreRig(offsetIsJoint: true, animations: []).write(to: folder, name: "rig"))
        #expect(base.skeleton.jointPaths == ["Root", "Root/Offset", "Root/Offset/Arm"])
        #expect(base.joints(notDrivenBy: try #require(clips.first)) == ["Root/Offset"])
    }

    /// Files that would otherwise stop the program or never finish: a node that is its own ancestor, a joint index that
    /// is not a number, joints that cannot be put parent first, and a cubic clip a hundred years long.
    @Test("A malformed glTF character is refused or its clip dropped — never a crash or a hang")
    func malformed() throws {
        let folder = try GLTFReaderTests.folder()

        var cycle = Self.centimetreRig(animations: [])
        var nodes = cycle.json["nodes"] as! [[String: Any]]
        nodes[3]["children"] = [5, 1]   // the arm parents the root, which is the arm's ancestor
        cycle.json["nodes"] = nodes
        #expect(throws: RigLoaderError.self) { try RigLoader.load(url: cycle.write(to: folder, name: "cycle")) }
        #expect(throws: GLTFError.unreadable(file: "cycle.gltf")) {
            try ImportedModel.read(gltf: cycle.write(to: folder, name: "cycle"))
        }

        var notANumber = Self.centimetreRig(animations: [])
        var meshes = notANumber.json["meshes"] as! [[String: Any]]
        var primitives = meshes[0]["primitives"] as! [[String: Any]]
        var attributes = primitives[0]["attributes"] as! [String: Int]
        attributes["JOINTS_0"] = notANumber.accessor([.nan, 0, 0, 0, 1, 0, 0, 0, 1e30, 0, 0, 0], type: "VEC4")
        primitives[0]["attributes"] = attributes
        meshes[0]["primitives"] = primitives
        notANumber.json["meshes"] = meshes
        #expect(throws: RigLoaderError.self) {
            try SkinnedModel.read(url: notANumber.write(to: folder, name: "nan"), vertexDescriptor: layout, semantics: semantics)
        }

        // The child joint and its parent both outside the scene, the child first: no order puts them parent first.
        var outside = Builder()
        outside.append("nodes", ["name": "Hand"])
        outside.append("nodes", ["name": "Arm", "children": [0]])
        outside.append("nodes", ["name": "Body", "mesh": 0, "skin": 0])
        outside.append("meshes", ["primitives": [["attributes": ["POSITION": outside.accessor([0, 0, 0, 1, 0, 0, 0, 1, 0],
                                                                                               type: "VEC3")]]]])
        outside.append("skins", ["joints": [0, 1]])
        outside.json["scenes"] = [["nodes": [2]]]
        #expect(throws: RigLoaderError.self) { try RigLoader.load(url: outside.write(to: folder, name: "outside")) }

        var long = Self.centimetreRig(animations: ["Swing"])
        var samplers: [[String: Any]] = []
        samplers.append(["input": long.accessor([0, 3e9], type: "SCALAR"),
                         "output": long.accessor([0, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 0], type: "VEC3"),
                         "interpolation": "CUBICSPLINE"])
        var animations = long.json["animations"] as! [[String: Any]]
        animations.append(["name": "Century", "samplers": samplers,
                           "channels": [["sampler": 0, "target": ["node": 1, "path": "translation"]]]])
        long.json["animations"] = animations
        var warnings: [RigLoader.Warning] = []
        let rig = try RigLoader.load(url: long.write(to: folder, name: "long")) { warnings.append($0) }
        #expect(rig.clips.map(\.name) == ["Swing"])
        guard case .clipDropped(_, "Century", let reason)? = warnings.first else {
            Issue.record("expected the century-long clip dropped, got \(warnings)")
            return
        }
        #expect(reason.contains("hour"))
    }

    @Test("A damaged glTF character is said as one, by file")
    func damaged() throws {
        let url = try GLTFReaderTests.folder().appending(path: "torn.glb")
        try Data("glTF".utf8).write(to: url)
        #expect(throws: RigLoaderError.self) { try RigLoader.load(url: url) }
        do {
            _ = try RigLoader.load(url: url)
        } catch let error as RigLoaderError {
            guard case .unreadable = error else { Issue.record("\(error)"); return }
            #expect(error.description.contains("torn.glb"))
        }
        let noSkin = try GLTFReaderTests.folder()
        var b = Builder()
        b.quad()
        #expect(throws: RigLoaderError.noSkeleton("statue.gltf")) {
            try RigLoader.load(url: b.write(to: noSkin, name: "statue"))
        }
    }
}

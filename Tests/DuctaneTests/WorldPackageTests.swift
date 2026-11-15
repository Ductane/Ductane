import Foundation
import Metal
import ModelIO
import Testing
import simd
@testable import Ductane

/// **A scene package opened for a game**: unpacked once, its world read, its props loaded through ``MeshLoader`` with
/// their textures, its ground and collision shapes read from the files beside the description.
@Suite("A scene package")
struct WorldPackageTests {

    /// A package as a world editor writes one: the scene first, a textured prop in a folder of its own, the description
    /// and its binary files under `game/`.
    private static func entries() throws -> [(String, Data)] {
        let prop = try Data(contentsOf: #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda")))
        let image = try Data(contentsOf: #require(Bundle.module.url(forResource: "material-map", withExtension: "png")))
        let heights: [Float] = (0..<9).map { Float($0 % 3) }
        let colours = [SIMD3<Float>](repeating: SIMD3(0.2, 0.4, 0.1), count: 9)
        let ramp: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, -1)]
        var placed = matrix_identity_float4x4
        placed.columns.3 = SIMD4(2, 0, -3, 1)
        let world = WorldFile(name: "Clearing", props: ["props/1_textured-quad/textured-quad.usda"],
                              collisionShapes: [0: "game/collision/0.f32"],
                              placements: [WorldFile.Placement(prop: 0, transform: placed)],
                              ground: WorldFile.Ground(size: 2, resolution: 2),
                              markers: [WorldFile.Marker(kind: "spawn", position: SIMD3(0, 1, 0))])
        let scene = #"#usda 1.0\#n(\#n    defaultPrim = "World"\#n)\#ndef Xform "World" {}\#n"#
        return [("Clearing.usda", Data(scene.utf8)),
                ("props/1_textured-quad/textured-quad.usda", prop),
                ("props/1_textured-quad/material-map.png", image),
                (WorldPackage.descriptionPath, try world.data()),
                ("game/ground.f32", WorldFile.Ground.heightsData(heights)),
                ("game/ground.rgb", WorldFile.Ground.coloursData(colours)),
                ("game/collision/0.f32", WorldFile.CollisionShape.data(ramp))]
    }

    private static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WorldPackageTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Everything the package holds comes out: the world, a prop with its texture, the ground and a shape")
    func opens() throws {
        let work = Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Clearing.usdz")
        try StoredZip.data(Self.entries()).write(to: url)
        let package = try WorldPackage(contentsOf: url, cache: work.appending(path: "Cache"))

        #expect(package.world.name == "Clearing")
        #expect(package.world.markers("spawn").count == 1)
        #expect(package.world.placements[0].transform.columns.3 == SIMD4(2, 0, -3, 1))
        let ground = try #require(try package.ground())
        #expect(ground.height(x: 0, z: 0) == 1)
        #expect(try package.collisionShapes()[0]?.count == 3)

        // The prop loads from the unpacked copy, and its texture is found beside it.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float3; layout.attributes[0].offset = 0; layout.attributes[0].bufferIndex = 0
        layout.attributes[1].format = .float3; layout.attributes[1].offset = 12; layout.attributes[1].bufferIndex = 0
        layout.attributes[2].format = .float2; layout.attributes[2].offset = 24; layout.attributes[2].bufferIndex = 0
        layout.layouts[0].stride = 32
        let meshes = try MeshLoader.load(url: package.propURL(0), device: device, vertexDescriptor: layout,
                                         semantics: [0: MDLVertexAttributePosition, 1: MDLVertexAttributeNormal,
                                                     2: MDLVertexAttributeTextureCoordinate])
        let source = try #require(meshes.first?.materials.first?.textures[.baseColor])
        guard case .url(let map) = source else { Issue.record("the base colour did not come through as a file"); return }
        #expect(FileManager.default.fileExists(atPath: map.path), "the texture is beside the prop")
        #expect(map.path.hasPrefix(package.propFolder(0).path))
    }

    @Test("Opened again it is used as it was unpacked; a changed package is unpacked again")
    func reusesUntilChanged() throws {
        let work = Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Clearing.usdz"), cache = work.appending(path: "Cache")
        try StoredZip.data(Self.entries()).write(to: url)
        let first = try WorldPackage(contentsOf: url, cache: cache)
        let marker = first.folder.appending(path: "left-by-the-test")
        try Data().write(to: marker)
        _ = try WorldPackage(contentsOf: url, cache: cache)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the same package is not unpacked twice")

        var entries = try Self.entries()
        var world = try WorldFile.read(entries[3].1)
        world.name = "Clearing at dusk"
        entries[3].1 = try world.data()
        try StoredZip.data(entries).write(to: url)
        let changed = try WorldPackage(contentsOf: url, cache: cache)
        #expect(changed.world.name == "Clearing at dusk")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a changed package replaces its copy")
    }

    @Test("A folder holding the same files is read in place")
    func folder() throws {
        let work = Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        for (name, data) in try Self.entries() {
            let target = work.appending(path: name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        let package = try WorldPackage(contentsOf: work)
        #expect(package.folder == work)
        #expect(package.world.props.count == 1)
    }

    @Test("A package naming a file outside itself is refused, and one without a description says so")
    func refusals() throws {
        let work = Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let escaping = work.appending(path: "Escaping.usdz")
        try StoredZip.data(Self.entries() + [("../outside.txt", Data("no".utf8))]).write(to: escaping)
        #expect(throws: WorldPackage.OpenError.unsafeEntry("../outside.txt")) {
            try WorldPackage(contentsOf: escaping, cache: work.appending(path: "Cache"))
        }
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "outside.txt").path))

        let bare = work.appending(path: "Bare.usdz")
        try StoredZip.data([("Bare.usda", Data("#usda 1.0\n".utf8))]).write(to: bare)
        #expect(throws: WorldPackage.OpenError.noDescription("Bare.usdz")) {
            try WorldPackage(contentsOf: bare, cache: work.appending(path: "Cache"))
        }
        for name in ["/etc/x", "a/../b", "./a", "a//b", "a\\b"] { #expect(WorldPackage.safePath(name) == nil, "\(name)") }

        // A description naming a file outside the package is refused, though every entry is inside it.
        var entries = try Self.entries()
        var world = try WorldFile.read(entries[3].1)
        world.collisionShapes = [0: "../../outside.f32"]
        entries[3].1 = try world.data()
        let naming = work.appending(path: "Naming.usdz")
        try StoredZip.data(entries).write(to: naming)
        #expect(throws: WorldFile.ReadError.unsafePath("../../outside.f32")) {
            try WorldPackage(contentsOf: naming, cache: work.appending(path: "Cache"))
        }
        #expect(WorldPackage.safePath("props/1_A/A.usda") == "props/1_A/A.usda")
    }
}

/// A zip that stores every entry, as a `.usdz` must — just enough of the format to make a package in a test.
enum StoredZip {
    static func data(_ entries: [(String, Data)]) -> Data {
        var out = Data(), directory = Data()
        func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (name, bytes) in entries {
            let offset = out.count, nameBytes = Data(name.utf8), crc = crc32(bytes)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(bytes.count), &out); u32(UInt32(bytes.count), &out)
            u16(nameBytes.count, &out); u16(0, &out); out.append(nameBytes); out.append(bytes)
            u32(0x0201_4B50, &directory); u16(20, &directory); u16(20, &directory); u16(0, &directory); u16(0, &directory)
            u16(0, &directory); u16(0, &directory); u32(crc, &directory); u32(UInt32(bytes.count), &directory)
            u32(UInt32(bytes.count), &directory); u16(nameBytes.count, &directory); u16(0, &directory); u16(0, &directory)
            u16(0, &directory); u16(0, &directory); u32(0, &directory); u32(UInt32(offset), &directory)
            directory.append(nameBytes)
        }
        let start = out.count
        out.append(directory)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(directory.count), &out); u32(UInt32(start), &out); u16(0, &out)
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

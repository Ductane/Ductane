//
//  WorldGroundLayersTests.swift
//  DuctaneTests
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import Testing
import UniformTypeIdentifiers
@testable import Ductane

/// **Textured ground layers**: a texture set packed into the two slices the shader reads, carried in a world file, read
/// back from a package with its weights, and drawn.
@Suite("Textured ground layers")
@MainActor
struct WorldGroundLayersTests {

    /// Writes a `side`² PNG, every pixel `rgb` — or one channel, gray.
    static func png(_ url: URL, side: Int = 8, rgb: SIMD3<UInt8>, gray: Bool = false,
                    pixel: ((Int, Int) -> SIMD3<UInt8>)? = nil) throws {
        let channels = gray ? 1 : 4
        var bytes = [UInt8](repeating: 255, count: side * side * channels)
        for y in 0..<side {
            for x in 0..<side {
                let c = pixel?(x, y) ?? rgb
                let o = (y * side + x) * channels
                if gray { bytes[o] = c.x } else { bytes[o] = c.x; bytes[o + 1] = c.y; bytes[o + 2] = c.z }
            }
        }
        let space = gray ? CGColorSpaceCreateDeviceGray() : try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * channels, space: space,
                                             bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue
                                                              : CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WorldGroundLayersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A set is packed as the shader reads it: colour and height, normal turned to DirectX's way, roughness, occlusion")
    func packs() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let colour = folder.appending(path: "mud_diff.png"), normal = folder.appending(path: "mud_nor_gl.png")
        let rough = folder.appending(path: "mud_rough.png"), height = folder.appending(path: "mud_disp.png")
        try Self.png(colour, rgb: SIMD3(200, 100, 50))
        try Self.png(normal, rgb: SIMD3(140, 200, 255))
        try Self.png(rough, rgb: SIMD3(90, 90, 90), gray: true)
        try Self.png(height, rgb: SIMD3(30, 30, 30), gray: true)
        let set = WorldGroundTexture(colour: colour, normal: normal, roughness: rough, height: height, tileSize: 3)
        let (albedo, surface) = try WorldGroundTextures.packed(set, side: 4)
        #expect(Array(albedo[0..<4]) == [200, 100, 50, 30], "colour as drawn, the height in alpha")
        #expect(surface[0] == 140)
        #expect(surface[1] == 55, "OpenGL's green turned down the image")
        #expect(surface[2] == 90 && surface[3] == 255, "roughness from its map, no occlusion: none")

        // A DirectX map is kept as it is; with nothing but colour, the defaults: mid height, flat, rough, unoccluded.
        let dx = WorldGroundTexture(colour: colour, normal: normal, normalIsDirectX: true)
        #expect(try WorldGroundTextures.packed(dx, side: 4).surface[1] == 200)
        let bare = try WorldGroundTextures.packed(WorldGroundTexture(colour: colour), side: 4)
        #expect(bare.albedo[3] == 128)
        #expect(Array(bare.surface[0..<4]) == [128, 128, WorldGroundTextures.defaultRoughness, 255])

        // Occlusion, roughness and metalness packed in one file: occlusion from red, roughness from green.
        let arm = folder.appending(path: "mud_arm.png")
        try Self.png(arm, rgb: SIMD3(180, 70, 0))
        let packed = try WorldGroundTextures.packed(WorldGroundTexture(colour: colour, packed: arm), side: 4)
        #expect(packed.surface[2] == 70 && packed.surface[3] == 180)

        #expect(throws: WorldGroundTexturesError.self) {
            try WorldGroundTextures.packed(WorldGroundTexture(colour: folder.appending(path: "missing.png")), side: 4)
        }
    }

    @Test("A colour map's average colour, linear; the tile size kept within reason")
    func averageAndTile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "grass.png")
        try Self.png(url, rgb: SIMD3(0, 0, 0)) { x, _ in x < 4 ? SIMD3(255, 255, 255) : SIMD3(0, 0, 0) }
        let average = try #require(WorldGroundTextures.averageColour(of: url))
        #expect(abs(average.x - 0.5) < 0.02 && abs(average.y - 0.5) < 0.02)
        #expect(WorldGroundTexture(colour: url, tileSize: 500).tileSize == 50)
        #expect(WorldGroundTexture(colour: url, tileSize: .nan).tileSize == 1)
        #expect(WorldGroundTextures.size(for: .full) == 2048 && WorldGroundTextures.size(for: .quarter) == 512)
    }

    @Test("Weights are written as shares of 255, a point's eight together")
    func weights() {
        var out = [UInt8](repeating: 9, count: 4 * 8)
        let w: [SIMD8<Float>] = [SIMD8(1, 0, 0, 0, 0, 0, 0, 0), SIMD8(0.5, 0.5, 0, 0, 0, 0, 0, 0),
                                 SIMD8(0, 0, 0, 0, 0, 0, 0, 1), SIMD8(0.25, 0, 0.75, 0, 0, 0, 0, 0)]
        out.withUnsafeMutableBufferPointer { WorldGroundWeights.write(w, resolution: 1, xs: 0...1, zs: 0...1, into: $0.baseAddress!) }
        #expect(Array(out[0..<8]) == [255, 0, 0, 0, 0, 0, 0, 0])
        #expect(out[8] == 128 && out[9] == 128)
        #expect(out[23] == 255)
        #expect(out[24] == 64 && out[26] == 191)
    }

    @Test("A world file carries each layer's colour and texture set, and one without them still reads")
    func worldFile() throws {
        var ground = WorldFile.Ground(size: 4, resolution: 2, weights: "game/ground.weights", layers: ["Grass", "Rock"])
        ground.layerColours = [[0.1, 0.3, 0.05], [0.4, 0.4, 0.4]]
        ground.textures = [WorldFile.Ground.Texture(map: "textures/ground/1/grass.png", normal: "textures/ground/1/grass_n.png",
                                                    normalIsDirectX: true, tileSize: 2.5), nil]
        let data = try JSONEncoder().encode(ground)
        let back = try JSONDecoder().decode(WorldFile.Ground.self, from: data)
        #expect(back == ground)
        #expect(back.textures?[0]?.files == ["textures/ground/1/grass.png", "textures/ground/1/grass_n.png"])
        let old = try JSONDecoder().decode(WorldFile.Ground.self, from: Data(#"{"size":4,"resolution":2,"heights":"h","colours":"c"}"#.utf8))
        #expect(old.textures == nil && old.layerColours == nil)
    }

    /// A package whose 2 × 2 ground has two layers — grass textured, rock not — the left half grass, the right rock.
    private static func texturedPackage(textured: Bool = true) throws -> (WorldPackage, URL) {
        let folder = try Self.folder()
        try FileManager.default.createDirectory(at: folder.appending(path: "game"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "textures/ground/1_Grass"), withIntermediateDirectories: true)
        try Self.png(folder.appending(path: "textures/ground/1_Grass/grass.png"), side: 16, rgb: .zero) { x, y in
            (x / 4 + y / 4) % 2 == 0 ? SIMD3(250, 30, 30) : SIMD3(30, 30, 250)
        }
        var ground = WorldFile.Ground(size: 4, resolution: 2, weights: "game/ground.weights", layers: ["Grass", "Rock"])
        if textured {
            ground.layerColours = [[0.1, 0.3, 0.05], [0.4, 0.4, 0.4]]
            ground.textures = [WorldFile.Ground.Texture(map: "textures/ground/1_Grass/grass.png", tileSize: 1), nil]
        }
        let world = WorldFile(name: "Field", props: [], placements: [], ground: ground, sky: WorldFile.Sky(timeOfDay: 12))
        try world.data().write(to: folder.appending(path: WorldPackage.descriptionPath))
        try WorldFile.Ground.heightsData([Float](repeating: 0, count: 9)).write(to: folder.appending(path: "game/ground.f32"))
        try WorldFile.Ground.coloursData([SIMD3<Float>](repeating: SIMD3(0.2, 0.4, 0.1), count: 9))
            .write(to: folder.appending(path: "game/ground.rgb"))
        var weights = Data()
        for _ in 0..<3 { for x in 0..<3 { weights += x == 2 ? [0, 255, 0, 0, 0, 0, 0, 0] : [255, 0, 0, 0, 0, 0, 0, 0] } }
        try weights.write(to: folder.appending(path: "game/ground.weights"))
        return (try WorldPackage(contentsOf: folder), folder)
    }

    @Test("A package's ground brings its textured layers and the weights to blend them by")
    func packageGround() throws {
        let (package, folder) = try Self.texturedPackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ground = try #require(try package.groundSource())
        #expect(ground.isTextured)
        #expect(ground.paintedLayers.count == 2)
        #expect(ground.paintedLayers[0].texture?.colour.lastPathComponent == "grass.png")
        #expect(ground.paintedLayers[0].texture?.tileSize == 1)
        #expect(ground.paintedLayers[1].texture == nil && ground.paintedLayers[1].colour == SIMD3(0.4, 0.4, 0.4))
        var out = [UInt8](repeating: 0, count: 9 * 8)
        out.withUnsafeMutableBufferPointer { ground.writeWeights(xs: 0...2, zs: 0...2, into: $0.baseAddress!) }
        #expect(out[0] == 255 && out[2 * 8 + 1] == 255)
        // Without textures, nothing changes: no layers, no weights.
        let (plain, plainFolder) = try Self.texturedPackage(textured: false)
        defer { try? FileManager.default.removeItem(at: plainFolder) }
        let untextured = try #require(try plain.groundSource())
        #expect(!untextured.isTextured && untextured.paintedLayers.isEmpty && untextured.weights.isEmpty)
    }

    @Test("A textured ground is drawn from its texture, not its painted colours")
    func draws() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        func frame(textured: Bool) throws -> [UInt8] {
            let (package, folder) = try Self.texturedPackage(textured: textured)
            defer { try? FileManager.default.removeItem(at: folder) }
            let engine = try FrameRenderer(device: device)
            let world = try WorldRenderer(engine: engine, textureCache: nil)
            engine.game = world
            world.loadsGroundTexturesAtOnce = true
            world.scheduleTime = 1_794_000_000
            try world.show(package) { _ in }
            world.camera = WorldRenderer.View(eye: SIMD3(-0.5, 3, 0.01), target: SIMD3(-0.5, 0, 0))
            let png = try #require(world.pngFrame(width: 48, height: 48))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var bytes = [UInt8](repeating: 0, count: 48 * 48 * 4)
            let context = try #require(CGContext(data: &bytes, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 48))
            return bytes
        }
        let painted = try frame(textured: false), textured = try frame(textured: true)
        // Painted: green and even. Textured: the red and blue squares of the grass's map, looking down on its half.
        func spread(_ b: [UInt8]) -> (red: Int, blue: Int, green: Int) {
            var r = 0, g = 0, bl = 0
            for i in stride(from: 0, to: b.count, by: 4) {
                if b[i] > b[i + 1] + 30 && b[i] > b[i + 2] + 30 { r += 1 }
                if b[i + 2] > b[i] + 30 && b[i + 2] > b[i + 1] + 30 { bl += 1 }
                if b[i + 1] > b[i] + 15 && b[i + 1] > b[i + 2] + 15 { g += 1 }
            }
            return (r, bl, g)
        }
        let p = spread(painted), t = spread(textured)
        #expect(p.red == 0 && p.blue == 0 && p.green > 500, "painted: \(p)")
        #expect(t.red > 200 && t.blue > 200, "textured: \(t)")
    }
}

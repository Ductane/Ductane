//
//  WorldGroundLayers.swift
//  Ductane
//

import CoreGraphics
import DuctaneCulling
import Foundation
import ImageIO
import Metal
import simd

/// **One painted layer of a world's ground, as a ``WorldRenderer`` draws it**: a colour, and — when it has one — a
/// texture set that repeats across the ground every ``WorldGroundTexture/tileSize`` metres.
///
/// The layer model is the one Unity's Terrain Layers and Unreal's landscape layers use: each layer a colour map with an
/// optional normal, roughness, ambient occlusion and height map, tiled in metres, blended by the painted weights — and, where
/// both layers have height maps, by height, so stones show through sand rather than fading into it.
public nonisolated struct WorldGroundLayer: Equatable, Sendable {
    /// Linear. What the layer is drawn with when it has no texture, and what the ground is mixed to for anything that
    /// cannot draw textures.
    public var colour: SIMD3<Float>
    public var texture: WorldGroundTexture?

    public init(colour: SIMD3<Float>, texture: WorldGroundTexture? = nil) {
        self.colour = colour
        self.texture = texture
    }
}

/// **A ground layer's texture set**: the files of a PBR material made for ground — grass, mud, gravel — and how large
/// one repeat of it is.
public nonisolated struct WorldGroundTexture: Hashable, Sendable {
    /// The colour (albedo, base colour, diffuse) map. Required.
    public var colour: URL
    /// The normal map; ``normalIsDirectX`` when its green channel points down the image (DirectX's convention) rather than
    /// up (OpenGL's).
    public var normal: URL?
    public var normalIsDirectX: Bool
    public var roughness: URL?
    /// Ambient occlusion.
    public var occlusion: URL?
    /// Ambient occlusion, roughness and metalness packed in red, green and blue — one file instead of two.
    public var packed: URL?
    /// Height (displacement), for blending by height.
    public var height: URL?
    /// Metres of ground one repeat covers.
    public var tileSize: Float

    public init(colour: URL, normal: URL? = nil, normalIsDirectX: Bool = false, roughness: URL? = nil,
                occlusion: URL? = nil, packed: URL? = nil, height: URL? = nil, tileSize: Float = Self.defaultTileSize) {
        self.colour = colour
        self.normal = normal
        self.normalIsDirectX = normalIsDirectX
        self.roughness = roughness
        self.occlusion = occlusion
        self.packed = packed
        self.height = height
        self.tileSize = Self.tileSizes.clamp(tileSize)
    }

    /// From a decimetre — a pebble's detail — to fifty metres, a field's.
    public static let tileSizes: ClosedRange<Float> = 0.1...50
    public static let defaultTileSize: Float = 2

    /// Every file it reads.
    public var files: [URL] { [colour] + [normal, roughness, occlusion, packed, height].compactMap { $0 } }

    /// The same files and maps, whatever the tile size — what a set of loaded textures is keyed by.
    var maps: WorldGroundTexture {
        var maps = self
        maps.tileSize = Self.defaultTileSize
        return maps
    }
}

private nonisolated extension ClosedRange where Bound == Float {
    func clamp(_ value: Float) -> Float { value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : Float(1) }
}

/// **A ground's layer textures on the GPU**: two texture arrays, one slice a textured layer.
///
/// - ``albedo``: sRGB colour, alpha the height (0.5 where a set has no height map).
/// - ``surface``: the normal's x and y (DirectX's way up: green toward +z), roughness, ambient occlusion.
///
/// Every slice is the same size — ``size(for:)`` of the graphics settings — so a set of mixed sizes still makes one array,
/// and a 4K texture costs no more than a 1K one at the same quality. Made off the main thread: decoding a few 2K images is
/// a fraction of a second, and an editor choosing a texture must not stall its window.
public nonisolated final class WorldGroundTextures: @unchecked Sendable {
    public let albedo: MTLTexture
    public let surface: MTLTexture
    /// The slice each texture set is in, by its maps.
    let slices: [WorldGroundTexture: Int]
    public let size: Int

    /// The slice a layer's texture is drawn from, or nil.
    func slice(of texture: WorldGroundTexture?) -> Int? { texture.flatMap { slices[$0.maps] } }

    /// Every allocation, for a residency set.
    public var allocations: [MTLAllocation] { [albedo, surface] }

    /// One slice's side, in texels: 2048 at full texture quality, halved at each step down — never under 256.
    public static func size(for quality: GraphicsSettings.TextureQuality) -> Int { max(2048 >> quality.reduction, 256) }

    /// Loads `textures` — each texture set once, however many layers use it — into slices of `size` texels.
    /// - Throws: ``WorldGroundTexturesError`` when a colour map cannot be read or the GPU will not make the arrays.
    public static func make(device: MTLDevice, textures: [WorldGroundTexture], size: Int) throws -> WorldGroundTextures {
        var sets: [WorldGroundTexture] = []
        for texture in textures where !sets.contains(texture.maps) { sets.append(texture.maps) }
        guard !sets.isEmpty else { throw WorldGroundTexturesError.noTextures }
        let side = max(size, 4)
        let sliceBytes = side * side * 4
        guard let staging = device.makeBuffer(length: sliceBytes * sets.count * 2, options: .storageModeShared) else {
            throw WorldGroundTexturesError.couldNotCreate
        }
        let bytes = staging.contents().bindMemory(to: UInt8.self, capacity: sliceBytes * sets.count * 2)
        for (index, set) in sets.enumerated() {
            try Self.pack(set, side: side, albedo: bytes + index * sliceBytes,
                          surface: bytes + (sets.count + index) * sliceBytes)
        }
        func array(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = side
            d.height = side
            d.arrayLength = sets.count
            d.mipmapLevelCount = Int(log2(Double(side))) + 1
            d.usage = .shaderRead
            d.storageMode = .private
            let texture = device.makeTexture(descriptor: d)
            texture?.label = label
            return texture
        }
        guard let albedo = array(.rgba8Unorm_srgb, "Ground Layers, Colour and Height"),
              let surface = array(.rgba8Unorm, "Ground Layers, Normal, Roughness and Occlusion"),
              let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw WorldGroundTexturesError.couldNotCreate }
        for index in sets.indices {
            for (texture, offset) in [(albedo, index * sliceBytes), (surface, (sets.count + index) * sliceBytes)] {
                blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: side * 4, sourceBytesPerImage: sliceBytes,
                          sourceSize: MTLSize(width: side, height: side, depth: 1), to: texture, destinationSlice: index,
                          destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
        }
        blit.generateMipmaps(for: albedo)
        blit.generateMipmaps(for: surface)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return WorldGroundTextures(albedo: albedo, surface: surface,
                                   slices: Dictionary(uniqueKeysWithValues: sets.enumerated().map { ($1, $0) }), size: side)
    }

    private init(albedo: MTLTexture, surface: MTLTexture, slices: [WorldGroundTexture: Int], size: Int) {
        self.albedo = albedo
        self.surface = surface
        self.slices = slices
        self.size = size
    }

    // MARK: Packing

    /// Writes one texture set's two slices: colour and height into `albedo`, normal, roughness and occlusion into
    /// `surface`, each `side`² RGBA bytes. Public for tests through ``packed(_:side:)``.
    static func pack(_ set: WorldGroundTexture, side: Int, albedo: UnsafeMutablePointer<UInt8>,
                     surface: UnsafeMutablePointer<UInt8>) throws {
        guard let colour = Self.pixels(set.colour, side: side, colour: true) else {
            throw WorldGroundTexturesError.unreadable(set.colour)
        }
        let height = set.height.flatMap { Self.pixels($0, side: side, colour: false) }
        let normal = set.normal.flatMap { Self.pixels($0, side: side, colour: false) }
        let roughness = set.roughness.flatMap { Self.pixels($0, side: side, colour: false) }
        let occlusion = set.occlusion.flatMap { Self.pixels($0, side: side, colour: false) }
        let packed = set.packed.flatMap { Self.pixels($0, side: side, colour: false) }
        // Kept alive, and their bytes handed to the optimised packer (`WorldGroundPacking`).
        func map(_ image: Image?) -> WorldGroundPacking.Map? {
            image.map { WorldGroundPacking.Map(bytes: $0.bytes.baseAddress!, channels: $0.channels) }
        }
        withExtendedLifetime([colour, height, normal, roughness, occlusion, packed]) {
            WorldGroundPacking.pack(texels: side * side, colour: map(colour)!, height: map(height), normal: map(normal),
                                    normalIsDirectX: set.normalIsDirectX, roughness: map(roughness),
                                    occlusion: map(occlusion), packed: map(packed), defaultRoughness: Self.defaultRoughness,
                                    albedo: albedo, surface: surface)
        }
    }

    /// Ground is rough: a soil or grass with no roughness map is drawn at 0.9.
    static let defaultRoughness: UInt8 = 230

    /// The two slices' bytes for one set, as ``make(device:textures:size:)`` uploads them — for tests.
    static func packed(_ set: WorldGroundTexture, side: Int) throws -> (albedo: [UInt8], surface: [UInt8]) {
        var albedo = [UInt8](repeating: 0, count: side * side * 4), surface = albedo
        try albedo.withUnsafeMutableBufferPointer { a in
            try surface.withUnsafeMutableBufferPointer { s in
                try pack(set, side: side, albedo: a.baseAddress!, surface: s.baseAddress!)
            }
        }
        return (albedo, surface)
    }

    /// An image's bytes, `channels` a texel, held in memory that does not move while the packer reads it.
    final class Image {
        let bytes: UnsafeMutableBufferPointer<UInt8>
        let channels: Int
        init(count: Int, channels: Int) {
            bytes = .allocate(capacity: count)
            bytes.initialize(repeating: 255)
            self.channels = channels
        }
        deinit { bytes.deallocate() }
        subscript(texel: Int, channel: Int) -> UInt8 { bytes[texel * channels + min(channel, channels - 1)] }
    }

    /// An image read and resized to `side`², rows top first: RGBA, or one channel for a grey data map. A colour map is put
    /// in sRGB, as it is drawn; a data map — normal, roughness, height — is read in its own colour space, never converted,
    /// since its numbers are not colours.
    static func pixels(_ url: URL, side: Int, colour: Bool) -> Image? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let gray = image.colorSpace?.model == .monochrome
        let space: CGColorSpace?
        if colour {
            space = CGColorSpace(name: CGColorSpace.sRGB)
        } else if gray {
            space = image.colorSpace ?? CGColorSpaceCreateDeviceGray()
        } else {
            space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let space else { return nil }
        let channels = gray && !colour ? 1 : 4
        let out = Image(count: side * side * channels, channels: channels)
        guard let context = CGContext(data: out.bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * channels, space: space,
                                      bitmapInfo: channels == 1 ? CGImageAlphaInfo.none.rawValue
                                                                : CGImageAlphaInfo.noneSkipLast.rawValue
                                                                  | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return out
    }

    /// **A colour map's average colour, linear** — what a textured layer is drawn as where textures are not: another USD
    /// tool's view of the scene, the colours a world file carries, a game that draws no textures. Nil when it cannot be read.
    public static func averageColour(of url: URL) -> SIMD3<Float>? {
        guard let pixels = pixels(url, side: 32, colour: true) else { return nil }
        var sum = SIMD3<Float>.zero
        for i in 0..<(32 * 32) {
            sum += SIMD3(WorldGround.linear(pixels[i, 0]), WorldGround.linear(pixels[i, 1]), WorldGround.linear(pixels[i, 2]))
        }
        return sum / Float(32 * 32)
    }
}

public nonisolated enum WorldGroundTexturesError: Error, Equatable, CustomStringConvertible {
    case noTextures
    case unreadable(URL)
    case couldNotCreate
    public var description: String {
        switch self {
        case .noTextures: "no layer has a texture"
        case .unreadable(let url): "\(url.lastPathComponent) could not be read as an image"
        case .couldNotCreate: "the GPU would not make the ground's layer textures"
        }
    }
}

// MARK: - The weights a renderer reads

/// **The painted weights a ``WorldRenderer`` blends textured layers by**: eight bytes a point, each layer's share of 255,
/// in the layers' order — as ``WorldFile/Ground/weights`` keeps them.
public nonisolated enum WorldGroundWeights {
    public static let bytesPerPoint = 8

    /// Writes points `xs` × `zs` of weights given as fractions summing to one, as shares of 255 that sum to 255.
    public static func write(_ weights: [SIMD8<Float>], resolution: Int, xs: ClosedRange<Int>, zs: ClosedRange<Int>,
                             into out: UnsafeMutablePointer<UInt8>) {
        let n = resolution + 1
        weights.withUnsafeBufferPointer { w in
            for z in zs {
                for x in xs {
                    let i = z * n + x
                    let o = out + i * bytesPerPoint
                    guard i < w.count else { o[0] = 255; for k in 1..<8 { o[k] = 0 }; continue }
                    let scaled = simd_clamp(w[i], SIMD8(repeating: 0), SIMD8(repeating: 1)) * 255
                    for k in 0..<8 { o[k] = UInt8(scaled[k].rounded()) }
                }
            }
        }
    }

    /// The same, from weights already in shares of 255.
    public static func write(_ weights: [SIMD8<UInt8>], resolution: Int, xs: ClosedRange<Int>, zs: ClosedRange<Int>,
                             into out: UnsafeMutablePointer<UInt8>) {
        let n = resolution + 1
        weights.withUnsafeBufferPointer { w in
            for z in zs {
                for x in xs {
                    let i = z * n + x
                    let o = out + i * bytesPerPoint
                    let point = i < w.count ? w[i] : SIMD8(255, 0, 0, 0, 0, 0, 0, 0)
                    for k in 0..<8 { o[k] = point[k] }
                }
            }
        }
    }
}

//
//  WorldGroundSource.swift
//  Ductane
//

import Foundation
import simd

/// **The ground a ``WorldRenderer`` draws**: a square grid centred on the origin, `resolution` cells a side, `size` metres
/// across, written into the renderer's vertices a patch at a time — so an editor's brush stroke writes only the patch it
/// touched, sixty times a second, and the renderer never keeps the ground itself (keeping it would make every edit copy it).
///
/// A game's ground is its scene package's (``WorldPackageGround``); an editor's is its own ground, made one of these.
public nonisolated protocol WorldGroundSource {
    /// **Which ground this is**: the same for a ground and every edit of it, another for another ground.
    var lineage: UUID { get }
    /// How often it has changed — with ``lineage``, how a renderer tells the ground it last drew from this one without
    /// comparing a million heights.
    var revision: Int { get }
    var size: Float { get }
    /// Cells a side; `resolution + 1` points.
    var resolution: Int { get }
    /// `(resolution + 1)²` heights, rows along +X, row after row along +Z.
    var heights: [Float] { get }
    /// One a cell, `resolution²`, true where the ground is cut away — a cave's mouth; empty when it has none.
    var holes: [Bool] { get }
    /// **Writes points `xs` × `zs` as the renderer draws them** — twelve floats a point (``WorldGroundVertices``): position,
    /// normal, uv (a metre a unit), colour, and how soft the ground is there (where footprints show) — at `out + point × 12`.
    func writeVertices(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>)
    /// **Writes where puddles gather** at points `xs` × `zs` (``WorldPuddleField``): 0 never … 1 the first to fill, one
    /// float a point at `out + point`.
    func writePuddles(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>)
    /// **How far round a changed point its puddles change**, metres: ``WorldPuddleField/reach`` for puddles worked out from
    /// the heights, 0 for ones read from a file.
    var puddleReach: Float { get }
    /// **The painted layers, as drawn** — each a colour and perhaps a texture set (``WorldGroundLayer``), in the order of
    /// the weights ``writeWeights(xs:zs:into:)`` writes. While none has a texture the ground is drawn in its vertices'
    /// colours, as it always was; empty for a ground with no layers to speak of.
    var paintedLayers: [WorldGroundLayer] { get }
    /// **Writes how much of each layer is at points `xs` × `zs`**: eight bytes a point, each layer's share of 255
    /// (``WorldGroundWeights``), at `out + point × 8`. Read only while a layer has a texture.
    func writeWeights(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<UInt8>)
}

public nonisolated extension WorldGroundSource {
    var pointsPerSide: Int { resolution + 1 }
    var spacing: Float { size / Float(resolution) }
    /// The whole grid.
    var allPoints: WorldGroundRegion { WorldGroundRegion(x: 0...resolution, z: 0...resolution) }
    /// Whether cell (x, z) is cut away.
    func isHole(_ x: Int, _ z: Int) -> Bool {
        let holes = self.holes
        return !holes.isEmpty && holes[z * resolution + x]
    }
    var hasHoles: Bool { !holes.isEmpty }
    /// Whether any layer is drawn with a texture.
    var isTextured: Bool { paintedLayers.contains { $0.texture != nil } }

    var paintedLayers: [WorldGroundLayer] { [] }
    func writeWeights(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<UInt8>) {}
}

/// **A patch of a ground's grid points**: what an edit changed, and so what has to be written again.
public nonisolated struct WorldGroundRegion: Sendable, Equatable {
    public var x: ClosedRange<Int>
    public var z: ClosedRange<Int>

    public init(x: ClosedRange<Int>, z: ClosedRange<Int>) {
        self.x = x
        self.z = z
    }

    public func union(_ other: WorldGroundRegion) -> WorldGroundRegion {
        WorldGroundRegion(x: min(x.lowerBound, other.x.lowerBound)...max(x.upperBound, other.x.upperBound),
                          z: min(z.lowerBound, other.z.lowerBound)...max(z.upperBound, other.z.upperBound))
    }

    /// Grown by `points` on every side, kept within a grid of `resolution` cells — a changed height moves its neighbours'
    /// normals, so what must be redrawn is one point wider than what changed.
    public func expanded(by points: Int, within resolution: Int) -> WorldGroundRegion {
        WorldGroundRegion(x: max(x.lowerBound - points, 0)...min(x.upperBound + points, resolution),
                          z: max(z.lowerBound - points, 0)...min(z.upperBound + points, resolution))
    }
}

/// **A scene package's ground, as a ``WorldRenderer`` draws it**: the heights, painted colours and holes of
/// ``WorldPackage/ground()``, how soft each point is from its painted layers, and where puddles gather as the editor worked
/// it out.
public nonisolated struct WorldPackageGround: WorldGroundSource, Sendable {
    public let ground: WorldGround
    /// 0…1 a point: where footprints show beside snow.
    public let softness: [Float]
    /// 0…1 a point, or empty: where puddles gather (``WorldFile/Ground/puddles``).
    public let puddles: [Float]
    /// Each layer's share of each point, out of 255 (``WorldFile/Ground/weights``), or empty.
    public let weights: [SIMD8<UInt8>]
    /// The painted layers, with their textures (``WorldFile/Ground/textures``); empty when none has one.
    public let paintedLayers: [WorldGroundLayer]
    public let lineage = UUID()
    public var revision: Int { 0 }
    public var size: Float { ground.size }
    public var resolution: Int { ground.resolution }
    public var heights: [Float] { ground.heights }
    public var holes: [Bool] { ground.holes }
    public var puddleReach: Float { 0 }

    public init(ground: WorldGround, softness: [Float] = [], puddles: [Float] = [], weights: [SIMD8<UInt8>] = [],
                layers: [WorldGroundLayer] = []) {
        self.ground = ground
        self.softness = softness
        self.puddles = puddles
        self.weights = weights
        self.paintedLayers = layers
    }

    public func writeWeights(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<UInt8>) {
        WorldGroundWeights.write(weights, resolution: ground.resolution, xs: xs, zs: zs, into: out)
    }

    public func writeVertices(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>) {
        WorldGroundVertices.write(heights: ground.heights, colours: ground.colours, softness: softness,
                                  resolution: ground.resolution, size: ground.size, xs: xs, zs: zs, into: out)
    }

    public func writePuddles(xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>) {
        let n = ground.resolution + 1
        for z in zs {
            for x in xs {
                let i = z * n + x
                out[i] = i < puddles.count ? puddles[i] : 0
            }
        }
    }
}

public nonisolated extension WorldPackage {
    /// **The package's ground as a ``WorldRenderer`` draws it** — heights, colours and holes, how soft each point is, where
    /// puddles gather. Nil when the world has none.
    func groundSource() throws -> WorldPackageGround? {
        guard let ground = try ground(), let description = world.ground else { return nil }
        let points = ground.pointsPerSide * ground.pointsPerSide
        let weights = try groundWeights()
        let softness = weights.map { WorldFile.Ground.softness($0, softLayers: description.softLayers ?? []) } ?? []
        var puddles: [Float] = []
        if let path = description.puddles {
            let data = try Data(contentsOf: url(of: path))
            if data.count == points * 4 {
                puddles = data.withUnsafeBytes { raw in
                    (0..<points).map {
                        Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                    }
                }
            }
        }
        // **Textured layers** (``WorldFile/Ground/textures``), drawn only with the weights to blend them by.
        var layers: [WorldGroundLayer] = []
        if weights != nil, let textures = description.textures, textures.contains(where: { $0 != nil }) {
            let colours = description.layerColours ?? []
            layers = (0..<min(description.layers.count, WorldFile.Ground.layerCount)).map { index in
                let texture = index < textures.count ? textures[index] : nil
                let colour = index < colours.count && colours[index].count == 3
                    ? SIMD3(colours[index][0], colours[index][1], colours[index][2]) : SIMD3<Float>(repeating: 0.3)
                return WorldGroundLayer(colour: colour, texture: texture.map(groundTexture))
            }
        }
        return WorldPackageGround(ground: ground, softness: softness, puddles: puddles,
                                  weights: layers.isEmpty ? [] : (weights ?? []), layers: layers)
    }

    /// A layer's texture set, its files found in the package.
    private func groundTexture(_ texture: WorldFile.Ground.Texture) -> WorldGroundTexture {
        WorldGroundTexture(colour: url(of: texture.map), normal: texture.normal.map(url(of:)),
                           normalIsDirectX: texture.normalIsDirectX ?? false, roughness: texture.roughness.map(url(of:)),
                           occlusion: texture.occlusion.map(url(of:)), packed: texture.packed.map(url(of:)),
                           height: texture.height.map(url(of:)), tileSize: texture.tileSize)
    }
}

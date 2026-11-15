//
//  WorldGround.swift
//  Ductane
//

import Foundation
import simd

/// **A world's ground**, read from the files ``WorldFile/Ground`` names: heights to stand on and a mesh to draw, both
/// from the same grid, so what the player stands on is what they see.
public nonisolated struct WorldGround: Sendable, Equatable {
    public let size: Float
    public let resolution: Int
    /// `(resolution + 1)²` heights, rows along +X.
    public let heights: [Float]
    /// One linear colour a point.
    public let colours: [SIMD3<Float>]
    /// One a cell, `resolution²`, true where the ground is cut away; empty when it has no holes.
    public let holes: [Bool]

    /// How far down "no ground" is: under a hole a walker falls through to whatever is below — a cave's floor — and
    /// stands on that. A number rather than nothing, because a body asks for a height.
    public static let underHole: Float = -10_000

    public var pointsPerSide: Int { resolution + 1 }
    public var spacing: Float { size / Float(resolution) }
    /// The corner with the smallest x and z.
    public var origin: SIMD2<Float> { SIMD2(-size / 2, -size / 2) }

    public init(size: Float, resolution: Int, heights: [Float], colours: [SIMD3<Float>], holes: [Bool] = []) {
        self.size = size
        self.resolution = resolution
        self.heights = heights
        self.colours = colours
        self.holes = holes
    }

    /// Reads the files a world's ground is.
    public init(_ description: WorldFile.Ground, heights heightData: Data, colours colourData: Data,
                holes holeData: Data? = nil) throws {
        let points = (description.resolution + 1) * (description.resolution + 1)
        guard description.resolution > 0, heightData.count == points * 4, colourData.count == points * 3 else {
            throw WorldGroundError.wrongSize(expected: points, heights: heightData.count / 4, colours: colourData.count / 3)
        }
        let heights = heightData.withUnsafeBytes { raw in
            (0..<points).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        let colours = colourData.withUnsafeBytes { raw in
            (0..<points).map { i in
                SIMD3(Self.linear(raw[i * 3]), Self.linear(raw[i * 3 + 1]), Self.linear(raw[i * 3 + 2]))
            }
        }
        let cells = description.resolution * description.resolution
        if let holeData, holeData.count != cells { throw WorldGroundError.wrongHoles(expected: cells, found: holeData.count) }
        self.init(size: description.size, resolution: description.resolution, heights: heights, colours: colours,
                  holes: holeData.map { $0.map { $0 != 0 } } ?? [])
    }

    /// Whether cell (x, z) is cut away.
    public func isHole(_ x: Int, _ z: Int) -> Bool { !holes.isEmpty && holes[z * resolution + x] }

    /// The height under (x, z), between points by bilinear interpolation; the nearest edge's off
    /// the grid, so a walker who goes off the edge of the world walks on rather than falling forever; ``underHole`` over a
    /// hole.
    public func height(x: Float, z: Float) -> Float {
        let gx = min(max((x - origin.x) / spacing, 0), Float(resolution))
        let gz = min(max((z - origin.y) / spacing, 0), Float(resolution))
        let x0 = min(Int(gx), resolution - 1), z0 = min(Int(gz), resolution - 1)
        if isHole(x0, z0) { return Self.underHole }
        let fx = gx - Float(x0), fz = gz - Float(z0)
        let n = pointsPerSide
        let h00 = heights[z0 * n + x0], h10 = heights[z0 * n + x0 + 1]
        let h01 = heights[(z0 + 1) * n + x0], h11 = heights[(z0 + 1) * n + x0 + 1]
        return (h00 * (1 - fx) + h10 * fx) * (1 - fz) + (h01 * (1 - fx) + h11 * fx) * fz
    }

    /// Whether (x, z) is over the grid at all.
    public func contains(x: Float, z: Float) -> Bool {
        x >= origin.x && x <= origin.x + size && z >= origin.y && z <= origin.y + size
    }

    /// The height under (x, z) **as if every hole were filled**, between points by bilinear interpolation, the nearest
    /// edge's off the grid — for a game that keeps its holes apart from its heights.
    public func heightIgnoringHoles(x: Float, z: Float) -> Float {
        let gx = min(max((x - origin.x) / spacing, 0), Float(resolution))
        let gz = min(max((z - origin.y) / spacing, 0), Float(resolution))
        let x0 = min(Int(gx), resolution - 1), z0 = min(Int(gz), resolution - 1)
        let fx = gx - Float(x0), fz = gz - Float(z0)
        let n = pointsPerSide
        let h00 = heights[z0 * n + x0], h10 = heights[z0 * n + x0 + 1]
        let h01 = heights[(z0 + 1) * n + x0], h11 = heights[(z0 + 1) * n + x0 + 1]
        return (h00 * (1 - fx) + h10 * fx) * (1 - fz) + (h01 * (1 - fx) + h11 * fx) * fz
    }

    /// The point (x, z) of the grid in the world.
    public func point(_ x: Int, _ z: Int) -> SIMD3<Float> {
        SIMD3(origin.x + Float(x) * spacing, heights[z * pointsPerSide + x], origin.y + Float(z) * spacing)
    }

    /// The surface's normal at point (x, z), from its neighbours.
    public func normal(_ x: Int, _ z: Int) -> SIMD3<Float> {
        let n = pointsPerSide
        let left = heights[z * n + max(x - 1, 0)], right = heights[z * n + min(x + 1, resolution)]
        let back = heights[max(z - 1, 0) * n + x], front = heights[min(z + 1, resolution) * n + x]
        let dx = Float(min(x + 1, resolution) - max(x - 1, 0)) * spacing
        let dz = Float(min(z + 1, resolution) - max(z - 1, 0)) * spacing
        return simd_normalize(SIMD3(-(right - left) / dx, 1, -(front - back) / dz))
    }

    /// **The mesh to draw**: one vertex a point — position, normal, uv (a metre a unit), colour, twelve floats packed as
    /// the GPU reads them (``floatsPerVertex``) — and two triangles a cell, wound counter-clockwise seen from above, as
    /// the props are.
    public func mesh() -> (vertices: [Float], indices: [UInt32]) {
        let n = pointsPerSide
        var vertices: [Float] = []
        vertices.reserveCapacity(n * n * Self.floatsPerVertex)
        for z in 0..<n {
            for x in 0..<n {
                let p = point(x, z), normal = normal(x, z), colour = colours[z * n + x]
                vertices += [p.x, p.y, p.z, normal.x, normal.y, normal.z, p.x, p.z, colour.x, colour.y, colour.z, 1]
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(resolution * resolution * 6)
        for z in 0..<resolution {
            for x in 0..<resolution where !isHole(x, z) {
                let a = UInt32(z * n + x), b = a + 1, c = a + UInt32(n), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return (vertices, indices)
    }

    /// The ground's vertex: the props' position, normal and uv, then its colour — 48 bytes, packed.
    public static let floatsPerVertex = 12

    public static func linear(_ byte: UInt8) -> Float {
        let c = Float(byte) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    public static func srgbByte(_ linear: Float) -> UInt8 {
        let c = min(max(linear, 0), 1)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8((s * 255).rounded())
    }
}

public nonisolated enum WorldGroundError: Error, Equatable, CustomStringConvertible {
    case wrongSize(expected: Int, heights: Int, colours: Int)
    case wrongHoles(expected: Int, found: Int)
    public var description: String {
        switch self {
        case let .wrongHoles(expected, found): "the ground's holes file holds \(found) cells; its grid has \(expected)"
        case let .wrongSize(expected, heights, colours):
            "the ground's files hold \(heights) heights and \(colours) colours; its grid has \(expected) points"
        }
    }
}

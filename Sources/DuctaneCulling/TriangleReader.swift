//
//  TriangleReader.swift
//  Ductane
//

import simd

/// **A mesh's triangles read out of its buffers**, for what a walker meets (`WorldRenderer.collisionTriangles(of:)`) — here, in a
/// module optimised in every configuration, because a Debug build reading every index of hundreds of props one closure call
/// at a time held the window for seconds when a walk began on a large map.
public enum TriangleReader {
    /// Appends to `out` the positions `count` indices name — 32-bit if `wide`, else 16 — each at `stride` bytes into
    /// `vertices`, a position first, moved by `node`.
    public static func append(vertices: UnsafeRawPointer, stride: Int, indices: UnsafeRawPointer, count: Int, wide: Bool,
                              node: simd_float4x4, to out: inout [SIMD3<Float>]) {
        out.reserveCapacity(out.count + count)
        for i in 0..<count {
            let vertex = wide ? Int(indices.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                              : Int(indices.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            let p = vertices.loadUnaligned(fromByteOffset: vertex * stride, as: SIMD3<Float>.self)
            let placed = node * SIMD4(p, 1)
            out.append(SIMD3(placed.x, placed.y, placed.z))
        }
    }
}

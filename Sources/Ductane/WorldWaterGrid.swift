//
//  WorldWaterGrid.swift
//  Ductane
//

import simd

/// **Whether a point is under a scene's water, without asking every rectangle** (2026-11-01). A body of water's surface
/// is rectangles at its level (``WorldFile/Water/rectangles``) — a marsh can be 1,261 of them — and the see-through sort asked
/// each of them about each see-through copy in view, every frame: 10.7 ms of a Debug frame for 74 copies of goop. Here
/// each rectangle is filed in the square cells it overlaps, so a point asks only the few in its own cell.
public nonisolated struct WorldWaterGrid: Sendable {

    /// Each rectangle as its level and `(x0, z0, x1, z1)`.
    public let rectangles: [(level: Float, rectangle: SIMD4<Float>)]
    /// The highest level of any — nothing at or above it is under water, which most things are.
    public let top: Float
    private let cell: Float
    private var cells: [SIMD2<Int32>: [Int32]] = [:]

    public init(_ rectangles: [(level: Float, rectangle: SIMD4<Float>)], cell: Float = 16) {
        self.rectangles = rectangles
        self.cell = max(cell, 0.01)
        top = rectangles.map(\.level).max() ?? -.infinity
        for (index, r) in rectangles.enumerated() {
            let lo = key(r.rectangle.x, r.rectangle.y), hi = key(r.rectangle.z, r.rectangle.w)
            for x in lo.x...max(lo.x, hi.x) {
                for z in lo.y...max(lo.y, hi.y) { cells[SIMD2(x, z), default: []].append(Int32(index)) }
            }
        }
    }

    private func key(_ x: Float, _ z: Float) -> SIMD2<Int32> {
        SIMD2(Int32((x / cell).rounded(.down)), Int32((z / cell).rounded(.down)))
    }

    /// Whether `point` is below the level of a rectangle it stands over.
    public func covers(_ point: SIMD3<Float>) -> Bool {
        guard point.y < top, let candidates = cells[key(point.x, point.z)] else { return false }
        for index in candidates {
            let (level, r) = rectangles[Int(index)]
            if point.y < level && point.x >= r.x && point.x <= r.z && point.z >= r.y && point.z <= r.w { return true }
        }
        return false
    }
}

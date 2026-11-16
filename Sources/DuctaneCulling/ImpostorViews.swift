//
//  ImpostorViews.swift
//  Ductane
//

import simd

/// **Where a prop's far picture is seen from** (2026-11-01): the directions its impostor is drawn from, over the upper
/// half of a sphere round it, laid out on a hemi-octahedral grid — and, for a direction an eye looks from, the four of
/// them to blend.
///
/// A far copy is drawn as one square facing the eye, painted from these pictures (`impostorFragment` in
/// `WorldShaders.metal`), instead of thousands of triangles a few pixels across: a 400 m wooded zone seen whole drew 1.8
/// million triangles of trees and bushes, every one at its pack's coarsest level. The same layout is used by the bake and the
/// draw, so it lives here once, with its tests.
public enum ImpostorViews {
    /// Views a side: `side × side` in all.
    public static let side = 8
    public static var count: Int { side * side }

    /// One view: the direction it looks from (toward the eye, from the prop's centre), and its picture's right and up.
    public struct View: Sendable, Equatable {
        public var direction: SIMD3<Float>
        public var right: SIMD3<Float>
        public var up: SIMD3<Float>
    }

    /// A direction in the upper hemisphere (`y ≥ 0`) as a point of the unit square.
    public static func encode(_ direction: SIMD3<Float>) -> SIMD2<Float> {
        let d = direction / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 1e-6)
        return SIMD2(d.x + d.z, d.x - d.z) * 0.5 + 0.5
    }

    /// The direction a point of the unit square stands for — ``encode(_:)`` undone.
    public static func decode(_ point: SIMD2<Float>) -> SIMD3<Float> {
        let p = point * 2 - 1
        let x = (p.x + p.y) / 2, z = (p.x - p.y) / 2
        return simd_normalize(SIMD3(x, max(1 - abs(x) - abs(z), 0), z))
    }

    /// Every view, row by row: view `row * side + column` looks from the centre of that cell of the square.
    public static let views: [View] = (0..<count).map { index in
        let cell = SIMD2(Float(index % side), Float(index / side))
        let direction = decode((cell + 0.5) / Float(side))
        let across = simd_cross(SIMD3<Float>(0, 1, 0), direction)
        let right = simd_length(across) > 1e-4 ? simd_normalize(across) : SIMD3<Float>(1, 0, 0)
        return View(direction: direction, right: right, up: simd_cross(direction, right))
    }

    /// **The four views to blend for an eye looking from `direction`**, and how much of each: the cells round the point
    /// of the square it falls on, bilinearly. A direction below the horizon is seen as from the horizon.
    public static func blend(for direction: SIMD3<Float>) -> (views: SIMD4<Int32>, weights: SIMD4<Float>) {
        var d = direction
        d.y = max(d.y, 0)
        if simd_length(d) < 1e-6 { d = SIMD3(0, 1, 0) }
        let g = encode(simd_normalize(d)) * Float(side) - 0.5
        let lower = simd_clamp(g.rounded(.down), SIMD2(repeating: 0), SIMD2(repeating: Float(side - 1)))
        let upper = simd_min(lower + 1, SIMD2(repeating: Float(side - 1)))
        let f = simd_clamp(g - lower, SIMD2(repeating: 0), SIMD2(repeating: 1))
        func index(_ x: Float, _ y: Float) -> Int32 { Int32(y) * Int32(side) + Int32(x) }
        return (SIMD4(index(lower.x, lower.y), index(upper.x, lower.y), index(lower.x, upper.y), index(upper.x, upper.y)),
                SIMD4((1 - f.x) * (1 - f.y), f.x * (1 - f.y), (1 - f.x) * f.y, f.x * f.y))
    }
}

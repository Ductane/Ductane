//
//  WorldGroundDetail.swift
//  Ductane
//

import simd

/// **The ground's coarser levels, a chunk at a time** (2026-11-01).
///
/// A 400 m zone seen whole drew its ground as 1.28 million triangles across about as many pixels, and shading
/// triangles a pixel across — four samples each, a quad of fragments for one — was a third of the frame. A chunk far
/// enough away is drawn from every second, fourth, eighth or sixteenth point instead, whichever strays from the full
/// ground by under half a pixel (``error(of:heights:floatsPerPoint:pointsPerRow:originX:originZ:)``). The colour,
/// normal and height a pixel shows still come from the full grid (`fineGround` in `WorldShaders.metal`), so only the
/// outline moves, by under half a pixel.
///
/// **A chunk's edge is never coarsened.** A coarse cell on it is a fan from its centre through every point along the
/// edge, so it meets the neighbouring chunk point for point at whatever level that one is drawn: no cracks, and nothing
/// to keep neighbours in step. Inside, a coarse cell is two triangles split as a full cell is.
///
/// Here, in the optimised module, because the errors are every point of every chunk at every level — 2.7 million
/// sums for a 400 m zone, worked out when it opens and again for the chunks a brush touches.
public enum WorldGroundDetail {
    /// The steps offered, finest first: a chunk at step `s` is drawn from every `s`th point.
    public static let steps = [2, 4, 8, 16]

    /// Whether a chunk `width` by `height` cells can be drawn at `step`.
    public static func fits(width: Int, height: Int, step: Int) -> Bool {
        width % step == 0 && height % step == 0 && width >= step && height >= step
    }

    /// **A chunk's triangles at a step**, as grid points from the chunk's corner, three a triangle, wound as a full
    /// cell's are: (x, z) → (x, z + 1) → (x + 1, z + 1).
    public static func triangles(width: Int, height: Int, step s: Int) -> [SIMD2<Int32>] {
        guard fits(width: width, height: height, step: s) else { return [] }
        var out: [SIMD2<Int32>] = []
        for z0 in stride(from: 0, to: height, by: s) {
            for x0 in stride(from: 0, to: width, by: s) {
                let a = SIMD2(Int32(x0), Int32(z0)), b = SIMD2(Int32(x0), Int32(z0 + s))
                let c = SIMD2(Int32(x0 + s), Int32(z0 + s)), d = SIMD2(Int32(x0 + s), Int32(z0))
                let left = x0 == 0, top = z0 + s == height, right = x0 + s == width, bottom = z0 == 0
                guard left || top || right || bottom else {
                    out += [a, b, c, a, c, d]
                    continue
                }
                // Round the cell in the winding's direction — up its left side, along its top, down its right, back along
                // its bottom — every point on a side that is the chunk's edge, only the corners on one that is not.
                var ring: [SIMD2<Int32>] = []
                func side(_ from: SIMD2<Int32>, _ to: SIMD2<Int32>, every: Bool) {
                    let stepCount = every ? s : 1
                    for k in 0..<stepCount { ring.append(from &+ (to &- from) &* Int32(k) / Int32(stepCount)) }
                }
                side(a, b, every: left)
                side(b, c, every: top)
                side(c, d, every: right)
                side(d, a, every: bottom)
                let centre = SIMD2(Int32(x0 + s / 2), Int32(z0 + s / 2))
                for k in ring.indices { out += [centre, ring[k], ring[(k + 1) % ring.count]] }
            }
        }
        return out
    }

    /// The triangles of ``triangles(width:height:step:)`` as indices into a grid `pointsPerRow` points wide, the chunk's
    /// corner at (`originX`, `originZ`).
    public static func indices(width: Int, height: Int, step: Int, pointsPerRow: Int, originX: Int, originZ: Int) -> [UInt32] {
        triangles(width: width, height: height, step: step).map {
            UInt32((originZ + Int($0.y)) * pointsPerRow + originX + Int($0.x))
        }
    }

    /// **How far a chunk drawn as `triangles` strays from the full ground**, in metres: the largest difference in height
    /// at any grid point under them. `heights` is the ground's vertices, a point's height its second float.
    public static func error(of triangles: [SIMD2<Int32>], heights: UnsafePointer<Float>, floatsPerPoint: Int,
                             pointsPerRow: Int, originX: Int, originZ: Int) -> Float {
        @inline(__always) func height(_ p: SIMD2<Int32>) -> Float {
            heights[((originZ + Int(p.y)) * pointsPerRow + originX + Int(p.x)) * floatsPerPoint + 1]
        }
        @inline(__always) func cross(_ u: SIMD2<Int32>, _ v: SIMD2<Int32>) -> Int32 { u.x * v.y - u.y * v.x }
        var worst: Float = 0
        var t = 0
        while t + 2 < triangles.count {
            let p0 = triangles[t], p1 = triangles[t + 1], p2 = triangles[t + 2]
            t += 3
            let area = cross(p1 &- p0, p2 &- p0)
            guard area != 0 else { continue }
            let h0 = height(p0), h1 = height(p1), h2 = height(p2)
            let lo = simd_min(p0, simd_min(p1, p2)), hi = simd_max(p0, simd_max(p1, p2))
            for z in lo.y...hi.y {
                for x in lo.x...hi.x {
                    let q = SIMD2(x, z)
                    // Barycentric weights, exact in integers; a point on an edge is inside both triangles, which is fine.
                    let w0 = cross(p2 &- p1, q &- p1), w1 = cross(p0 &- p2, q &- p2), w2 = cross(p1 &- p0, q &- p0)
                    let inside = area > 0 ? (w0 >= 0 && w1 >= 0 && w2 >= 0) : (w0 <= 0 && w1 <= 0 && w2 <= 0)
                    guard inside else { continue }
                    let drawn = (Float(w0) * h0 + Float(w1) * h1 + Float(w2) * h2) / Float(area)
                    worst = max(worst, abs(height(q) - drawn))
                }
            }
        }
        return worst
    }

    /// **The coarsest step to draw a chunk at**: the largest whose error, `distance` metres away, is under half a pixel
    /// — 1, the full ground, when none is. `errors` are per ``steps``, infinite where a step does not fit.
    public static func step(errors: [Float], distance: Float, pixelsPerRadian: Float) -> Int {
        var chosen = 1
        for (index, error) in errors.enumerated() where index < steps.count {
            if error * pixelsPerRadian / max(distance, 0.01) < 0.5 { chosen = steps[index] }
        }
        return chosen
    }
}

//
//  WorldPuddleField.swift
//  Ductane
//

import simd

/// **Where puddles gather, a point at a time** (2026-11-16): 0 never … 1 the first to fill. **A point holds water as deep
/// as the lowest rim round it**: in each of eight directions the highest ground within ``reach``; the lowest of those
/// eight less the point's own height is how deep water could stand there — a basin, not the foot of a slope, which water
/// leaves by its open side. A mean of the ground round it put a ring of puddle at the foot of every hill. A brushed
/// puddle adds, kept dry takes away. A shader fills the field to the weather's puddle level: the highest values first.
///
/// Here, in the optimised module, because a million points done one by one in a Debug build would be seconds.
public enum WorldPuddleField {
    /// How far round a point its hollow is judged, metres.
    public static let reach: Float = 1.5
    /// How deep water must be able to stand at a point for it to be a full puddle, metres.
    public static let fullDepth: Float = 0.06

    /// The field for points `xs` × `zs` of a grid `resolution` cells a side and `size` metres across, written into `out`
    /// (every point's value; only those asked for are worked out).
    public static func write(heights: [Float], paint: [Float], resolution: Int, size: Float,
                             xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>) {
        let n = resolution + 1
        let spacing = size / Float(resolution)
        let r = max(1, Int((reach / spacing).rounded()))
        let ways = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        heights.withUnsafeBufferPointer { h in
            for z in zs {
                for x in xs {
                    let i = z * n + x
                    let own = h[i]
                    var rim = Float.greatestFiniteMagnitude
                    for (dx, dz) in ways {
                        var highest = own
                        var k = 1
                        while k <= r {
                            let xx = x + dx * k, zz = z + dz * k
                            // Off the ground's edge, water runs away: no rim that way.
                            if xx < 0 || xx > resolution || zz < 0 || zz > resolution { highest = own; break }
                            highest = max(highest, h[zz * n + xx])
                            k += 1
                        }
                        rim = min(rim, highest)
                        if rim <= own { break }
                    }
                    let depth = max(rim - own, 0)
                    var value = min(depth / fullDepth, 1)
                    if i < paint.count { value += paint[i] }
                    out[i] = min(max(value, 0), 1)
                }
            }
        }
    }
}

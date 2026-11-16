//
//  WorldGroundVertices.swift
//  Ductane
//

import simd

/// **The ground's vertices for the GPU, a patch at a time** — position, normal, a metre of texture a metre of ground,
/// and the painted colour, its fourth how soft the ground is there (footprints, 2026-11-15): twelve floats a point
/// (2026-10-26).
///
/// Here, in the optimised module, because a million points done one by one in a Debug build were a second and a half of
/// opening a 400 m zone — most of it converting each layer's colour from sRGB again at every point, which is done once
/// here. The same sums as `WorldGround.point(_:_:)` and `normal(_:_:)`.
public enum WorldGroundVertices {
    public static let floatsPerPoint = 12

    /// Writes points `xs` × `zs` of a grid `resolution` cells a side and `size` metres across, centred on the origin.
    ///
    /// - Parameters:
    ///   - layerColours: each layer's colour, **already linear**.
    ///   - layerSoftness: each layer's softness, 1 soft, 0 not: a point's is its layers' by their weights.
    public static func write(heights: [Float], weights: [SIMD8<Float>], layerColours: [SIMD3<Float>],
                             layerSoftness: [Float] = [], resolution: Int, size: Float, xs: ClosedRange<Int>,
                             zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>) {
        let n = resolution + 1
        let spacing = size / Float(resolution), origin = -size / 2
        let layers = min(layerColours.count, 8)
        heights.withUnsafeBufferPointer { h in
            weights.withUnsafeBufferPointer { w in
                for z in zs {
                    for x in xs {
                        let i = z * n + x
                        let px = origin + Float(x) * spacing, pz = origin + Float(z) * spacing
                        let x0 = max(x - 1, 0), x1 = min(x + 1, resolution), z0 = max(z - 1, 0), z1 = min(z + 1, resolution)
                        let dx = Float(x1 - x0) * spacing, dz = Float(z1 - z0) * spacing
                        let normal = simd_normalize(SIMD3(-(h[z * n + x1] - h[z * n + x0]) / dx, 1,
                                                          -(h[z1 * n + x] - h[z0 * n + x]) / dz))
                        var colour = SIMD3<Float>.zero
                        var soft: Float = 0
                        if i < w.count {
                            let mix = w[i]
                            for layer in 0..<layers { colour += layerColours[layer] * mix[layer] }
                            for layer in 0..<min(layerSoftness.count, 8) { soft += layerSoftness[layer] * mix[layer] }
                        } else if let first = layerSoftness.first {
                            soft = first
                        }
                        let o = out + i * floatsPerPoint
                        o[0] = px; o[1] = h[i]; o[2] = pz
                        o[3] = normal.x; o[4] = normal.y; o[5] = normal.z
                        o[6] = px; o[7] = pz
                        o[8] = colour.x; o[9] = colour.y; o[10] = colour.z
                        o[11] = min(soft, 1)
                    }
                }
            }
        }
    }

    /// The same points, **coloured point by point** — a ground whose painted layers were mixed when it was saved, as a
    /// world file carries it — with how soft each point is beside it (empty for nowhere soft).
    public static func write(heights: [Float], colours: [SIMD3<Float>], softness: [Float], resolution: Int, size: Float,
                             xs: ClosedRange<Int>, zs: ClosedRange<Int>, into out: UnsafeMutablePointer<Float>) {
        let n = resolution + 1
        let spacing = size / Float(resolution), origin = -size / 2
        heights.withUnsafeBufferPointer { h in
            for z in zs {
                for x in xs {
                    let i = z * n + x
                    let px = origin + Float(x) * spacing, pz = origin + Float(z) * spacing
                    let x0 = max(x - 1, 0), x1 = min(x + 1, resolution), z0 = max(z - 1, 0), z1 = min(z + 1, resolution)
                    let dx = Float(x1 - x0) * spacing, dz = Float(z1 - z0) * spacing
                    let normal = simd_normalize(SIMD3(-(h[z * n + x1] - h[z * n + x0]) / dx, 1,
                                                      -(h[z1 * n + x] - h[z0 * n + x]) / dz))
                    let colour = i < colours.count ? colours[i] : SIMD3<Float>(repeating: 0)
                    let o = out + i * floatsPerPoint
                    o[0] = px; o[1] = h[i]; o[2] = pz
                    o[3] = normal.x; o[4] = normal.y; o[5] = normal.z
                    o[6] = px; o[7] = pz
                    o[8] = colour.x; o[9] = colour.y; o[10] = colour.z
                    o[11] = i < softness.count ? min(softness[i], 1) : 0
                }
            }
        }
    }
}

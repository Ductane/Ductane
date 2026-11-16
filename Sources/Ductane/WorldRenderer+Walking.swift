//
//  WorldRenderer+Walking.swift
//  Ductane
//

import Foundation
import simd

public extension WorldRenderer {

    /// **What a walker meets near `centre`**: every placed prop and scattered copy whose box comes within `reach` metres
    /// of it on the ground plane, with its solid triangles (``collisionTriangles(of:)``) and where it stands. Props a
    /// walker passes through (``walkedThrough``) and props not loaded yet are left out.
    ///
    /// Gathered on the main actor, where the props are; build the ``CollisionMesh`` from it off the main thread, since
    /// a few hundred buildings are millions of triangles, and gather again once the walker has gone a good way from
    /// `centre`:
    ///
    /// ```swift
    /// let near = world.solids(around: SIMD2(feet.x, feet.z), reach: 150)
    /// let mesh = await Task.detached { near.isEmpty ? nil : CollisionMesh(placed: near) }.value
    /// surroundings.meshes = mesh
    /// ```
    func solids(around centre: SIMD2<Float>, reach: Float) -> [(transform: simd_float4x4, triangles: [SIMD3<Float>])] {
        var placed: [(transform: simd_float4x4, triangles: [SIMD3<Float>])] = []
        // Asked once a prop, not once a copy: a marsh plants thousands of each.
        var solid: [URL: (bounds: BoundingBox, triangles: [SIMD3<Float>])?] = [:]
        func add(_ prop: URL, _ transform: simd_float4x4) {
            let known: (bounds: BoundingBox, triangles: [SIMD3<Float>])?
            if let asked = solid[prop] {
                known = asked
            } else {
                if !walkedThrough.contains(prop), let bounds = bounds(of: prop), let triangles = collisionTriangles(of: prop),
                   !triangles.isEmpty {
                    known = (bounds, triangles)
                } else {
                    known = nil
                }
                solid[prop] = known
            }
            guard let known else { return }
            let box = known.bounds.transformed(by: transform)
            let nearest = simd_clamp(centre, SIMD2(box.minimum.x, box.minimum.z), SIMD2(box.maximum.x, box.maximum.z))
            guard simd_distance(nearest, centre) <= reach else { return }
            placed.append((transform, known.triangles))
        }
        for placement in scene.placements { add(placement.prop, placement.transform) }
        for scatter in scene.scatters {
            for copy in scatter.copies where scatter.prototypes.indices.contains(copy.prototype) {
                add(scatter.prototypes[copy.prototype], copy.transform)
            }
        }
        return placed
    }
}

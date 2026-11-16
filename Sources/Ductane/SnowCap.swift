//
//  SnowCap.swift
//  Ductane
//

import simd

/// **Snow that builds up on roofs and props** (2026-11-16): a cap made from a prop's upward-facing surfaces when it loads,
/// which a renderer raises with the lying snow — a dusting to a thick, rounded slab on a roof, a rail or a rock. No pack
/// changes and nobody models it: ``make(_:)`` builds it from the prop's own triangles. Ultra Dynamic Weather and Enviro
/// raise snow on surfaces the same way.
///
/// **What a vertex says** (``Vertex``): where it sits on the prop; ``Vertex/lift``, how much of the snow's depth raises it
/// (1 on a flat top, less as a face tilts, less again at an edge, 0 at the foot of the cap's rim); ``Vertex/push``, 0 for a
/// vertex that stays put, else `1 + a / 2π` for one that leans out over the edge by a third of the depth — the rim's
/// rounding — toward the level direction at angle `a` from +x toward +z, in the prop's own space; the rim's top and its
/// skirt's top share it exactly, so they never part. A renderer: `position + up × depth × lift + direction × depth × 0.35`,
/// the direction turned with the copy, in the vertex stage.
public nonisolated enum SnowCap {

    /// One vertex of a cap, laid out as a prop's: position, normal, then `lift` and `push` where the uv would be.
    public struct Vertex: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var normal: SIMD3<Float>
        public var lift: Float
        public var push: Float

        /// The level direction a pushed vertex leans toward, in the prop's own space; zero for one that stays put.
        public var leaning: SIMD3<Float> {
            guard push >= 1 else { return .zero }
            let a = (push - 1) * 2 * .pi
            return SIMD3(cos(a), 0, sin(a))
        }

        public init(position: SIMD3<Float>, normal: SIMD3<Float>, lift: Float, push: Float) {
            self.position = position
            self.normal = normal
            self.lift = lift
            self.push = push
        }
    }

    /// A face counts as facing up from this much of its normal pointing up (about 72° from upright).
    public static let upward: Float = 0.3

    /// **The cap over `triangles`** — a triangle soup in the prop's own space, three corners each, wound as USD winds a
    /// front face: the upward faces welded into one surface, each corner lifted by how flat it is, with a skirt down from
    /// every open edge so the raised cap meets the prop with no gap. Empty when nothing faces up.
    public static func make(_ triangles: [SIMD3<Float>]) -> (vertices: [Vertex], indices: [UInt32]) {
        var weld: [SIMD3<Int32>: Int] = [:]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []
        func index(of p: SIMD3<Float>) -> Int {
            let key = SIMD3<Int32>(Int32(clamping: Int((p.x * 1000).rounded())), Int32(clamping: Int((p.y * 1000).rounded())),
                                   Int32(clamping: Int((p.z * 1000).rounded())))
            if let known = weld[key] { return known }
            weld[key] = positions.count
            positions.append(p)
            normals.append(.zero)
            return positions.count - 1
        }
        var t = 0
        while t + 2 < triangles.count {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            t += 3
            guard all(a .== a), all(b .== b), all(c .== c) else { continue }
            let n = simd_cross(b - a, c - a)
            let area = simd_length(n)
            guard area > 1e-8, n.y / area > upward else { continue }
            let i = index(of: a), j = index(of: b), k = index(of: c)
            guard i != j, j != k, i != k else { continue }
            faces.append((i, j, k))
            // Area-weighted: a big flat roof outweighs a sliver at its edge.
            normals[i] += n; normals[j] += n; normals[k] += n
        }
        guard !faces.isEmpty else { return ([], []) }

        // The open edges: those only one upward face has.
        struct Edge: Hashable { let a: Int, b: Int }
        var count: [Edge: Int] = [:]
        for (i, j, k) in faces {
            for (p, q) in [(i, j), (j, k), (k, i)] { count[Edge(a: min(p, q), b: max(p, q)), default: 0] += 1 }
        }
        var outward = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var open: [(Int, Int)] = []
        for (i, j, k) in faces {
            let centre = (positions[i] + positions[j] + positions[k]) / 3
            for (p, q) in [(i, j), (j, k), (k, i)] where count[Edge(a: min(p, q), b: max(p, q))] == 1 {
                // Away from the face, across the edge, level.
                let edge = positions[q] - positions[p]
                var across = SIMD3(-edge.z, 0, edge.x)
                let middle = (positions[p] + positions[q]) / 2
                if simd_dot(across, middle - centre) < 0 { across = -across }
                let length = simd_length(across)
                guard length > 1e-6 else { continue }
                outward[p] += across / length
                outward[q] += across / length
                open.append((p, q))
            }
        }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(positions.count + open.count * 4)
        let up = SIMD3<Float>(0, 1, 0)
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        var rim = [Bool](repeating: false, count: positions.count)
        for (p, q) in open { rim[p] = true; rim[q] = true }
        for v in positions.indices {
            let n = simd_length(normals[v]) > 0 ? simd_normalize(normals[v]) : up
            let lift = smoothstep(upward, 0.75, n.y)
            if rim[v], simd_length(outward[v]) > 1e-6 {
                let out = simd_normalize(SIMD3(outward[v].x, 0, outward[v].z))
                vertices.append(Vertex(position: positions[v], normal: simd_normalize(n + out * 0.8), lift: lift * 0.7,
                                       push: Self.push(toward: out)))
            } else {
                vertices.append(Vertex(position: positions[v], normal: n, lift: lift, push: 0))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * 3 + open.count * 6)
        for (i, j, k) in faces { indices += [UInt32(i), UInt32(j), UInt32(k)] }
        // The skirt: from the raised rim down to where the cap meets the prop, facing out.
        for (p, q) in open {
            let base = UInt32(vertices.count)
            for v in [p, q] {
                let top = vertices[v]
                let out = simd_length(outward[v]) > 1e-6 ? simd_normalize(SIMD3(outward[v].x, 0, outward[v].z)) : up
                vertices.append(Vertex(position: top.position, normal: simd_normalize(out + up * 0.3), lift: top.lift,
                                       push: top.push))
                vertices.append(Vertex(position: top.position, normal: out, lift: 0, push: 0))
            }
            // p top, p foot, q top, q foot.
            indices += [base, base + 1, base + 2, base + 2, base + 1, base + 3]
        }
        return (vertices, indices)
    }

    /// `1 + a / 2π` for the level direction `out` at angle `a`.
    static func push(toward out: SIMD3<Float>) -> Float {
        var a = atan2(out.z, out.x) / (2 * .pi)
        if a < 0 { a += 1 }
        return 1 + min(a, 0.999_999)
    }
}

import simd

/// **The part of a prop that turns in the wind** (2026-11-21) — a windmill's sails, a wind pump's wheel, a fan's blades,
/// a water wheel's paddles — found in its geometry, so a model made as one mesh still turns as it should.
///
/// A rotor is a ring: **several identical loose pieces round one hub, each pointing out from it** — sails, blades,
/// paddles. That is what is looked for. A tower's braces are a ring of identical pieces too, but each runs *round* its
/// middle, not out from it, and its legs run along the axis; neither is taken. The turning part is then that ring and
/// everything else that lies within its circle and close to its plane — the hub, the slats between sails — and the rest
/// stays where it is.
///
/// Worked out in the prop's own space (each mesh's node transform applied), never a mesh's, which may be scaled unevenly:
/// turned in a mesh's space and then squashed by its node, sails would flatten as they went round.
public nonisolated struct TurningPart: Sendable, Equatable {
    /// The point it turns about, in the prop's space.
    public var hub: SIMD3<Float>
    /// The axis it turns about, unit length.
    public var axis: SIMD3<Float>
    /// Per mesh, per submesh, per triangle: whether that triangle turns.
    public var turns: [[[Bool]]]

    /// How many triangles turn.
    public var count: Int { turns.reduce(0) { $0 + $1.reduce(0) { $0 + $1.filter { $0 }.count } } }

    /// **What turns, if anything does**: `meshes` gives each mesh's vertex positions in the prop's space and each of its
    /// submeshes' triangles as vertex indices, three at a time. Nil when no ring of pieces is found.
    public static func find(meshes given: [(positions: [SIMD3<Float>], submeshes: [[UInt32]])]) -> TurningPart? {
        // Triangles naming a vertex the mesh does not have are left out (a file is data from anyone); what turns is still
        // said per triangle of what was given, those left out never turning.
        let meshes = given.map { mesh in
            (positions: mesh.positions, submeshes: mesh.submeshes.map { indices in
                stride(from: 0, to: indices.count - 2, by: 3).flatMap { t -> [UInt32] in
                    let triangle = indices[t..<(t + 3)]
                    return triangle.allSatisfy { Int($0) < mesh.positions.count } ? Array(triangle) : []
                }
            })
        }
        // Every position, welded: a piece's faces are split at hard edges, and still one piece.
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude), upper = -lower
        for mesh in meshes {
            for p in mesh.positions {
                // A model is data from anyone: a position that is not a number has no place to turn about.
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
                lower = simd_min(lower, p); upper = simd_max(upper, p)
            }
        }
        let size = simd_reduce_max(upper - lower)
        guard size.isFinite, size > 0 else { return nil }
        let grain = size * 1e-5
        var weld: [SIMD3<Int32>: Int32] = [:]
        var welded: [SIMD3<Float>] = []
        let ids: [[Int32]] = meshes.map { mesh in
            mesh.positions.map { p in
                // Measured from the lowest corner, so every key is in range: at most 1e5 grains across.
                let q = ((p - lower) / grain).rounded(.toNearestOrAwayFromZero)
                let key = SIMD3<Int32>(Int32(clamping: Int(q.x)), Int32(clamping: Int(q.y)), Int32(clamping: Int(q.z)))
                if let id = weld[key] { return id }
                let id = Int32(welded.count)
                weld[key] = id
                welded.append(p)
                return id
            }
        }
        // Loose pieces: what triangles join.
        var parent = Array(0..<Int32(welded.count))
        func root(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
            return x
        }
        for (m, mesh) in meshes.enumerated() {
            for indices in mesh.submeshes {
                var t = 0
                while t + 2 < indices.count {
                    let a = root(ids[m][Int(indices[t])]), b = root(ids[m][Int(indices[t + 1])]), c = root(ids[m][Int(indices[t + 2])])
                    parent[Int(a)] = b; parent[Int(root(c))] = root(b)
                    t += 3
                }
            }
        }
        var pieceOf: [Int32: Int] = [:]
        var pieces: [[Int32]] = []
        var triangleCounts: [Int] = []
        for id in 0..<Int32(welded.count) {
            let r = root(id)
            if let index = pieceOf[r] { pieces[index].append(id) } else {
                pieceOf[r] = pieces.count
                pieces.append([id])
                triangleCounts.append(0)
            }
        }
        for (m, mesh) in meshes.enumerated() {
            for indices in mesh.submeshes {
                var t = 0
                while t + 2 < indices.count { triangleCounts[pieceOf[root(ids[m][Int(indices[t])])]!] += 1; t += 3 }
            }
        }
        guard pieces.count >= 4 else { return nil }

        // Each piece: its middle, its spread about it (the same for identical pieces however they are turned) and its
        // longest direction.
        struct Piece { let centre: SIMD3<Float>; let spread: Float; let along: SIMD3<Float>; let vertices: Int; let triangles: Int }
        let described: [Piece] = pieces.enumerated().map { index, members in
            let points = members.map { welded[Int($0)] }
            let centre = points.reduce(.zero, +) / Float(points.count)
            let spread = (points.reduce(0) { $0 + simd_length_squared($1 - centre) } / Float(points.count)).squareRoot()
            let (_, vectors) = eigen(covariance(points, about: centre))
            return Piece(centre: centre, spread: spread, along: vectors.2, vertices: points.count,
                         triangles: triangleCounts[index])
        }

        // Rings of identical pieces round one hub, each pointing out from it: **the one reaching furthest from its hub
        // wins** — sails, not the ring of bolts round a turbine's foot, which outnumber its three blades four to one.
        var best: (hub: SIMD3<Float>, axis: SIMD3<Float>, members: [Int], reach: Float)?
        let order = described.indices.sorted {
            (described[$0].vertices, described[$0].triangles, described[$0].spread)
                < (described[$1].vertices, described[$1].triangles, described[$1].spread)
        }
        var start = 0
        while start < order.count {
            var end = start + 1
            let first = described[order[start]]
            while end < order.count {
                let next = described[order[end]]
                guard next.vertices == first.vertices, next.triangles == first.triangles,
                      abs(next.spread - first.spread) <= max(first.spread * 0.03, grain * 10) else { break }
                end += 1
            }
            let group = Array(order[start..<end])
            start = end
            guard group.count >= 3, group.count <= 64, first.spread > size * 0.005 else { continue }
            let centres = group.map { described[$0].centre }
            let hub = centres.reduce(.zero, +) / Float(centres.count)
            let (values, vectors) = eigen(covariance(centres, about: hub))
            // A ring is flat: its middles lie in a plane, the axis square to it.
            guard values.0 <= max(values.1, 1e-12) * 0.05 else { continue }
            let axis = simd_normalize(vectors.0)
            let radii = centres.map { simd_length(($0 - hub) - simd_dot($0 - hub, axis) * axis) }
            let mean = radii.reduce(0, +) / Float(radii.count)
            guard mean > size * 0.02 else { continue }
            let deviation = (radii.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(radii.count)).squareRoot()
            guard deviation <= mean * 0.15 else { continue }
            // Each piece points out from the hub: a sail, not a brace running round a tower.
            let outward = zip(group, centres).map { index, centre -> Float in
                var radial = (centre - hub) - simd_dot(centre - hub, axis) * axis
                radial = simd_normalize(radial)
                return abs(simd_dot(radial, described[index].along))
            }
            guard outward.reduce(0, +) / Float(outward.count) >= 0.7 else { continue }
            var reach: Float = 0
            for index in group {
                for id in pieces[index] {
                    let d = welded[Int(id)] - hub
                    reach = max(reach, simd_length(d - simd_dot(d, axis) * axis))
                }
            }
            if best == nil || reach > best!.reach * 1.02
                || (abs(reach - best!.reach) <= best!.reach * 0.02 && group.count > best!.members.count) {
                best = (hub, axis, group, reach)
            }
        }
        // **No ring of identical pieces — sails each made differently, patched cloth beside planks**: then
        // spokes. Big pieces whose lengths all run through one hub, spread round it in a plane, each lying out to one side.
        if best == nil { best = spokes(described.indices.map { (described[$0].centre, described[$0].along, described[$0].spread) },
                                       pieces: pieces, welded: welded, size: size) }
        guard let ring = best else { return nil }

        // Everything within the ring's circle and near its plane turns with it.
        var reach: Float = 0, depth: Float = 0
        for index in ring.members {
            for id in pieces[index] {
                let d = welded[Int(id)] - ring.hub
                let along = simd_dot(d, ring.axis)
                reach = max(reach, simd_length(d - along * ring.axis))
                depth = max(depth, abs(along))
            }
        }
        reach *= 1.05
        // Close to its plane: a pitched blade stands out of it by part of its width, so a quarter of the reach at least.
        depth = max(depth * 1.25 + reach * 0.02, reach * 0.25)
        // **What turns with it**: whatever lies within its circle near its plane — the hub, the slats between sails — and
        // whatever starts inside the circle and points out from the hub, near the plane — a turbine's blades, longer than
        // the arms they are bolted to. Never past three times the ring's reach.
        let turningPieces = Set(pieces.indices.filter { index in
            var nearest = Float.greatestFiniteMagnitude, furthest: Float = 0
            for id in pieces[index] {
                let d = welded[Int(id)] - ring.hub
                let along = simd_dot(d, ring.axis)
                guard abs(along) <= depth else { return false }
                let radial = simd_length(d - along * ring.axis)
                nearest = min(nearest, radial)
                furthest = max(furthest, radial)
            }
            if furthest <= reach { return true }
            guard nearest <= reach, furthest <= reach * 3 else { return false }
            let piece = described[index]
            var out = (piece.centre - ring.hub) - simd_dot(piece.centre - ring.hub, ring.axis) * ring.axis
            guard simd_length(out) > 1e-6 else { return false }
            out = simd_normalize(out)
            return abs(simd_dot(out, piece.along)) >= 0.7
        })
        let turns: [[[Bool]]] = given.enumerated().map { m, mesh in
            mesh.submeshes.map { indices in
                stride(from: 0, to: indices.count - 2, by: 3).map { t in
                    guard indices[t..<(t + 3)].allSatisfy({ Int($0) < mesh.positions.count }) else { return false }
                    return turningPieces.contains(pieceOf[root(ids[m][Int(indices[t])])]!)
                }
            }
        }
        return TurningPart(hub: ring.hub, axis: ring.axis, turns: turns)
    }

    /// **A hub that big pieces point out from**: the point their lengths come nearest to passing through, found from each
    /// pair of them, kept where three or more pass within a twentieth of the prop's size of it, lie out to one side of it,
    /// and run in different directions in one plane — the axis square to that plane. Nil when none does.
    private static func spokes(_ described: [(centre: SIMD3<Float>, along: SIMD3<Float>, spread: Float)], pieces: [[Int32]],
                               welded: [SIMD3<Float>], size: Float)
        -> (hub: SIMD3<Float>, axis: SIMD3<Float>, members: [Int], reach: Float)? {
        let big = described.indices.filter { described[$0].spread >= size * 0.06 }
            .sorted { described[$0].spread > described[$1].spread }.prefix(48)
        let candidates = Array(big)
        guard candidates.count >= 3 else { return nil }
        let tolerance = size * 0.05
        var best: (hub: SIMD3<Float>, axis: SIMD3<Float>, members: [Int], reach: Float)?
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                let a = described[candidates[i]], b = described[candidates[j]]
                // The nearest points of the two lines.
                let w = a.centre - b.centre
                let d1 = a.along, d2 = b.along
                let bb = simd_dot(d1, d2), denominator = 1 - bb * bb
                guard denominator > 0.05 else { continue }
                let t = (bb * simd_dot(d2, w) - simd_dot(d1, w)) / denominator
                let u = (simd_dot(d2, w) - bb * simd_dot(d1, w)) / denominator
                let p = a.centre + d1 * t, q = b.centre + d2 * u
                guard simd_distance(p, q) <= tolerance else { continue }
                let hub = (p + q) / 2
                let members = candidates.filter { index in
                    let c = described[index]
                    let offset = hub - c.centre
                    let off = simd_length(offset - simd_dot(offset, c.along) * c.along)
                    return off <= tolerance && simd_length(offset) >= c.spread * 0.5
                }
                guard members.count >= 3 else { continue }
                // Directions spread round in a plane: their outer products' matrix has two large eigenvalues.
                var m = simd_float3x3()
                for index in members {
                    var d = described[index].centre - hub
                    d = simd_normalize(d)
                    m.columns.0 += d * d.x; m.columns.1 += d * d.y; m.columns.2 += d * d.z
                }
                let (values, vectors) = eigen(m)
                guard values.1 >= values.2 * 0.2, values.0 <= values.2 * 0.15 else { continue }
                let axis = simd_normalize(vectors.0)
                var reach: Float = 0
                for index in members {
                    for id in pieces[index] {
                        let d = welded[Int(id)] - hub
                        reach = max(reach, simd_length(d - simd_dot(d, axis) * axis))
                    }
                }
                if best == nil || members.count > best!.members.count
                    || (members.count == best!.members.count && reach > best!.reach) {
                    best = (hub, axis, members, reach)
                }
            }
        }
        return best
    }

    /// The covariance of points about a centre.
    private static func covariance(_ points: [SIMD3<Float>], about centre: SIMD3<Float>) -> simd_float3x3 {
        var c = simd_float3x3()
        for p in points {
            let d = p - centre
            c.columns.0 += d * d.x; c.columns.1 += d * d.y; c.columns.2 += d * d.z
        }
        let n = Float(max(points.count, 1))
        return simd_float3x3(c.columns.0 / n, c.columns.1 / n, c.columns.2 / n)
    }

    /// **A symmetric 3 × 3 matrix's eigenvalues, smallest first, and their vectors** — Jacobi rotations.
    static func eigen(_ m: simd_float3x3) -> (values: (Float, Float, Float), vectors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { a[i][j] = Double(m[j][i]) } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { p = 0; q = 2; largest = abs(a[0][2]) }
            if abs(a[1][2]) > largest { p = 1; q = 2; largest = abs(a[1][2]) }
            if largest < 1e-15 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq
            }
        }
        let order = [0, 1, 2].sorted { a[$0][$0] < a[$1][$1] }
        func vector(_ i: Int) -> SIMD3<Float> { SIMD3(Float(v[0][i]), Float(v[1][i]), Float(v[2][i])) }
        return ((Float(a[order[0]][order[0]]), Float(a[order[1]][order[1]]), Float(a[order[2]][order[2]])),
                (vector(order[0]), vector(order[1]), vector(order[2])))
    }

    /// **The turn it makes at an angle**, radians, as a transform in the prop's space: about ``axis`` through ``hub``.
    public func transform(angle: Float) -> simd_float4x4 {
        simd_float4x4(translation: hub) * simd_float4x4(simd_quatf(angle: angle, axis: axis))
            * simd_float4x4(translation: -hub)
    }

    /// **How fast it turns in a wind**, radians a second: a turn about every three seconds in a 10 m/s wind, still in
    /// none, never past about two turns a second.
    public static func speed(windSpeed: Float) -> Float { min(max(windSpeed, 0) * 0.2, 12) }
}

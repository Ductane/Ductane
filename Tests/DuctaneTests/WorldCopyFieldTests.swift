//
//  WorldCopyFieldTests.swift
//  DuctaneTests
//

import Testing
import simd
@testable import DuctaneCulling

/// The cells only skip work: whatever a copy would be on its own — drawn, at which level, casting into which cascade —
/// it is the same through the cells.
@Suite("Scattered copies in cells")
struct WorldCopyFieldTests {

    /// A field of copies, small ones everywhere and a few big ones, with a little randomness that is the same every run.
    private func field() -> WorldCopyField {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        var copies: [WorldCopyField.Copy] = []
        for _ in 0..<4000 {
            let p = SIMD3(random() * 300 - 150, random() * 4, random() * 300 - 150)
            let big = random() < 0.03
            let half = big ? SIMD3<Float>(2, 6, 2) : SIMD3<Float>(0.2, 0.3, 0.2)
            let scale: Float = 0.8 + random() * 0.4
            copies.append(.init(transform: simd_float4x4(translation: p), minimum: p - half, maximum: p + half, scale: scale,
                                prop: big ? 1 : 0))
        }
        return WorldCopyField(copies: copies, errors: [[0.01, 0.05, 0.2], [0.1, 0.5]])
    }

    /// The renderer's old rule, one copy at a time, with no cells.
    private func oneByOne(_ field: WorldCopyField, _ s: WorldCopyField.Settings) -> (visible: [Int: Int], cast: [[Int: Int]]) {
        var visible: [Int: Int] = [:]
        var cast = [[Int: Int]](repeating: [:], count: s.cascades.count)
        for copy in field.copies {
            let centre = simd_distance(s.eye, copy.centre)
            let pixels = 2 * copy.radius * s.pixelsPerRadian / max(centre - copy.radius, 0.5)
            guard pixels >= s.smallestDrawn else { continue }
            let casts = !s.cascades.isEmpty && pixels >= s.smallestCaster
            let inView = WorldCopyField.mayIntersect(s.view, copy.minimum, copy.maximum)
            guard inView || casts else { continue }
            let level = WorldCopyField.coarsestTier(errors: field.errors[copy.prop], distance: centre - copy.radius,
                                                    scale: copy.scale, pixelsPerRadian: s.pixelsPerRadian)
            let key = copy.prop * 10 + level
            if inView { visible[key, default: 0] += 1 }
            guard casts else { continue }
            let count = WorldCopyField.cascadeCount(forSize: 2 * copy.radius, texels: s.cascades.map(\.texelSize))
            for (c, cascade) in s.cascades.enumerated() where c < count
                && centre - copy.radius <= cascade.end && centre + copy.radius * 9 >= cascade.start
                && WorldCopyField.mayIntersect(cascade.planes, copy.minimum, copy.maximum) {
                // A level coarser for each cascade further out, as far as the prop has levels — and past the nearest,
                // no finer than the cascade's texels can show.
                var castLevel = min(level + c, field.errors[copy.prop].count)
                if c > 0 {
                    castLevel = max(castLevel, WorldCopyField.coarsestTier(errors: field.errors[copy.prop], distance: 1,
                                                                           scale: copy.scale, pixelsPerRadian: 1 / cascade.texelSize))
                }
                cast[c][copy.prop * 10 + castLevel, default: 0] += 1
            }
        }
        return (visible, cast)
    }

    private func counts(_ runs: WorldCopyField.Runs) -> [Int: Int] {
        Dictionary(runs.runs.map { ($0.prop * 10 + $0.level, $0.count) }, uniquingKeysWith: +)
    }

    @Test("Through the cells, the same copies at the same levels as one by one", arguments: [
        SIMD3<Float>(0, 2, 0), SIMD3<Float>(-140, 1.7, 120), SIMD3<Float>(0, 300, 0),
    ])
    func sameAsOneByOne(eye: SIMD3<Float>) {
        let field = field()
        let view = simd_float4x4.lookAt(eye: eye, target: SIMD3(20, 0, -30))
        let projection = simd_float4x4.perspective(fovY: 1, aspect: 1.5, near: 0.1, far: 2000)
        let sun = simd_float4x4.orthographic(halfWidth: 60, halfHeight: 60, near: -400, far: 400)
            * simd_float4x4.lookAt(eye: SIMD3(eye.x, 0, eye.z) + SIMD3(0.5, 1, 0.3), target: SIMD3(eye.x, 0, eye.z))
        let settings = WorldCopyField.Settings(
            eye: eye, pixelsPerRadian: 1000, view: Self.planes(projection * view), smallestDrawn: 3, smallestCaster: 80,
            cascades: [.init(planes: Self.planes(sun), start: 0, end: 20, texelSize: 0.05),
                       .init(planes: Self.planes(sun), start: 15, end: 80, texelSize: 0.5)])
        let chosen = field.select(settings)
        let expected = oneByOne(field, settings)
        // The coarse cascade's texels choose a coarser level than one-a-cascade would, for some copy: the rule is exercised.
        if eye.y < 100 {
            #expect(field.copies.contains { WorldCopyField.coarsestTier(errors: field.errors[$0.prop], distance: 1, scale: $0.scale,
                                                                        pixelsPerRadian: 1 / 0.5) > 1 })
        }
        // Not a comparison of two empty answers.
        #expect(chosen.visible.transforms.count > 20)
        if eye.y < 100 { #expect(chosen.cascades.contains { !$0.isEmpty }) }
        #expect(counts(chosen.visible) == expected.visible)
        #expect(chosen.cascades.map(counts) == expected.cast)
        #expect(chosen.visible.transforms.count == expected.visible.values.reduce(0, +))
        // From high above everything is far: most cells are passed over without a look inside.
        if eye.y > 100 { #expect(chosen.cellsOpened < field.cells.count / 2) }
    }

    @Test("A prop's own levels are chosen by size on screen, never an empty one")
    func ownLevels() {
        let tree = [25_278, 12_700, 6_562]
        #expect(WorldCopyField.ownLevel(triangles: tree, pixels: 2000) == 0)
        #expect(WorldCopyField.ownLevel(triangles: tree, pixels: 500) == 1)    // 15,625 to spend
        #expect(WorldCopyField.ownLevel(triangles: tree, pixels: 330) == 2)    // 6,806
        #expect(WorldCopyField.ownLevel(triangles: tree, pixels: 40) == 2)     // the coarsest, however small
        #expect(WorldCopyField.ownLevel(triangles: [900, 0], pixels: 1) == 0)  // an empty stand-in is not a level
    }

    @Test("A run's transforms are its own copies'")
    func runsHoldTheirTransforms() {
        let field = field()
        let settings = WorldCopyField.Settings(eye: SIMD3(0, 2, 0), pixelsPerRadian: 1000, view: [], smallestDrawn: 3,
                                               smallestCaster: 80)
        let chosen = field.select(settings)
        for run in chosen.visible.runs {
            for transform in chosen.visible.transforms[run.start..<run.start + run.count] {
                let p = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                #expect(field.copies.contains { $0.prop == run.prop && $0.transform == transform && simd_distance($0.centre, p) < 7 })
            }
        }
    }

    /// The five or six planes of a view-projection, normalised; a zero one dropped — Ductane's `Frustum`.
    static func planes(_ m: simd_float4x4) -> [SIMD4<Float>] {
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2, r2].compactMap { p in
            let l = simd_length(SIMD3(p.x, p.y, p.z))
            return l > 1e-6 ? p / l : nil
        }
    }

    /// A player turning grass down thins only the ground cover, takes the same copies every frame, and only takes more
    /// away as it falls — never swaps one for another, which would read as grass flickering.
    @Test("Ground cover thins to the density: the same copies each time, fewer as it falls, nothing else touched")
    func groundCoverThins() {
        let copies = field()
        func chosen(_ density: Float) -> (cover: Set<SIMD3<Float>>, others: Int) {
            let settings = WorldCopyField.Settings(eye: SIMD3(0, 400, 0), pixelsPerRadian: 1000, view: [], smallestDrawn: 0,
                                                   smallestCaster: 80, thinned: [true, false], density: density)
            let selection = copies.select(settings)
            var cover = Set<SIMD3<Float>>(), others = 0
            for run in selection.visible.runs {
                let positions = selection.visible.transforms[run.start..<run.start + run.count]
                    .map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
                if run.prop == 0 { cover.formUnion(positions) } else { others += positions.count }
            }
            return (cover, others)
        }
        let all = chosen(1), half = chosen(0.5), quarter = chosen(0.25)
        #expect(all.cover.count > 3000)
        let share = Float(half.cover.count) / Float(all.cover.count)
        #expect(abs(share - 0.5) < 0.05, "half the density drew \(share) of the grass")
        #expect(abs(Float(quarter.cover.count) / Float(all.cover.count) - 0.25) < 0.05)
        #expect(quarter.cover.isSubset(of: half.cover), "lowering the density swapped copies instead of taking them away")
        #expect(chosen(0.5).cover == half.cover, "a second frame chose different copies")
        #expect(half.others == all.others && quarter.others == all.others, "what is not ground cover was thinned")
    }

    /// A copy's place comes from a world file, data from anyone: a position that is not a number, infinite or past any
    /// integer must not stop the game when its thinning seed is made from it.
    @Test("A copy anywhere — not a number, infinite, past any integer — gets a seed without trapping")
    func seedFromAnyPlace() {
        for value: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1e30, 3.25] {
            let place = SIMD3<Float>(value, 0, value)
            let copy = WorldCopyField.Copy(transform: simd_float4x4(translation: place), minimum: place, maximum: place,
                                           scale: 1, prop: 0)
            _ = WorldCopyField.keeps(copy.seed, atDensity: 0.5)
        }
        let a = WorldCopyField.Copy(transform: simd_float4x4(translation: SIMD3(1, 0, 2)), minimum: .zero, maximum: .one,
                                    scale: 1, prop: 0)
        let b = WorldCopyField.Copy(transform: simd_float4x4(translation: SIMD3(1, 5, 2)), minimum: .zero, maximum: .one,
                                    scale: 2, prop: 1)
        #expect(a.seed == b.seed, "the seed is where it stands on the ground, whatever else differs")
    }

    /// The draw distance divides the smallest size drawn, so every kind comes in by the same share of its own distance.
    @Test("A shorter draw distance brings every kind in by the same share of its own distance")
    func drawDistanceIsAShareOfEachKindsOwn() {
        let small = WorldCopyField.Copy(transform: simd_float4x4(translation: .zero), minimum: SIMD3(repeating: -0.2),
                                        maximum: SIMD3(repeating: 0.2), scale: 1, prop: 0)
        let big = WorldCopyField.Copy(transform: simd_float4x4(translation: .zero), minimum: SIMD3(repeating: -4),
                                      maximum: SIMD3(repeating: 4), scale: 1, prop: 1)
        // Each kind's own distance: where it is `smallest` pixels across.
        func farthest(_ copy: WorldCopyField.Copy, smallest: Float) -> Float {
            var low: Float = 0, high: Float = 100_000
            for _ in 0..<60 {
                let mid = (low + high) / 2
                var moved = copy
                moved.centre = SIMD3(0, 0, mid)
                moved.minimum = moved.centre - SIMD3(repeating: copy.radius)
                moved.maximum = moved.centre + SIMD3(repeating: copy.radius)
                let field = WorldCopyField(copies: [moved], errors: [[], []])
                let drawn = !field.select(WorldCopyField.Settings(eye: .zero, pixelsPerRadian: 1000, view: [],
                                                                  smallestDrawn: smallest, smallestCaster: 1e9))
                    .visible.isEmpty
                if drawn { low = mid } else { high = mid }
            }
            return low
        }
        for copy in [small, big] {
            let full = farthest(copy, smallest: 3), short = farthest(copy, smallest: 3 / 0.6)
            #expect(abs(short / full - 0.6) < 0.02, "a 60% draw distance drew it to \(short / full) of its own")
        }
    }
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, abs(f.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)))
        let u = simd_cross(s, f)
        return simd_float4x4(rows: [SIMD4(s, -simd_dot(s, eye)), SIMD4(u, -simd_dot(u, eye)),
                                    SIMD4(-f, simd_dot(f, eye)), SIMD4(0, 0, 0, 1)])
    }

    /// Reversed-Z, as the engine's: near at depth 1, far at 0.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect
        return simd_float4x4(rows: [SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                                    SIMD4(0, 0, near / (far - near), far * near / (far - near)), SIMD4(0, 0, -1, 0)])
    }

    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(rows: [SIMD4(1 / halfWidth, 0, 0, 0), SIMD4(0, 1 / halfHeight, 0, 0),
                             SIMD4(0, 0, 1 / (far - near), far / (far - near)), SIMD4(0, 0, 0, 1)])
    }
}

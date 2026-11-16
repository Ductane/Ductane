//
//  WorldGroundDetailTests.swift
//  DuctaneTests
//

import Testing
import simd
@testable import DuctaneCulling

/// A coarse chunk must cover what the full one covers, meet its neighbours point for point at any level, keep the full
/// cell's winding, and say truthfully how far it strays.
@Suite("The ground's coarser levels")
struct WorldGroundDetailTests {

    private func signedArea(_ a: SIMD2<Int32>, _ b: SIMD2<Int32>, _ c: SIMD2<Int32>) -> Int32 {
        let u = b &- a, v = c &- a
        return u.x * v.y - u.y * v.x
    }

    @Test("every level covers the chunk exactly once, wound as a full cell is")
    func coversTheChunk() {
        // A full cell's two triangles, (x, z) → (x, z + 1) → (x + 1, z + 1) and its pair, have this sign.
        let fullSign = signedArea(SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1)).signum()
        for step in WorldGroundDetail.steps {
            let triangles = WorldGroundDetail.triangles(width: 32, height: 32, step: step)
            #expect(triangles.count % 3 == 0)
            var area: Int32 = 0
            for t in stride(from: 0, to: triangles.count, by: 3) {
                let s = signedArea(triangles[t], triangles[t + 1], triangles[t + 2])
                #expect(s.signum() == fullSign, "step \(step): a triangle wound the other way")
                area += abs(s)
            }
            // Twice the chunk's area: no gaps, no overlaps.
            #expect(area == 2 * 32 * 32, "step \(step)")
        }
    }

    @Test("a chunk's edge keeps every point, so neighbours at any level meet")
    func edgesKeepEveryPoint() {
        for step in WorldGroundDetail.steps {
            let triangles = WorldGroundDetail.triangles(width: 32, height: 32, step: step)
            // Every edge segment one cell long, as the full chunk next door has it, is an edge of some triangle.
            var segments = Set<SIMD4<Int32>>()
            func key(_ a: SIMD2<Int32>, _ b: SIMD2<Int32>) -> SIMD4<Int32> {
                (a.x, a.y) < (b.x, b.y) ? SIMD4(a.x, a.y, b.x, b.y) : SIMD4(b.x, b.y, a.x, a.y)
            }
            for t in stride(from: 0, to: triangles.count, by: 3) {
                for k in 0..<3 { segments.insert(key(triangles[t + k], triangles[t + (k + 1) % 3])) }
            }
            for i in Int32(0)..<32 {
                for (a, b) in [(SIMD2(i, 0), SIMD2(i + 1, 0)), (SIMD2(i, 32), SIMD2(i + 1, 32)),
                               (SIMD2(0, i), SIMD2(0, i + 1)), (SIMD2(32, i), SIMD2(32, i + 1))] {
                    #expect(segments.contains(key(a, b)), "step \(step): edge \(a)–\(b) is not one of its triangles' sides")
                }
            }
        }
    }

    @Test("a step that does not divide the chunk is not offered")
    func stepsThatDoNotFit() {
        #expect(WorldGroundDetail.triangles(width: 20, height: 32, step: 8).isEmpty)
        #expect(!WorldGroundDetail.fits(width: 20, height: 32, step: 8))
        #expect(WorldGroundDetail.fits(width: 20, height: 32, step: 4))
    }

    /// Heights for a 33-point square chunk as the renderer lays its vertices out: twelve floats a point, height second.
    private func vertices(_ height: (Int, Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: 33 * 33 * 12)
        for z in 0...32 { for x in 0...32 { out[(z * 33 + x) * 12 + 1] = height(x, z) } }
        return out
    }

    private func error(_ v: [Float], step: Int) -> Float {
        v.withUnsafeBufferPointer {
            WorldGroundDetail.error(of: WorldGroundDetail.triangles(width: 32, height: 32, step: step), heights: $0.baseAddress!,
                                 floatsPerPoint: 12, pointsPerRow: 33, originX: 0, originZ: 0)
        }
    }

    @Test("a sloping plane strays not at all; a bump strays by its height")
    func errors() {
        let plane = vertices { x, z in Float(x) * 0.3 - Float(z) * 0.1 + 2 }
        for step in WorldGroundDetail.steps { #expect(error(plane, step: step) < 1e-4) }
        // One point raised a metre where no coarse level has a vertex: every level misses all of it.
        let bump = vertices { x, z in x == 5 && z == 7 ? 1 : 0 }
        for step in WorldGroundDetail.steps { #expect(abs(error(bump, step: step) - 1) < 1e-5, "step \(step)") }
    }

    @Test("the coarsest step under half a pixel is chosen")
    func chosenStep() {
        let errors: [Float] = [0.01, 0.04, 0.2, 1]
        // 1,000 pixels a radian: at 100 m a pixel is 0.1 m, so 0.01 and 0.04 are under half of one and 0.2 is not.
        #expect(WorldGroundDetail.step(errors: errors, distance: 100, pixelsPerRadian: 1000) == 4)
        #expect(WorldGroundDetail.step(errors: errors, distance: 1, pixelsPerRadian: 1000) == 1)
        #expect(WorldGroundDetail.step(errors: errors, distance: 10_000, pixelsPerRadian: 1000) == 16)
        #expect(WorldGroundDetail.step(errors: [0.01, .infinity, .infinity, .infinity], distance: 100, pixelsPerRadian: 1000) == 2)
    }
}

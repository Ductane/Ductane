//
//  HUDTriangulationTests.swift
//  DuctaneTests
//

import Testing
import simd
@testable import Ductane

@Suite("HUD — filling a polygon")
struct HUDTriangulationTests {

    /// Unsigned area of a closed outline.
    static func area(of points: [SIMD2<Float>]) -> Float {
        var twice: Float = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    /// Summed unsigned area of index triples. Equal to the outline's only if the triangles neither
    /// overlap nor leave a gap — a fan over a concave shape does both, and can still come out equal by
    /// luck, which is why the fan test below also checks a point.
    static func area(of indices: [Int], in points: [SIMD2<Float>]) -> Float {
        stride(from: 0, to: indices.count, by: 3).reduce(0) { sum, i in
            sum + area(of: [points[indices[i]], points[indices[i + 1]], points[indices[i + 2]]])
        }
    }

    static func contains(_ p: SIMD2<Float>, triangle a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        func turn(_ o: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
            (q.x - o.x) * (r.y - o.y) - (q.y - o.y) * (r.x - o.x)
        }
        let d1 = turn(a, b, p), d2 = turn(b, c, p), d3 = turn(c, a, p)
        return (d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0)
    }

    @Test("A square is two triangles covering it")
    func square() {
        let square: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let indices = HUDRenderer.triangulate(square)
        #expect(indices.count == 6)
        #expect(abs(Self.area(of: indices, in: square) - 1) < 1e-6)
    }

    @Test("Either way round, the same area", arguments: [false, true])
    func winding(reversed: Bool) {
        var l: [SIMD2<Float>] = [[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]]
        if reversed { l.reverse() }
        let indices = HUDRenderer.triangulate(l)
        #expect(indices.count == (l.count - 2) * 3)
        #expect(abs(Self.area(of: indices, in: l) - Self.area(of: l)) < 1e-6)
    }

    /// A zigzag of five strokes: concave at four corners, and the shape a naive fill gets wrong.
    static let zigzag: [SIMD2<Float>] = [
        [0.0350, 0.2200], [0.2050, 0.2200], [0.3282, 0.6610], [0.4150, 0.4600], [0.5850, 0.4600], [0.6546, 0.5625], [0.7950, 0.0600], [0.9650, 0.0600], [0.7750, 0.7400], [0.6050, 0.7400], [0.5189, 0.6131], [0.3950, 0.9000], [0.2250, 0.9000],
    ]

    /// **Why not a fan.** Fanned from its first point, a zigzag puts triangles over ground outside the
    /// shape — the space between its arms — which ear clipping never does.
    @Test("A fan would draw outside a zigzag; ear clipping does not")
    func notAFan() {
        let w = Self.zigzag
        let fan = (1..<(w.count - 1)).flatMap { [0, $0, $0 + 1] }
        // Inside the left valley's mouth, between the left arm and the middle stroke: not part of the shape.
        let outside = SIMD2<Float>(0.31, 0.35)
        func covers(_ indices: [Int]) -> Bool {
            stride(from: 0, to: indices.count, by: 3).contains { i in
                Self.contains(outside, triangle: w[indices[i]], w[indices[i + 1]], w[indices[i + 2]])
            }
        }
        #expect(covers(fan), "the fan was expected to spill outside the zigzag, and did not — the test point is wrong")
        #expect(!covers(HUDRenderer.triangulate(w)), "ear clipping put a triangle outside the zigzag")
        #expect(abs(Self.area(of: HUDRenderer.triangulate(w), in: w) - Self.area(of: w)) < 1e-5)
    }

    @Test("Fewer than three points draw nothing")
    func degenerate() {
        #expect(HUDRenderer.triangulate([]).isEmpty)
        #expect(HUDRenderer.triangulate([[0, 0], [1, 1]]).isEmpty)
    }

    /// The feather's outer edge: each side moved out by the full width, so a square's corner goes out
    /// along its diagonal by √2 of it — whichever way round the square was given.
    @Test("A rim moves every edge out by its width, either way round", arguments: [false, true])
    func squareRim(reversed: Bool) {
        var square: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        if reversed { square.reverse() }
        let rim = HUDRenderer.rim(of: square, width: 0.1)
        let corner = rim[square.firstIndex(of: [0, 0])!]
        #expect(simd_distance(corner, [-0.1, -0.1]) < 1e-5, "the corner at the origin went to \(corner)")
    }

    /// Round a zigzag, every rim point lies outside the shape — including at its reflex corners, where a
    /// sign mistake would pull the feather inward and eat into the strokes.
    @Test("A zigzag's rim lies outside it")
    func zigzagRimOutside() {
        let w = Self.zigzag
        let rim = HUDRenderer.rim(of: w, width: 0.01)
        let triangles = HUDRenderer.triangulate(w)
        for (index, point) in rim.enumerated() {
            let inside = stride(from: 0, to: triangles.count, by: 3).contains { i in
                Self.contains(point, triangle: w[triangles[i]], w[triangles[i + 1]], w[triangles[i + 2]])
            }
            #expect(!inside, "rim point \(index) at \(point) is inside the shape")
        }
    }
}

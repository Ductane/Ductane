//
//  ImpostorViewsTests.swift
//  DuctaneTests
//

import Testing
import simd
@testable import DuctaneCulling

/// The bake and the draw both lay a far picture's views out this way, so a view must be where its cell says, its picture
/// square to it, and the blend for any eye a true weighting of neighbouring views.
@Suite("Where a far picture is seen from")
struct ImpostorViewsTests {

    @Test("a direction comes back from its point of the square")
    func roundTrip() {
        for x in stride(from: Float(-1), through: 1, by: 0.25) {
            for z in stride(from: Float(-1), through: 1, by: 0.25) {
                for y: Float in [0, 0.3, 1] {
                    let d = SIMD3(x, y, z)
                    guard simd_length(d) > 0.01 else { continue }
                    let back = ImpostorViews.decode(ImpostorViews.encode(simd_normalize(d)))
                    #expect(simd_distance(back, simd_normalize(d)) < 1e-4, "\(d) came back as \(back)")
                }
            }
        }
    }

    @Test("every view looks from above the horizon, its picture square to it")
    func viewsAreSquare() {
        #expect(ImpostorViews.views.count == ImpostorViews.side * ImpostorViews.side)
        for view in ImpostorViews.views {
            #expect(view.direction.y >= 0)
            for v in [view.direction, view.right, view.up] { #expect(abs(simd_length(v) - 1) < 1e-4) }
            #expect(abs(simd_dot(view.direction, view.right)) < 1e-4)
            #expect(abs(simd_dot(view.direction, view.up)) < 1e-4)
            #expect(abs(simd_dot(view.right, view.up)) < 1e-4)
            #expect(view.up.y >= -1e-4, "a picture is never upside down")
        }
    }

    @Test("an eye on a view's own direction sees that view alone")
    func eyeOnAView() {
        for (index, view) in ImpostorViews.views.enumerated() {
            let (views, weights) = ImpostorViews.blend(for: view.direction)
            var weight: Float = 0
            for k in 0..<4 where views[k] == Int32(index) { weight += weights[k] }
            #expect(abs(weight - 1) < 1e-3, "view \(index)")
        }
    }

    @Test("the blend's weights sum to one and name real views, below the horizon too")
    func blendWeights() {
        for x in stride(from: Float(-1), through: 1, by: 0.2) {
            for y in stride(from: Float(-0.5), through: 1, by: 0.25) {
                for z in stride(from: Float(-1), through: 1, by: 0.2) {
                    let (views, weights) = ImpostorViews.blend(for: SIMD3(x, y, z))
                    #expect(abs(weights.sum() - 1) < 1e-4)
                    for k in 0..<4 {
                        #expect(weights[k] >= 0)
                        #expect((0..<Int32(ImpostorViews.count)).contains(views[k]))
                    }
                }
            }
        }
    }
}

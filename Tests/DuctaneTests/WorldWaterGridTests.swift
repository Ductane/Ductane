//
//  WorldWaterGridTests.swift
//  DuctaneTests
//

import simd
import Testing
@testable import Ductane

@Suite("Water, looked up by where")
struct WorldWaterGridTests {

    @Test("The grid answers as asking every rectangle would, for points all over")
    func sameAsEveryRectangle() {
        // A marsh of small rectangles at two levels, some crossing cell edges.
        var rectangles: [(level: Float, rectangle: SIMD4<Float>)] = []
        for i in 0..<40 {
            let x = Float(i % 8) * 13 - 50, z = Float(i / 8) * 11 - 30
            rectangles.append((i % 3 == 0 ? 1.5 : 0, SIMD4(x, z, x + 9, z + 7)))
        }
        let grid = WorldWaterGrid(rectangles, cell: 16)
        func every(_ p: SIMD3<Float>) -> Bool {
            rectangles.contains { p.y < $0.level && p.x >= $0.rectangle.x && p.x <= $0.rectangle.z
                && p.z >= $0.rectangle.y && p.z <= $0.rectangle.w }
        }
        var under = 0
        for i in 0..<4000 {
            let p = SIMD3(Float(i % 63) * 1.9 - 60, Float(i % 5) * 0.5 - 1, Float(i / 63) * 0.9 - 35)
            #expect(grid.covers(p) == every(p), "at \(p)")
            if every(p) { under += 1 }
        }
        #expect(under > 100, "the check ran over water as well as off it")
        #expect(!WorldWaterGrid([]).covers(SIMD3(0, -10, 0)), "no water, nothing under it")
    }
}

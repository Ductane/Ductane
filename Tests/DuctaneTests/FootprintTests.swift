//
//  FootprintTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import Testing
import simd
@testable import Ductane

@Suite("Footprints")
struct FootprintTests {

    /// Walks character `id` from `start` along `direction` for `metres` at `speed`, in small steps.
    private static func walk(_ trail: inout FootprintTrail, id: Int = 1, from start: SIMD3<Float>,
                             along direction: SIMD3<Float>, metres: Float, speed: Float = 1.5,
                             shape: FootprintTrail.Shape = .boot) {
        var travelled: Float = 0
        while travelled <= metres {
            trail.step(character: id, feet: start + simd_normalize(direction) * travelled, speed: speed, shape: shape)
            travelled += 0.05
        }
    }

    @Test("A walk leaves a print each stride, left and right in turn, either side of the way, pointing along it")
    func strides() throws {
        var trail = FootprintTrail()
        Self.walk(&trail, from: SIMD3(0, 0, 0), along: SIMD3(0, 0, -1), metres: 10)
        let stride = FootprintTrail.stride(atSpeed: 1.5)
        #expect(abs(Float(trail.prints.count) - 10 / stride) <= 1.5, "\(trail.prints.count) prints of \(stride) m")
        for (a, b) in zip(trail.prints, trail.prints.dropFirst()) {
            #expect(a.isLeft != b.isLeft)
            #expect(abs(abs(a.position.y - b.position.y) - stride) < 0.06)
        }
        let print = try #require(trail.prints.first)
        #expect(abs(print.heading) < 1e-4, "walking along −z is heading 0")
        // Walking north, a left foot is to the west.
        for p in trail.prints { #expect(p.isLeft ? p.position.x < 0 : p.position.x > 0) }
        // Running spaces them out.
        var running = FootprintTrail()
        Self.walk(&running, from: .zero, along: SIMD3(1, 0, 0), metres: 10, speed: 7)
        #expect(running.prints.count < trail.prints.count)
        #expect(abs(running.prints[0].heading - .pi / 2) < 1e-3, "walking east")
    }

    @Test("No prints in the air, none across a teleport, and each character keeps its own feet")
    func gaps() {
        var trail = FootprintTrail()
        trail.step(character: 1, feet: .zero, speed: 2)
        trail.step(character: 1, feet: SIMD3(0, 0, 3), speed: 2, onGround: false)
        trail.step(character: 1, feet: SIMD3(0, 0, 4), speed: 2)
        #expect(trail.prints.isEmpty, "landing starts a trail, it does not make one")
        trail.step(character: 1, feet: SIMD3(50, 0, 50), speed: 2)
        #expect(trail.prints.isEmpty, "a teleport leaves no print")
        Self.walk(&trail, id: 2, from: SIMD3(10, 0, 0), along: SIMD3(1, 0, 0), metres: 3, shape: .bare)
        Self.walk(&trail, id: 3, from: SIMD3(-10, 0, 0), along: SIMD3(-1, 0, 0), metres: 3)
        #expect(trail.prints.contains { $0.shape == .bare } && trail.prints.contains { $0.shape == .boot })
    }

    @Test("Prints last half an hour in calm weather, minutes in falling snow, and fade as they go")
    func wiping() throws {
        var calm = FootprintTrail()
        Self.walk(&calm, from: .zero, along: SIMD3(0, 0, 1), metres: 2)
        let print = try #require(calm.prints.first)
        calm.advance(seconds: 900, weather: .clear)
        #expect(abs(calm.strength(of: print) - print.weight * 0.5) < 0.01, "half gone in a quarter of an hour")
        calm.advance(seconds: 901, weather: .clear)
        #expect(calm.prints.isEmpty, "gone after half an hour")
        var snowing = FootprintTrail()
        Self.walk(&snowing, from: .zero, along: SIMD3(0, 0, 1), metres: 2)
        snowing.advance(seconds: 200, weather: Weather(kind: .snow, severity: 1))
        #expect(snowing.prints.isEmpty, "heavy snow fills prints in within minutes")
        #expect(FootprintTrail.wipeRate(Weather(kind: .rain, severity: 1)) > FootprintTrail.wipeRate(.clear) * 10)
    }

    @Test("Prints far from the eye are let go, and no more than the most are kept")
    func keeping() {
        var trail = FootprintTrail()
        Self.walk(&trail, from: .zero, along: SIMD3(1, 0, 0), metres: 120)
        trail.forget(beyond: 48, of: SIMD3(0, 0, 0))
        #expect(!trail.prints.isEmpty && trail.prints.allSatisfy { simd_length($0.position) <= 48 })
        var crowd = FootprintTrail()
        for id in 0..<300 { Self.walk(&crowd, id: id, from: SIMD3(Float(id), 0, 0), along: SIMD3(0, 0, 1), metres: 40) }
        #expect(crowd.prints.count == FootprintTrail.maximumPrints)
    }

    @Test("The grid finds a print where it is, boot-shaped — long along the way, narrow across — at its height only")
    @MainActor
    func grid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var trail = FootprintTrail()
        Self.walk(&trail, from: SIMD3(2, 0.4, 2), along: SIMD3(0, 0, -1), metres: 1.2)
        let grid = try FootprintGrid(device: device)
        #expect(grid.update(frameSlot: 1, trail: trail, around: SIMD3(1, 0, 1)) == trail.prints.count)
        let print = try #require(trail.prints.first)
        let c = SIMD3(print.position.x, 0.4, print.position.y)
        #expect(grid.press(at: c, frameSlot: 1) > 0.6, "pressed in the middle")
        #expect(grid.press(at: c + SIMD3(0, 0, -0.1), frameSlot: 1) > 0.4, "toward the toe")
        #expect(grid.press(at: c + SIMD3(0, 0, 0.11), frameSlot: 1) > 0.4, "toward the heel")
        #expect(grid.press(at: c + SIMD3(0.08, 0, 0), frameSlot: 1) == 0 && grid.press(at: c - SIMD3(0.08, 0, 0), frameSlot: 1) == 0)
        #expect(grid.press(at: c + SIMD3(0, 0, 0.25), frameSlot: 1) == 0)
        #expect(grid.press(at: c + SIMD3(0, 3, 0), frameSlot: 1) == 0, "not on a roof three metres up")
        #expect(grid.press(at: SIMD3(20, 0.4, 20), frameSlot: 1) == 0)
        // A print across a cell's edge is found from both sides of it.
        var edge = FootprintTrail()
        Self.walk(&edge, from: SIMD3(0.5, 0, 3), along: SIMD3(0, 0, -1), metres: 3)
        grid.update(frameSlot: 0, trail: edge, around: .zero)
        for p in edge.prints {
            #expect(grid.press(at: SIMD3(p.position.x, 0, p.position.y), frameSlot: 0) > 0.5)
        }
        // Bare feet have toes: pressed at the toe's tip where a boot is not.
        #expect(FootprintTrail.Shape.bare.press(at: SIMD2(-0.62, 0.85)) > 0.5)
        #expect(FootprintTrail.Shape.boot.press(at: SIMD2(0, 0)) > 0.5)
        #expect(FootprintTrail.Shape.boot.press(at: SIMD2(1.1, 0)) == 0)
    }

    @Test("Many walkers crossing: every print is found, from the grid's first cells to its last, and nowhere between")
    @MainActor
    func crowded() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var trail = FootprintTrail()
        // Walkers along rows and columns, some through the same cells, near the grid's corners as well as its middle.
        for (n, start) in [SIMD3<Float>(-47, 0, -40), SIMD3(-20, 0, 10), SIMD3(-20.2, 0, 10), SIMD3(30, 0, 47)].enumerated() {
            Self.walk(&trail, id: n, from: start, along: SIMD3(1, 0, 0), metres: 15)
        }
        Self.walk(&trail, id: 9, from: SIMD3(-13, 0, 40), along: SIMD3(0, 0, -1), metres: 60)
        let grid = try FootprintGrid(device: device)
        #expect(grid.update(frameSlot: 2, trail: trail, around: .zero) == trail.prints.count)
        for p in trail.prints {
            #expect(grid.press(at: SIMD3(p.position.x, 0, p.position.y), frameSlot: 2) > 0.5)
        }
        #expect(grid.press(at: SIMD3(5, 0, -30), frameSlot: 2) == 0)
        #expect(grid.press(at: SIMD3(47.9, 0, -47.9), frameSlot: 2) == 0)
        // Written again with none, nothing is found where they were.
        grid.update(frameSlot: 2, trail: FootprintTrail(), around: .zero)
        #expect(trail.prints.allSatisfy { grid.press(at: SIMD3($0.position.x, 0, $0.position.y), frameSlot: 2) == 0 })
    }
}

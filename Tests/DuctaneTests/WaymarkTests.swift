import Foundation
import Metal
import Testing
import simd
@testable import Ductane

@Suite("Waymark")
struct WaymarkTests {

    private let flat: (SIMD2<Float>) -> Float = { _ in 0 }
    private let dryGround: (SIMD2<Float>) -> (height: Float, isStandable: Bool) = { _ in (0, true) }
    private let body = NavigationGrid.Body()

    // MARK: The way

    @Test("With no grid the way is the straight line")
    func straight() {
        #expect(Waymark.way(from: .zero, to: SIMD3(0, 0, -30), grid: nil, surface: flat) == [.zero, SIMD3(0, 0, -30)])
    }

    @Test("The way goes round a wall, not through it")
    func roundAWall() {
        let wall = CollisionMesh(triangles: CollisionMesh.box(centre: SIMD3(0, 1, 0), halfExtents: SIMD3(8, 1, 0.2)))
        let grid = NavigationGrid(mesh: wall, ground: dryGround, around: .zero, reach: 30, body: body)
        let way = Waymark.way(from: SIMD3(0, 0, 5), to: SIMD3(0, 0, -5), grid: grid, surface: flat)
        #expect(way.contains { abs($0.x) > 8 })
        #expect(simd_distance(way.last!, SIMD3(0, 0, -5)) < 0.6)
        // Drawn, the rounded line still keeps clear of the wall.
        let mark = Waymark(way: way, target: SIMD3(0, 0, -5), surface: flat)
        #expect(!mark.points.contains { abs($0.z) < 0.2 && abs($0.x) < 8 })
    }

    @Test("A goal off the grid is reached by the grid's edge, then straight on")
    func offTheGrid() {
        let grid = NavigationGrid(mesh: nil, ground: dryGround, around: .zero, reach: 20, body: body)
        let goal = SIMD3<Float>(0, 0, -100)
        let way = Waymark.way(from: .zero, to: goal, grid: grid, surface: flat)
        #expect(way.last == goal)
        let edge = way[way.count - 2]
        #expect(edge.z < -15 && edge.z >= -20.5)
    }

    // MARK: The line

    @Test("A point every step from the player to the place, never under the surface")
    func points() {
        let hill: (SIMD2<Float>) -> Float = { p in max(0, 2 - abs(p.y + 10) / 2) }
        let mark = Waymark(way: [.zero, SIMD3(0, 0, -20)], target: SIMD3(0, 0, -20), surface: hill)
        #expect(abs(mark.length - 20) < 1e-3)
        #expect(mark.points.count == 51)
        for p in mark.points { #expect(p.y >= hill(SIMD2(p.x, p.z)) + 0.1) }
        #expect(mark.points.contains { $0.y > 1.5 })
        #expect(!mark.turnedToFace)
    }

    @Test("Corners are rounded off, the ends kept")
    func rounded() {
        let way: [SIMD3<Float>] = [.zero, SIMD3(10, 0, 0), SIMD3(10, 0, 10)]
        let round = Waymark.rounded(way, passes: 3)
        #expect(round.first == way.first && round.last == way.last)
        #expect(!round.contains(SIMD3(10, 0, 0)))
        // Every point of the curve still lies within the corner's square.
        #expect(round.allSatisfy { $0.x >= 0 && $0.x <= 10 && $0.z >= 0 && $0.z <= 10 })
    }

    @Test("A way behind the player begins in front of them and turns round to it")
    func turnsToFace() throws {
        // Facing −z; the place 30 m behind, at +z.
        let way: [SIMD3<Float>] = [.zero, SIMD3(0, 0, 30)]
        let mark = Waymark(way: way, target: SIMD3(0, 0, 30), facing: SIMD3(0, 0, -1), surface: flat)
        #expect(mark.turnedToFace)
        // It leaves ahead of them: its first few meters go toward −z.
        let early = try #require(mark.points.first { $0.z < -2 })
        #expect(mark.distances[mark.points.firstIndex(of: early)!] < 4)
        // It swings out to one side, and ends at the place.
        #expect(mark.points.contains { abs($0.x) > 1.5 })
        #expect(simd_distance(mark.points.last!, SIMD3(0, 0.12, 30)) < 0.2)
        // Ahead of them, no turn; and a look that asks for none makes none.
        #expect(!Waymark(way: way, target: way[1], facing: SIMD3(0, 0, 1), surface: flat).turnedToFace)
        var plain = Waymark.Look()
        plain.turnsToFace = false
        #expect(!Waymark(way: way, target: way[1], facing: SIMD3(0, 0, -1), surface: flat, look: plain).turnedToFace)
        // To the side and a little behind it turns too, toward that side.
        let right = Waymark(way: [.zero, SIMD3(20, 0, 8)], target: SIMD3(20, 0, 8), facing: SIMD3(0, 0, -1), surface: flat)
        #expect(right.turnedToFace)
        #expect(right.points.prefix(30).contains { $0.x > 1 })
    }

    // MARK: Time

    @Test("It sweeps out, the beam is up at once, and it all fades at the end")
    func timing() {
        #expect(Waymark.Look().duration == 15)
        let six = Waymark.Look(duration: 6, fadeOut: 1.5)
        var mark = Waymark(way: [.zero, SIMD3(0, 0, -100)], target: SIMD3(0, 0, -100), surface: flat, look: six)
        mark.step(deltaTime: 0.5)
        #expect(abs(mark.front - 20) < 1e-3)
        #expect(mark.beamOpacity == 1)
        #expect(mark.ending == 1)
        mark.step(deltaTime: 4.75)   // 5.25 of 6: half through the fade
        #expect(abs(mark.beamOpacity - 0.5) < 0.01)
        mark.step(deltaTime: 1)
        #expect(mark.isOver && mark.ending == 0)
    }

    @Test("A mark every spacing from the first spacing out, heading along the line; a line has none")
    func marks() {
        let mark = Waymark(way: [.zero, SIMD3(0, 0, -10)], target: SIMD3(0, 0, -10), surface: flat,
                           look: Waymark.Look(spacing: 2))
        #expect(mark.marks.map(\.distance) == [2, 4, 6, 8, 10])
        #expect(mark.marks.allSatisfy { simd_distance($0.tangent, SIMD3(0, 0, -1)) < 1e-4 })
        #expect(abs(mark.marks[1].position.z + 4) < 1e-3)
        let line = Waymark(way: [.zero, SIMD3(0, 0, -10)], target: SIMD3(0, 0, -10), surface: flat,
                           look: Waymark.Look(pattern: .line))
        #expect(line.marks.isEmpty)
    }

    // MARK: Its sound

    @Test("Every sound is made, short and below full scale; none is silence")
    func sounds() {
        for sound in Waymark.Look.Sound.allCases where sound != .none {
            let samples = WaymarkSound.samples(sound)
            #expect(!samples.isEmpty && Double(samples.count) / WaymarkSound.sampleRate < 1.5, "\(sound)")
            #expect((samples.map(abs).max() ?? 0) > 0.2 && (samples.map(abs).max() ?? 1) < 0.5, "\(sound)")
        }
        #expect(WaymarkSound.samples(.none).isEmpty)
    }

    // MARK: Its look

    @Test("A saved look keeps what it said and fills in what it did not")
    func savedLook() throws {
        let json = #"{"pattern":"chevrons","width":0.3,"beam":{"height":40},"placement":"ground","sound":"sonar"}"#
        let look = try JSONDecoder().decode(Waymark.Look.self, from: Data(json.utf8))
        #expect(look.pattern == .chevrons && look.width == 0.3 && look.beam.height == 40)
        #expect(look.placement == .ground && look.sound == .sonar && look.volume == Waymark.Look().volume)
        #expect(look.spacing == Waymark.Look().spacing && look.beam.width == Waymark.Look.Beam().width)
        let again = try JSONDecoder().decode(Waymark.Look.self, from: JSONEncoder().encode(look))
        #expect(again == look)
        // Out of range, clamped.
        let wild = try JSONDecoder().decode(Waymark.Look.self, from: Data(#"{"roundness":4,"glow":-1}"#.utf8))
        #expect(wild.roundness == 1 && wild.glow == 0)
    }

    // MARK: Drawing

    @Test("The shader's frame and corner are the sizes Swift writes")
    func layout() {
        #expect(MemoryLayout<WaymarkRenderer.Vertex>.stride == 32)
        #expect(MemoryLayout<WaymarkRenderer.Frame>.size == 64 + 16 * 8)
    }

    private final class Draws: GameLoop {
        let renderer: WaymarkRenderer
        let mark: Waymark
        let eye: SIMD3<Float>
        let pitch: Float
        var drew = false
        init(_ renderer: WaymarkRenderer, _ mark: Waymark, eye: SIMD3<Float>, pitch: Float) {
            self.renderer = renderer
            self.mark = mark
            self.eye = eye
            self.pitch = pitch
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let view = Camera(position: eye, yaw: 0, pitch: pitch).viewMatrix
            let projection = simd_float4x4(perspectiveFovY: 60 * .pi / 180, aspectRatio: 1, nearZ: 0.1)
            drew = renderer.draw(mark, into: encoder, frameSlot: frameSlot, viewProjection: projection * view,
                                 camera: eye, time: 1)
        }
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    /// The frame's pixels, BGRA, 64 × 64.
    @MainActor
    /// Over the line from above and behind, looking down it — unless told otherwise.
    private func frame(of mark: Waymark, eye: SIMD3<Float> = SIMD3(0, 3, 3), pitch: Float = -0.5,
                       device: MTLDevice) throws -> (pixels: [UInt8], drew: Bool) {
        let frames = try FrameRenderer(device: device)
        let renderer = try WaymarkRenderer(device: device, sampleCount: frames.effectiveSampleCount)
        frames.residencySet.addAllocations(renderer.allocations)
        let game = Draws(renderer, mark, eye: eye, pitch: pitch)
        frames.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        frames.residencySet.addAllocation(target)
        frames.commitResidency()
        frames.render(into: target)
        var p = [UInt8](repeating: 0, count: 64 * 64 * 4)
        target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return (p, game.drew)
    }

    @Test("Drawn in its color, every pattern; over, nothing")
    @MainActor
    func draws() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        func redness(_ pixels: [UInt8]) -> Int {
            stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + max(Int(pixels[$1 + 2]) - Int(pixels[$1 + 1]), 0) }
        }
        var look = Waymark.Look(color: SIMD3(1, 0, 0), intensity: 1, width: 0.5, glow: 0, flow: 0)
        look.beam.isVisible = false
        let empty = try frame(of: Waymark(way: [.zero], target: .zero, surface: flat, look: look), device: device)
        for placement in Waymark.Look.Placement.allCases { for pattern in Waymark.Look.Pattern.allCases {
            look.placement = placement
            look.pattern = pattern
            var mark = Waymark(way: [.zero, SIMD3(0, 0, -30)], target: SIMD3(0, 0, -30), surface: flat, look: look)
            mark.step(deltaTime: 2)
            let shown = try frame(of: mark, device: device)
            #expect(shown.drew)
            #expect(redness(shown.pixels) > redness(empty.pixels) + 2_000, "\(placement) \(pattern)")
            mark.step(deltaTime: 20)
            let over = try frame(of: mark, device: device)
            #expect(!over.drew)
        } }
        // **Seen from low down, a floating dot stays round** and one on the ground goes flat: the floating dots cover far
        // more of the frame.
        look.pattern = .dots
        func lowDots(_ placement: Waymark.Look.Placement) throws -> Int {
            look.placement = placement
            var mark = Waymark(way: [.zero, SIMD3(0, 0, -30)], target: SIMD3(0, 0, -30), surface: flat, look: look)
            mark.step(deltaTime: 2)
            return redness(try frame(of: mark, eye: SIMD3(0, 0.3, 3), pitch: -0.05, device: device).pixels)
        }
        #expect(try lowDots(.floating) > lowDots(.ground) * 2)
        // The beam alone, seen ahead.
        look.beam = Waymark.Look.Beam(color: SIMD3(1, 0, 0), intensity: 1)
        look.pattern = .line
        look.width = 0.02
        var beam = Waymark(way: [.zero, SIMD3(0, 0, -12)], target: SIMD3(0, 0, -12), surface: flat, look: look)
        beam.step(deltaTime: 0.01)   // the line not out yet; the beam rising
        beam.step(deltaTime: 1)
        #expect(redness(try frame(of: beam, device: device).pixels) > redness(empty.pixels) + 2_000)
    }
}

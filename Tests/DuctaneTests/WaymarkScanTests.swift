import Foundation
import Metal
import Testing
import simd
@testable import Ductane

@Suite("Waymark scan")
struct WaymarkScanTests {

    // MARK: Kinds and the path's colour

    @Test("A path takes its kind's colour, and a kind with none keeps the line's")
    func pathColourByKind() {
        let look = Waymark.Look()
        #expect(look.leading(to: "objective").color == SIMD3(1, 0.62, 0.05))
        #expect(look.leading(to: "OBJECTIVE").color == SIMD3(1, 0.62, 0.05))
        #expect(look.leading(to: "unheard-of").color == look.color)
        #expect(look.leading(to: nil) == look)
        var custom = look
        custom.kinds["door"] = Waymark.Look.Kind(icon: .door)
        #expect(custom.leading(to: "door").color == look.color)
        let mark = Waymark(way: [.zero, SIMD3(0, 0, -10)], target: SIMD3(0, 0, -10), surface: { _ in 0 }, look: look,
                           kind: "enemy")
        #expect(mark.look.color == SIMD3(1, 0.12, 0.08))
    }

    @Test("Kinds are kept by their names in lower case")
    func kindsLowerCase() {
        let look = Waymark.Look(kinds: ["Supply Crate": Waymark.Look.Kind(icon: .crate)])
        #expect(look.kinds["supply crate"]?.icon == .crate)
        #expect(look.kind("SUPPLY CRATE").icon == .crate)
        #expect(look.kind("nothing").icon == .diamond)
    }

    @Test("A look read without a scan or kinds takes the engine's; one with them keeps them")
    func codable() throws {
        let old = try JSONDecoder().decode(Waymark.Look.self, from: Data(#"{"pattern":"arrows"}"#.utf8))
        #expect(old.pattern == .arrows)
        #expect(old.scan == Waymark.Look.Scan())
        #expect(old.kinds == Waymark.Look.defaultKinds)
        var look = Waymark.Look()
        look.scan.reach = 80
        look.scan.showsDistance = false
        look.kinds["vending"] = Waymark.Look.Kind(icon: .cross, color: SIMD3(0, 1, 0), markers: true)
        let back = try JSONDecoder().decode(Waymark.Look.self, from: JSONEncoder().encode(look))
        #expect(back == look)
        // A scan missing a key keeps the rest.
        let partial = try JSONDecoder().decode(Waymark.Look.Scan.self, from: Data(#"{"reach":120}"#.utf8))
        #expect(partial.reach == 120 && partial.speed == Waymark.Look.Scan().speed)
        // An icon this engine does not know is a diamond, not an error.
        let kind = try JSONDecoder().decode(Waymark.Look.Kind.self, from: Data(#"{"icon":"teapot","markers":true}"#.utf8))
        #expect(kind.icon == .diamond && kind.markers)
    }

    // MARK: Finding

    @Test("The ring finds what it reaches, across the ground, and nothing past its reach")
    func ringFinds() {
        var findables = Findables()
        let near = findables.add(kind: "loot", at: SIMD3(10, 0, 0))
        let high = findables.add(kind: "loot", at: SIMD3(0, 30, 20))   // 20 m across the ground, however high
        let far = findables.add(kind: "loot", at: SIMD3(0, 0, -70))
        var scan = WaymarkScan(from: .zero)
        scan.step(deltaTime: 0.1, findables: findables.all)
        #expect(scan.front == 5 && scan.found.isEmpty)
        scan.step(deltaTime: 0.15, findables: findables.all)
        #expect(scan.found[near] != nil && scan.found[high] == nil)
        scan.step(deltaTime: 1, findables: findables.all)
        #expect(scan.found[high] != nil)
        #expect(scan.front == 50 && scan.found[far] == nil)
        // Found when the ring reached it, not when the step came round.
        #expect(abs(scan.found[near]! - 0.2) < 1e-4)
    }

    @Test("An outline shows for its seconds, the icon a little longer, then the scan is over")
    func timing() {
        var findables = Findables()
        findables.add(kind: "enemy", at: SIMD3(5, 0, 0))
        var scan = WaymarkScan(from: .zero)
        scan.step(deltaTime: 0.5, findables: findables.all)
        var shown = scan.shown(findables.all, from: .zero)
        #expect(shown.count == 1 && shown[0].outline == 1 && shown[0].icon == 1 && shown[0].distance == 5)
        scan.step(deltaTime: 6, findables: findables.all)   // 6.4 s after it was found
        shown = scan.shown(findables.all, from: .zero)
        #expect(shown[0].outline == 0 && shown[0].icon == 1)
        #expect(!scan.isOver)
        scan.step(deltaTime: 2, findables: findables.all)
        #expect(scan.shown(findables.all, from: .zero).isEmpty)
        #expect(scan.isOver)
    }

    @Test("A found thing shows where it is now; one removed shows no more; one added behind the ring is not found")
    func moving() {
        var findables = Findables()
        let runner = findables.add(kind: "enemy", at: SIMD3(5, 0, 0))
        let gone = findables.add(kind: "loot", at: SIMD3(6, 0, 0))
        var scan = WaymarkScan(from: .zero)
        scan.step(deltaTime: 0.5, findables: findables.all)
        findables.move(runner, to: SIMD3(80, 0, 0))
        findables.remove(gone)
        let late = findables.add(kind: "loot", at: SIMD3(3, 0, 0))
        scan.step(deltaTime: 0.5, findables: findables.all)
        let shown = scan.shown(findables.all, from: .zero)
        #expect(shown.map(\.findable.id) == [runner])
        #expect(shown[0].findable.position == SIMD3(80, 0, 0))
        #expect(scan.found[late] == nil)
        #expect(findables.count == 2)
    }

    @Test("A scan whose ring has gone with nothing found is over once its ring is")
    func emptyScan() {
        var scan = WaymarkScan(from: .zero)
        scan.step(deltaTime: 0.9, findables: [])
        #expect(!scan.isOver && scan.ringOpacity > 0 && scan.ringOpacity < 1)
        scan.step(deltaTime: 0.2, findables: [])
        #expect(scan.ringOpacity == 0)
        // A scan stays over until its icons have gone too, none here.
        #expect(scan.isOver == (scan.age >= scan.look.scan.holds + scan.look.scan.iconLinger))
    }

    @Test("The ring runs over the surface it is given")
    func ringOnSurface() {
        var scan = WaymarkScan(from: SIMD3(10, 0, 10))
        scan.step(deltaTime: 0.2, findables: [])
        let points = scan.ring(count: 8) { p in p.x * 0.1 }
        #expect(points.count == 8)
        for p in points {
            #expect(abs(simd_distance(SIMD2(p.x, p.z), SIMD2(10, 10)) - 10) < 1e-3)
            #expect(abs(p.y - p.x * 0.1) < 1e-5)
        }
    }

    // MARK: What a world tags

    @Test("A world's tagged props and markers of a found kind are found; other markers are not")
    func inWorld() throws {
        var look = Waymark.Look()
        look.kinds["cache"] = Waymark.Look.Kind(icon: .crate, markers: true)
        let identity = matrix_identity_float4x4
        let world = WorldFile(
            name: "Test", props: ["crate.usda", "rock.usda"], found: [0: "loot"],
            placements: [WorldFile.Placement(prop: 0, transform: identity),
                         WorldFile.Placement(prop: 1, transform: identity),
                         WorldFile.Placement(prop: 0, transform: simd_float4x4(translation: SIMD3(4, 0, 0)))],
            markers: [WorldFile.Marker(kind: "spawn", position: .zero),
                      WorldFile.Marker(kind: "Cache", position: SIMD3(2, 0, 2))],
            waymark: look)
        let back = try WorldFile.read(JSONEncoder().encode(world))
        #expect(back.found == [0: "loot"])
        let found = Findables.inWorld(back, propURL: { URL(filePath: "/p/\(back.props[$0])") },
                                      propBounds: { _ in BoundingBox(minimum: .zero, maximum: SIMD3(1, 1, 1)) })
        #expect(found.map(\.kind) == ["Cache", "loot", "loot"])
        #expect(found[2].position == SIMD3(4, 0, 0))
        #expect(found[1].top == 1.5)
        #expect(Set(found.map(\.id)).count == 3 && found.allSatisfy { $0.id.raw < 0 })
        if case .prop(let url, _) = found[1].outline { #expect(url.lastPathComponent == "crate.usda") } else { Issue.record() }
    }

    @Test("A world file naming a found prop it lacks is refused")
    func badFoundProp() throws {
        let world = WorldFile(name: "Test", props: ["crate.usda"], found: [3: "loot"],
                              placements: [WorldFile.Placement(prop: 0, transform: matrix_identity_float4x4)])
        #expect(throws: WorldFile.ReadError.self) { try WorldFile.read(JSONEncoder().encode(world)) }
    }

    // MARK: The renderer

    @Test("What the shaders read is laid out as they expect")
    func layouts() {
        #expect(MemoryLayout<WaymarkScanRenderer.Icon>.stride == 48)
        #expect(MemoryLayout<WaymarkScanRenderer.Frame>.size == 64 + 16 * 5)
        #expect(MemoryLayout<WaymarkScanRenderer.Part>.size == 64 + 16)
    }

    @MainActor @Test("The scan's shaders compile and its pipelines build", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func renders() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try WaymarkScanRenderer(device: device)
    }

    // MARK: Drawn

    private final class Draws: GameLoop {
        let renderer: WaymarkScanRenderer
        let scan: WaymarkScan
        let shown: [WaymarkScan.Shown]
        let parts: [WaymarkScanRenderer.MaskPart]
        let eye = SIMD3<Float>(0, 8, 16)
        var mask: MTLTexture?
        var drew = false
        init(_ renderer: WaymarkScanRenderer, _ scan: WaymarkScan, _ shown: [WaymarkScan.Shown],
             _ parts: [WaymarkScanRenderer.MaskPart]) {
            self.renderer = renderer
            self.scan = scan
            self.shown = shown
            self.parts = parts
        }
        var viewProjection: simd_float4x4 {
            let view = Camera(position: eye, yaw: 0, pitch: -0.45).viewMatrix
            return simd_float4x4(perspectiveFovY: 60 * .pi / 180, aspectRatio: 1, nearZ: 0.1) * view
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {
            mask = renderer.encodeMask(parts, viewProjection: viewProjection, width: 96, height: 96, frameSlot: frameSlot,
                                       into: commandBuffer)
        }
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            drew = renderer.draw(scan, shown: shown, surface: { _ in 0 }, mask: mask, into: encoder, frameSlot: frameSlot,
                                 viewProjection: viewProjection, camera: eye, viewportSize: SIMD2(96, 96))
        }
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    /// The frame's pixels, BGRA, 96 × 96, looking down over the scan's origin from behind.
    @MainActor
    private func frame(_ scan: WaymarkScan, shown: [WaymarkScan.Shown] = [], parts: [WaymarkScanRenderer.MaskPart] = [],
                       device: MTLDevice, extra: [any MTLAllocation] = []) throws -> (pixels: [UInt8], drew: Bool) {
        let frames = try FrameRenderer(device: device)
        frames.sampleCount = 1
        let renderer = try WaymarkScanRenderer(device: device, sampleCount: frames.effectiveSampleCount)
        renderer.allocationsChanged = { added, _ in frames.residencySet.addAllocations(added); frames.commitResidency() }
        frames.residencySet.addAllocations(renderer.allocations + extra)
        let game = Draws(renderer, scan, shown, parts)
        frames.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 96, height: 96, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        frames.residencySet.addAllocation(target)
        frames.commitResidency()
        frames.render(into: target)
        var p = [UInt8](repeating: 0, count: 96 * 96 * 4)
        target.getBytes(&p, bytesPerRow: 96 * 4, from: MTLRegionMake2D(0, 0, 96, 96), mipmapLevel: 0)
        return (p, game.drew)
    }

    /// How much more blue than red the frame is — the scan's colour.
    private func blueness(_ p: [UInt8]) -> Int {
        stride(from: 0, to: p.count, by: 4).reduce(0) { $0 + max(Int(p[$1]) - Int(p[$1 + 2]), 0) }
    }

    @Test("The ring, an icon and an outline each draw; a scan that is over draws nothing")
    @MainActor
    func draws() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        var look = Waymark.Look()
        look.scan.color = SIMD3(0, 0.3, 1)
        look.kinds["loot"]?.color = SIMD3(0, 0.3, 1)
        let empty = blueness(try frame(WaymarkScan(from: .zero, look: look), device: device).pixels)

        // The ring, halfway out.
        var ringing = WaymarkScan(from: .zero, look: look)
        ringing.step(deltaTime: 0.2, findables: [])
        let ring = try frame(ringing, device: device)
        #expect(ring.drew)
        #expect(blueness(ring.pixels) > empty + 3_000)

        // An icon, once the ring has gone.
        var findables = Findables()
        findables.add(kind: "loot", at: SIMD3(0, 0, 0), top: 1)
        var found = WaymarkScan(from: .zero, look: look)
        found.step(deltaTime: 0.01, findables: findables.all)
        found.step(deltaTime: 1.5, findables: findables.all)
        let shown = found.shown(findables.all, from: SIMD3(0, 8, 16))
        #expect(shown.count == 1)
        let icon = try frame(found, shown: shown, device: device)
        #expect(icon.drew)
        #expect(blueness(icon.pixels) > empty + 3_000)

        // An outline round a box, from its triangles, seen though nothing else is drawn.
        let corners: [Float] = [-1, 0, -1, 1, 0, -1, 1, 2, -1, -1, 2, -1, -1, 0, 1, 1, 0, 1, 1, 2, 1, -1, 2, 1]
        var vertices: [Float] = []
        for c in stride(from: 0, to: corners.count, by: 3) { vertices += [corners[c], corners[c + 1], corners[c + 2], 0, 0, 0, 0, 0] }
        let faces: [UInt32] = [0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6, 0, 4, 5, 0, 5, 1, 3, 2, 6, 3, 6, 7, 0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2]
        let vb = try #require(device.makeBuffer(bytes: vertices, length: vertices.count * 4, options: .storageModeShared))
        let ib = try #require(device.makeBuffer(bytes: faces, length: faces.count * 4, options: .storageModeShared))
        let draw = Findable.MaskDraw(vertices: vb.gpuAddress, stride: 32, indices: ib.gpuAddress, indexCount: faces.count,
                                     indexType: .uint32)
        var outlined = shown
        outlined[0].icon = 0
        let outline = try frame(found, shown: outlined, parts: [WaymarkScanRenderer.MaskPart(draw: draw, opacity: 1)],
                                device: device, extra: [vb, ib])
        #expect(outline.drew)
        #expect(blueness(outline.pixels) > empty + 3_000)

        var over = found
        over.step(deltaTime: 30, findables: findables.all)
        #expect(over.isOver)
        let none = try frame(over, shown: over.shown(findables.all, from: .zero), device: device)
        #expect(!none.drew)
    }
}

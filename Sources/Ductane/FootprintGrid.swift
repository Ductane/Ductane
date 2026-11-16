//
//  FootprintGrid.swift
//  Ductane
//

import Metal
import simd

/// Why a ``FootprintGrid`` could not be made.
public nonisolated enum FootprintGridError: Error, CustomStringConvertible, Sendable {
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .couldNotCreate(let what): "the device would not create the footprints' \(what)"
        }
    }
}

/// **The prints round the eye, for a shader to find**: ``FootprintTrail``'s prints near the eye in one buffer, and a grid
/// of ``cellSize``-metre cells over ``halfExtent`` metres either way saying which prints touch each — so a pixel looks at
/// the few in its cell and works out each print's shape exactly (``Shape``'s ``press(at:)``, which a shader copies), sharp
/// at any distance, for well under a megabyte.
///
/// A print drawn into a texture instead was two or three texels wide at any size a frame can afford: every boot a
/// blocky sliver (2026-11-15).
///
/// **Written on the CPU each frame there are prints** (``update(frameSlot:trail:around:)``), into shared buffers a
/// frame in flight reads from its own slot. The grid's corner is kept to whole cells.
///
/// **What a shader reads**, buffers laid out as follows:
/// - prints: `float4 placed` (x, z, heading in radians — 0 along −z — and side, −1 left, 1 right), `float4 look`
///   (shape, 0 boot or 1 bare; strength 0…1; length; width, metres), `float4 height` (x how high the foot stood);
/// - cells: `uint` — `cellsPerSide² + 1` offsets, then the prints' indices, cell after cell: cell `c`'s prints are
///   indices `cells[offsets + cells[c]] ..< cells[offsets + cells[c + 1]]` with `offsets = cellsPerSide² + 1`;
/// - and ``origin``: the grid's corner, x and z — cell (i, j) covers `origin + (i, j) × cellSize`.
public final class FootprintGrid {

    /// One print as a shader reads it.
    nonisolated struct Instance {
        var placed: SIMD4<Float>
        var look: SIMD4<Float>
        var height: SIMD4<Float>
    }

    /// Metres a cell covers — more than any print is long, so a print touches at most four.
    public nonisolated static let cellSize: Float = 0.5
    /// Metres from the eye to the grid's edge.
    public nonisolated static let halfExtent: Float = 48
    public nonisolated static let cellsPerSide = Int(2 * halfExtent / cellSize)
    /// A print's length and width, metres, by shape.
    public nonisolated static func size(of shape: FootprintTrail.Shape) -> SIMD2<Float> {
        switch shape {
        case .boot: SIMD2(0.30, 0.115)
        case .bare: SIMD2(0.25, 0.10)
        }
    }

    /// The grid's corner as last written, x and z.
    public private(set) var origin = SIMD2<Float>(0, 0)
    /// How many prints the last write holds.
    public private(set) var count = 0

    private let prints: MTLBuffer
    private let cells: MTLBuffer
    private nonisolated static let printStride = MemoryLayout<Instance>.stride
    private nonisolated static let cellCount = cellsPerSide * cellsPerSide
    /// Offsets, then up to four cells' worth of indices a print.
    private nonisolated static let cellWords = cellCount + 1 + FootprintTrail.maximumPrints * 4

    public init(device: MTLDevice) throws {
        let slots = FrameRenderer.maxFramesInFlight
        guard let prints = device.makeBuffer(length: Self.printStride * FootprintTrail.maximumPrints * slots,
                                             options: .storageModeShared),
              let cells = device.makeBuffer(length: 4 * Self.cellWords * slots, options: .storageModeShared) else {
            throw FootprintGridError.couldNotCreate("buffers")
        }
        prints.label = "Footprints"
        cells.label = "Footprint Cells"
        self.prints = prints
        self.cells = cells
    }

    public var allocations: [any MTLAllocation] { [prints, cells] }

    /// Where frame slot `slot`'s prints and cells are, for a shader's argument table.
    public func printsAddress(frameSlot slot: Int) -> UInt64 {
        prints.gpuAddress + UInt64((slot % FrameRenderer.maxFramesInFlight) * Self.printStride * FootprintTrail.maximumPrints)
    }
    public func cellsAddress(frameSlot slot: Int) -> UInt64 {
        cells.gpuAddress + UInt64((slot % FrameRenderer.maxFramesInFlight) * 4 * Self.cellWords)
    }

    /// **Writes the trail's prints round `eye`** into frame slot `frameSlot`'s buffers. Returns how many.
    @discardableResult
    public func update(frameSlot: Int, trail: FootprintTrail, around eye: SIMD3<Float>) -> Int {
        let slot = frameSlot % FrameRenderer.maxFramesInFlight
        let n = Self.cellsPerSide, size = Self.cellSize
        origin = SIMD2(((eye.x - Self.halfExtent) / size).rounded(.down) * size,
                       ((eye.z - Self.halfExtent) / size).rounded(.down) * size)
        let out = prints.contents().advanced(by: slot * Self.printStride * FootprintTrail.maximumPrints)
            .bindMemory(to: Instance.self, capacity: FootprintTrail.maximumPrints)
        // Which cells each print touches: its box, half its length round its middle.
        var touches: [(print: Int32, cell: Int32)] = []
        touches.reserveCapacity(trail.prints.count * 2)
        var kept = 0
        for print in trail.prints where kept < FootprintTrail.maximumPrints {
            let strength = trail.strength(of: print)
            guard strength > 0.01 else { continue }
            let shape = Self.size(of: print.shape)
            let reach = shape.x * 0.55
            let low = (print.position - reach - origin) / size, high = (print.position + reach - origin) / size
            guard high.x >= 0, high.y >= 0, low.x < Float(n), low.y < Float(n) else { continue }
            out[kept] = Instance(placed: SIMD4(print.position.x, print.position.y, print.heading, print.isLeft ? -1 : 1),
                                 look: SIMD4(print.shape == .boot ? 0 : 1, strength, shape.x, shape.y),
                                 height: SIMD4(print.height, 0, 0, 0))
            for j in max(Int(low.y), 0)...min(Int(high.y), n - 1) {
                for i in max(Int(low.x), 0)...min(Int(high.x), n - 1) {
                    touches.append((Int32(kept), Int32(j * n + i)))
                }
            }
            kept += 1
        }
        count = kept
        // Cell after cell: how many each holds, where each starts, then the indices.
        let words = cells.contents().advanced(by: slot * 4 * Self.cellWords)
            .bindMemory(to: UInt32.self, capacity: Self.cellWords)
        let offsets = Self.cellCount + 1
        var perCell = [UInt32](repeating: 0, count: Self.cellCount)
        for touch in touches { perCell[Int(touch.cell)] += 1 }
        var running: UInt32 = 0
        for c in 0..<Self.cellCount {
            words[c] = running
            running += perCell[c]
        }
        words[Self.cellCount] = running
        var next = [UInt32](repeating: 0, count: Self.cellCount)
        for touch in touches {
            let c = Int(touch.cell)
            words[offsets + Int(words[c] + next[c])] = UInt32(touch.print)
            next[c] += 1
        }
        return kept
    }

    /// **How deeply a foot pressed at `point`**, 0…1, from what the last ``update(frameSlot:trail:around:)`` wrote —
    /// the sums a shader does, here for tests and for a game that wants them on the CPU.
    public func press(at point: SIMD3<Float>, frameSlot: Int) -> Float {
        let slot = frameSlot % FrameRenderer.maxFramesInFlight
        let n = Self.cellsPerSide
        let g = (SIMD2(point.x, point.z) - origin) / Self.cellSize
        guard g.x >= 0, g.y >= 0, g.x < Float(n), g.y < Float(n) else { return 0 }
        let c = Int(g.y) * n + Int(g.x)
        let words = cells.contents().advanced(by: slot * 4 * Self.cellWords).bindMemory(to: UInt32.self, capacity: Self.cellWords)
        let instances = prints.contents().advanced(by: slot * Self.printStride * FootprintTrail.maximumPrints)
            .bindMemory(to: Instance.self, capacity: FootprintTrail.maximumPrints)
        let offsets = Self.cellCount + 1
        var deepest: Float = 0
        for k in Int(words[c])..<Int(words[c + 1]) {
            let p = instances[Int(words[offsets + k])]
            guard abs(point.y - p.height.x) < 0.6 else { continue }
            deepest = max(deepest, Self.press(of: p, at: SIMD2(point.x, point.z)))
        }
        return deepest
    }

    /// One print's press at `xz` — what a shader's loop does for each print in the cell.
    nonisolated static func press(of p: Instance, at xz: SIMD2<Float>) -> Float {
        let h = p.placed.z
        let along = SIMD2(sin(h), -cos(h)), across = SIMD2(-along.y, along.x)
        let d = xz - SIMD2(p.placed.x, p.placed.y)
        // In the print's own terms: across (−1…1 of a right foot, mirrored for a left), along (−1 heel … 1 toe).
        let local = SIMD2(simd_dot(d, across) / (p.look.w * 0.5) * p.placed.w, simd_dot(d, along) / (p.look.z * 0.5))
        let shape: FootprintTrail.Shape = p.look.x < 0.5 ? .boot : .bare
        return shape.press(at: local) * p.look.y
    }
}

public nonisolated extension FootprintTrail.Shape {
    /// **How pressed a print of this shape is at `q`**, 0…1, in the print's own terms — across from −1 to 1 of a right
    /// foot (a left one mirrored before asking), along from −1 at the heel to 1 at the toe. **A shader copies these sums**:
    /// A renderer's shader works out the same, term for term.
    func press(at q: SIMD2<Float>) -> Float {
        func inside(_ c: SIMD2<Float>, _ r: SIMD2<Float>) -> Float { 1 - simd_length((q - c) / r) }
        func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        switch self {
        case .boot:
            // A broad sole and a heel with the arch between, the sole's tread in bars.
            let sole = inside(SIMD2(0.05, 0.38), SIMD2(0.95, 0.62))
            let heel = inside(SIMD2(0.0, -0.62), SIMD2(0.78, 0.36))
            let arch = inside(SIMD2(-0.12, -0.1), SIMD2(0.62, 0.42))
            let tread: Float = (q.y + 1) * 5 - ((q.y + 1) * 5).rounded(.down) < 0.5 ? 0.82 : 1.0
            return smooth(0, 0.12, max(max(sole, heel), arch * 0.8)) * tread
        case .bare:
            // The sole narrowing to the heel, and five toes, the big one on the inside.
            let ball = inside(SIMD2(0.05, 0.3), SIMD2(0.85, 0.42))
            let sole = inside(SIMD2(0.2, -0.25), SIMD2(0.55, 0.5))
            let heel = inside(SIMD2(0.05, -0.68), SIMD2(0.6, 0.3))
            var toes: Float = 0
            for i in 0..<5 {
                let x = -0.62 + Float(i) * 0.3
                let r: Float = i == 0 ? 0.24 : 0.17 - Float(i) * 0.012
                toes = max(toes, inside(SIMD2(x, 0.82 - abs(Float(i) - 0.5) * 0.04), SIMD2(r, r * 1.15)))
            }
            return smooth(0, 0.15, max(max(max(ball, sole), heel), toes))
        }
    }
}

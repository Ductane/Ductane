//
//  WorldCopyField.swift
//  Ductane
//

import simd

/// **A scene's scattered copies in square cells, and each frame's choice of which to draw** (2026-10-25).
///
/// A 400 m zone is 48,000 copies — grass, flowers, trees — and testing each against the view, the sun's cascades and
/// its size on screen one by one was 60 ms of every frame in a Debug build: a twitch felt orbiting and
/// walking. Two things fix it, and this is both:
///
/// - **Cells.** Copies are grouped into squares of ``cellSize`` metres; a cell whose largest copy would be under a few
///   pixels from the eye, or which neither the view nor any shadow needs, is passed over whole. Most of a zone is far
///   away most of the time, and its grass is a speck.
/// - **Compiled optimised in every configuration** (this target's `-O`, which `Package.swift` explains): an
///   unoptimised loop over tens of thousands of copies is most of a frame however few survive it. Nothing here calls
///   the engine, for the same reason — an unoptimised call in the inner loop undoes the rest.
///
/// The rule for a single copy is unchanged from the renderer it came out of: drawn when at least
/// ``Settings/smallestDrawn`` pixels across, casting when at least ``Settings/smallestCaster``, into the cascades worth
/// its size and whose stretch of the view its shadow can fall in; its level of detail the coarsest whose error is under
/// half a pixel (`MeshDetail.coarsestTier`).
public nonisolated struct WorldCopyField: Sendable {

    /// One scattered copy, with what does not change frame to frame worked out once.
    public struct Copy: Sendable {
        public var transform: simd_float4x4
        public var minimum: SIMD3<Float>
        public var maximum: SIMD3<Float>
        public var centre: SIMD3<Float>
        public var radius: Float
        public var scale: Float
        /// Which prop it is a copy of: an index the caller keeps.
        public var prop: Int

        public init(transform: simd_float4x4, minimum: SIMD3<Float>, maximum: SIMD3<Float>, scale: Float, prop: Int) {
            self.transform = transform
            self.minimum = minimum
            self.maximum = maximum
            self.centre = (minimum + maximum) / 2
            self.radius = simd_length(maximum - minimum) / 2
            self.scale = scale
            self.prop = prop
        }
    }

    /// A square of the ground and every copy standing in it.
    public struct Cell: Sendable {
        public var minimum: SIMD3<Float>
        public var maximum: SIMD3<Float>
        /// The radius of its largest copy: what decides whether anything in it can be seen from a distance.
        public var largest: Float
        /// Its copies, a run of ``WorldCopyField/copies``.
        public var range: Range<Int>
    }

    public static let defaultCellSize: Float = 16

    public let cellSize: Float
    /// Every copy, cell by cell.
    public let copies: [Copy]
    public let cells: [Cell]
    /// Per prop, its levels' errors in metres, finest first (`MeshDetail`'s) — for a prop whose levels were
    /// made by simplifying it.
    public let errors: [[Float]]
    /// Per prop, the triangles at each of its **own** levels, itself first (a vendor's own lower-detail files); empty for a
    /// prop with none. A prop with its own levels is levelled by size on screen (``ownLevel(triangles:pixels:)``).
    public let triangles: [[Int]]
    /// Per prop, the size on screen in pixels at or under which a copy in view is drawn as its far picture (its impostor,
    /// `ImpostorViews`) — 0, or missing, for a prop with none. Copies casting shadows still cast their meshes.
    public let impostorPixels: [Float]
    /// The level a run of far pictures is given: one past every prop's coarsest mesh level.
    public let impostorLevel: Int

    public init(copies: [Copy], errors: [[Float]], triangles: [[Int]] = [], impostorPixels: [Float] = [],
                cellSize: Float = defaultCellSize) {
        self.cellSize = cellSize
        self.errors = errors
        self.triangles = triangles
        self.impostorPixels = impostorPixels
        impostorLevel = errors.indices.map { prop in
            prop < triangles.count && triangles[prop].count > 1 ? triangles[prop].count - 1 : errors[prop].count
        }.max().map { $0 + 1 } ?? 1
        // Bucketed by the square each copy's centre stands in, then laid out bucket after bucket.
        var buckets: [SIMD2<Int32>: [Int]] = [:]
        for (index, copy) in copies.enumerated() {
            let key = SIMD2<Int32>(Int32((copy.centre.x / cellSize).rounded(.down)), Int32((copy.centre.z / cellSize).rounded(.down)))
            buckets[key, default: []].append(index)
        }
        var ordered: [Copy] = []
        ordered.reserveCapacity(copies.count)
        var cells: [Cell] = []
        cells.reserveCapacity(buckets.count)
        // A stable order — row by row — so the same scene lays out the same way every time.
        for key in buckets.keys.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let start = ordered.count
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity), largest: Float = 0
            for index in buckets[key]! {
                let copy = copies[index]
                ordered.append(copy)
                lo = simd_min(lo, copy.minimum)
                hi = simd_max(hi, copy.maximum)
                largest = max(largest, copy.radius)
            }
            cells.append(Cell(minimum: lo, maximum: hi, largest: largest, range: start..<ordered.count))
        }
        self.copies = ordered
        self.cells = cells
    }

    /// What a frame is drawn from: where the eye is, how big a pixel is, and the view's and the sun's planes.
    public struct Settings: Sendable {
        public var eye: SIMD3<Float>
        /// Screen pixels per radian of view — the viewport's height over the field of view.
        public var pixelsPerRadian: Float
        /// The view's frustum planes, each `(normal, d)` with the inside where `dot(normal, p) + d ≥ 0`.
        public var view: [SIMD4<Float>]
        public var smallestDrawn: Float
        public var smallestCaster: Float
        /// Every level drawn at this one, for looking at a level — or nil to choose by distance.
        public var forcedLevel: Int?
        /// Whether a far copy may be drawn as its prop's far picture — off to compare with the meshes it stands for.
        public var farPictures: Bool
        /// The sun's cascades, nearest first; empty when the sun casts nothing.
        public var cascades: [Cascade]

        public init(eye: SIMD3<Float>, pixelsPerRadian: Float, view: [SIMD4<Float>], smallestDrawn: Float,
                    smallestCaster: Float, forcedLevel: Int? = nil, farPictures: Bool = true, cascades: [Cascade] = []) {
            self.eye = eye
            self.pixelsPerRadian = pixelsPerRadian
            self.view = view
            self.smallestDrawn = smallestDrawn
            self.smallestCaster = smallestCaster
            self.forcedLevel = forcedLevel
            self.farPictures = farPictures
            self.cascades = cascades
        }
    }

    /// One of the sun's cascades: its planes, the stretch of view depth it is sampled over, and its texel's size.
    ///
    /// **Or the weather's cover** (`isCover`, 2026-11-15): what is overhead round the eye, seen from straight above, for
    /// rain to keep out from under. It takes every copy that casts and that it can see, at the copy's own level, and does
    /// not count toward which of the sun's cascades a copy is worth — so drawing it changes no shadow.
    public struct Cascade: Sendable {
        public var planes: [SIMD4<Float>]
        public var start: Float
        public var end: Float
        public var texelSize: Float
        public var isCover: Bool

        public init(planes: [SIMD4<Float>], start: Float, end: Float, texelSize: Float, isCover: Bool = false) {
            self.planes = planes
            self.start = start
            self.end = end
            self.texelSize = texelSize
            self.isCover = isCover
        }
    }

    /// Copies to draw in one pass, grouped: every transform of a run together, run after run.
    public struct Runs: Sendable {
        public struct Run: Sendable, Equatable {
            public let prop: Int
            public let level: Int
            public let start: Int
            public let count: Int
        }
        public var transforms: [simd_float4x4] = []
        public var runs: [Run] = []
        public var isEmpty: Bool { transforms.isEmpty }
        public init() {}
    }

    /// What a frame draws: the copies in view, and per cascade the copies casting into it.
    public struct Selection: Sendable {
        public var visible = Runs()
        public var cascades: [Runs] = []
        /// How many cells were looked inside, of how many — for the timing check.
        public var cellsOpened = 0
        public init() {}
    }

    /// **The copies this frame draws and casts**, grouped by prop and level.
    public func select(_ settings: Settings) -> Selection {
        // One slot more than any prop's levels: the far pictures' (``impostorLevel``).
        let levelSlots = impostorLevel + 1
        let bucketCount = errors.count * levelSlots
        var visible = [[simd_float4x4]](repeating: [], count: bucketCount)
        var cascadeBuckets = [[[simd_float4x4]]](repeating: [[simd_float4x4]](repeating: [], count: bucketCount),
                                                 count: settings.cascades.count)
        let casting = !settings.cascades.isEmpty
        let texels = settings.cascades.filter { !$0.isCover }.map(\.texelSize)
        var opened = 0

        for cell in cells {
            // The largest copy's size on screen as near as any copy in it can be: none in it can be bigger. A copy is
            // measured from its centre less its radius, and its centre is in the cell — so at least the cell's nearest
            // point less the largest radius away.
            let nearest = simd_distance(settings.eye, simd_clamp(settings.eye, cell.minimum, cell.maximum))
            let biggest = 2 * cell.largest * settings.pixelsPerRadian / max(nearest - cell.largest, 0.5)
            guard biggest >= settings.smallestDrawn || settings.forcedLevel != nil else { continue }
            let cellCasts = casting && biggest >= settings.smallestCaster
            let cellInView = Self.mayIntersect(settings.view, cell.minimum, cell.maximum)
            guard cellInView || cellCasts else { continue }
            opened += 1

            for index in cell.range {
                let copy = copies[index]
                let centre = simd_distance(settings.eye, copy.centre)
                let pixels = 2 * copy.radius * settings.pixelsPerRadian / max(centre - copy.radius, 0.5)
                guard pixels >= settings.smallestDrawn || settings.forcedLevel != nil else { continue }
                let casts = cellCasts && pixels >= settings.smallestCaster
                let inView = cellInView && Self.mayIntersect(settings.view, copy.minimum, copy.maximum)
                guard inView || casts else { continue }
                let errors = self.errors[copy.prop]
                let own = copy.prop < triangles.count && triangles[copy.prop].count > 1
                let level = settings.forcedLevel.map { min($0, levelCount(of: copy.prop, errors: errors)) }
                    ?? (own ? Self.ownLevel(triangles: triangles[copy.prop], pixels: pixels)
                            : Self.coarsestTier(errors: errors, distance: centre - copy.radius, scale: copy.scale,
                                                pixelsPerRadian: settings.pixelsPerRadian))
                let bucket = copy.prop * levelSlots + level
                if inView {
                    // **Small enough, it is drawn as its far picture** (2026-11-01) — never when a level is being looked at.
                    let picture = settings.farPictures && settings.forcedLevel == nil && copy.prop < impostorPixels.count
                        && impostorPixels[copy.prop] > 0 && pixels <= impostorPixels[copy.prop]
                    visible[picture ? copy.prop * levelSlots + impostorLevel : bucket].append(copy.transform)
                }
                guard casts else { continue }
                // Into the cascades worth its size, whose stretch of view its shadow can fall in — from its near side to
                // a long evening shadow past its far side — and which can see it.
                let count = Self.cascadeCount(forSize: 2 * copy.radius, texels: texels)
                let near = centre - copy.radius, far = centre + copy.radius * 9
                // **A level coarser for each cascade further out**, as far as the prop has levels: a far cascade's texel is
                // tens of centimetres, and a tree's every leaf card in it was a third of the shadow pass for a shadow that
                // looks the same. Not when a level is being looked at.
                //
                // **And past the nearest, no finer than the cascade's texels can show** (2026-10-26): a copy's size in
                // texels chooses a level as its size in pixels does on screen, and the coarser of the two is cast. 1.3 ms
                // of a wooded zone's worst near-ground frame at 2900×2200. The nearest cascade keeps the view's level, so
                // a tree's own leaves are shadowed by the same leaves that are drawn.
                let coarsest = levelCount(of: copy.prop, errors: errors)
                for (c, cascade) in settings.cascades.enumerated() where c < count || cascade.isCover {
                    guard near <= cascade.end, far >= cascade.start,
                          Self.mayIntersect(cascade.planes, copy.minimum, copy.maximum) else { continue }
                    if cascade.isCover {
                        cascadeBuckets[c][bucket].append(copy.transform)
                        continue
                    }
                    var castLevel = settings.forcedLevel == nil ? min(level + c, coarsest) : level
                    if settings.forcedLevel == nil, c > 0 {
                        let byTexel = own
                            ? Self.ownLevel(triangles: triangles[copy.prop], pixels: 2 * copy.radius / cascade.texelSize)
                            : Self.coarsestTier(errors: errors, distance: 1, scale: copy.scale,
                                                pixelsPerRadian: 1 / cascade.texelSize)
                        castLevel = max(castLevel, byTexel)
                    }
                    cascadeBuckets[c][copy.prop * levelSlots + castLevel].append(copy.transform)
                }
            }
        }

        func runs(_ buckets: [[simd_float4x4]]) -> Runs {
            var out = Runs()
            out.transforms.reserveCapacity(buckets.reduce(0) { $0 + $1.count })
            for (bucket, transforms) in buckets.enumerated() where !transforms.isEmpty {
                out.runs.append(Runs.Run(prop: bucket / levelSlots, level: bucket % levelSlots, start: out.transforms.count,
                                         count: transforms.count))
                out.transforms.append(contentsOf: transforms)
            }
            return out
        }
        var selection = Selection()
        selection.visible = runs(visible)
        selection.cascades = cascadeBuckets.map(runs)
        selection.cellsOpened = opened
        return selection
    }

    /// How many coarser levels a prop has: its own, or those made by simplifying it.
    private func levelCount(of prop: Int, errors: [Float]) -> Int {
        prop < triangles.count && triangles[prop].count > 1 ? triangles[prop].count - 1 : errors.count
    }

    /// Square pixels of a copy's size on screen per triangle drawn, at most — what a prop's own levels are chosen by.
    public static let pixelsPerTriangle: Float = 16

    /// **The level of a prop's own to draw a copy at**: the finest whose triangles fit one per ``pixelsPerTriangle``
    /// square pixels of the copy's size on screen, `pixels` across — else the coarsest. A level with no triangles is
    /// never chosen: a vendor's last level is sometimes an empty stand-in, and a tree that vanishes is worse than one
    /// drawn simply. (An engine importing the same pack may use the pack's own switch points; its FBX does not carry them.)
    public static func ownLevel(triangles: [Int], pixels: Float) -> Int {
        let budget = pixels * pixels / pixelsPerTriangle
        var coarsest = 0
        for (level, count) in triangles.enumerated() where count > 0 {
            if Float(count) <= budget { return level }
            coarsest = level
        }
        return coarsest
    }

    /// Whether any of a box is on the inside of every plane — Ductane's `Frustum.mayIntersect`, here so the loop
    /// does not leave this optimised module.
    @inline(__always)
    static func mayIntersect(_ planes: [SIMD4<Float>], _ minimum: SIMD3<Float>, _ maximum: SIMD3<Float>) -> Bool {
        for plane in planes {
            let normal = SIMD3(plane.x, plane.y, plane.z)
            let positive = minimum.replacing(with: maximum, where: normal .>= 0)
            if simd_dot(normal, positive) + plane.w < 0 { return false }
        }
        return true
    }

    /// Ductane's `MeshDetail.coarsestTier`: the coarsest level whose error is under half a pixel.
    @inline(__always)
    static func coarsestTier(errors: [Float], distance: Float, scale: Float, pixelsPerRadian: Float) -> Int {
        guard distance > 0 else { return 0 }
        var chosen = 0
        for (index, error) in errors.enumerated() {
            guard error * scale / distance * pixelsPerRadian < 0.5 else { break }
            chosen = index + 1
        }
        return chosen
    }

    /// Ductane's `ShadowCascades.cascadeCount(forCasterOfSize:)`: the cascades whose texel is at most a third of
    /// the caster, and always the nearest.
    @inline(__always)
    static func cascadeCount(forSize size: Float, texels: [Float]) -> Int {
        var count = 0
        for (index, texel) in texels.enumerated() where texel <= size / 3 { count = index + 1 }
        return max(1, count)
    }
}

//
//  WaymarkScan.swift
//  Ductane
//

import Foundation
import Metal
import simd

// MARK: How a scan looks

public nonisolated extension Waymark.Look {

    /// **How a scan looks and how long it takes** (``WaymarkScan``): the ring sweeping out from the player, the outline
    /// round each thing it passes, and the icon over it with its distance. Read with every key optional, as the rest of
    /// the look is.
    struct Scan: Sendable, Equatable, Codable {
        /// Whether a waymark sends one out at all.
        public var isOn: Bool
        /// **How far the ring reaches**, meters.
        public var reach: Float
        /// Meters a second the ring travels — 50 m in about a second by default.
        public var speed: Float
        /// **Seconds a thing stays outlined** once the ring has reached it, its fade included.
        public var holds: Float
        /// Seconds its icon stays after its outline has gone, so it can still be walked to.
        public var iconLinger: Float
        /// The ring's and the outlines' colour, linear.
        public var color: SIMD3<Float>
        /// What the colour is multiplied by into the scene's light: above 1, it glows.
        public var intensity: Float
        /// How wide the ring is where it runs over the ground, meters.
        public var ringWidth: Float
        /// How far the ring's glow spreads, 0 none to 1 its width again on each side.
        public var glow: Float
        /// How wide an outline is, pixels.
        public var outlineWidth: Float
        /// How big an icon is on screen, pixels.
        public var iconSize: Float
        /// Whether each icon shows how far off its thing is.
        public var showsDistance: Bool

        public init(isOn: Bool = true, reach: Float = 50, speed: Float = 50, holds: Float = 6, iconLinger: Float = 2,
                    color: SIMD3<Float> = SIMD3(0.25, 0.8, 1), intensity: Float = 2, ringWidth: Float = 1.2,
                    glow: Float = 0.6, outlineWidth: Float = 3, iconSize: Float = 30, showsDistance: Bool = true) {
            self.isOn = isOn
            self.reach = simd_clamp(reach, 2, 1_000)
            self.speed = simd_clamp(speed, 1, 1_000)
            self.holds = max(holds, 0.5)
            self.iconLinger = max(iconLinger, 0)
            self.color = simd_max(color, .zero)
            self.intensity = max(intensity, 0)
            self.ringWidth = max(ringWidth, 0.05)
            self.glow = simd_clamp(glow, 0, 1)
            self.outlineWidth = simd_clamp(outlineWidth, 1, 12)
            self.iconSize = simd_clamp(iconSize, 12, 96)
            self.showsDistance = showsDistance
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Scan()
            self.init(isOn: (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? d.isOn,
                      reach: (try? c.decodeIfPresent(Float.self, forKey: .reach)) ?? d.reach,
                      speed: (try? c.decodeIfPresent(Float.self, forKey: .speed)) ?? d.speed,
                      holds: (try? c.decodeIfPresent(Float.self, forKey: .holds)) ?? d.holds,
                      iconLinger: (try? c.decodeIfPresent(Float.self, forKey: .iconLinger)) ?? d.iconLinger,
                      color: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .color)) ?? d.color,
                      intensity: (try? c.decodeIfPresent(Float.self, forKey: .intensity)) ?? d.intensity,
                      ringWidth: (try? c.decodeIfPresent(Float.self, forKey: .ringWidth)) ?? d.ringWidth,
                      glow: (try? c.decodeIfPresent(Float.self, forKey: .glow)) ?? d.glow,
                      outlineWidth: (try? c.decodeIfPresent(Float.self, forKey: .outlineWidth)) ?? d.outlineWidth,
                      iconSize: (try? c.decodeIfPresent(Float.self, forKey: .iconSize)) ?? d.iconSize,
                      showsDistance: (try? c.decodeIfPresent(Bool.self, forKey: .showsDistance)) ?? d.showsDistance)
        }

        /// Seconds the ring takes to reach its end.
        public var travel: Float { reach / speed }
    }

    /// **The icon a scan labels a thing with** — drawn, not loaded, so nothing need be shipped for it.
    enum Icon: String, Sendable, Codable, CaseIterable {
        case diamond, circle, star, exclamation, question, cross, crate, crosshair, door, pin
    }

    /// **What one kind of place looks like**: its icon, the colour of a path leading to it and of its icon, and whether
    /// the scene's markers of that kind are found by a scan.
    struct Kind: Sendable, Equatable, Codable {
        public var icon: Icon
        /// Linear; nil takes the line's colour for a path and the scan's for an icon.
        public var color: SIMD3<Float>?
        /// **Whether a world's markers of this kind are found by a scan** — the editor's tag; a game's own things are
        /// registered whatever this says.
        public var markers: Bool

        public init(icon: Icon = .diamond, color: SIMD3<Float>? = nil, markers: Bool = false) {
            self.icon = icon
            self.color = color.map { simd_max($0, .zero) }
            self.markers = markers
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(icon: (try? c.decodeIfPresent(Icon.self, forKey: .icon)) ?? .diamond,
                      color: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .color)) ?? nil,
                      markers: (try? c.decodeIfPresent(Bool.self, forKey: .markers)) ?? false)
        }
    }

    /// **The kinds every look starts with**: a mission's objective in yellow, a player's own ping in white, collectibles,
    /// loot and enemies — the names a game uses unless it has its own.
    static let defaultKinds: [String: Kind] = [
        "objective": Kind(icon: .exclamation, color: SIMD3(1, 0.62, 0.05)),
        "ping": Kind(icon: .diamond, color: SIMD3(1, 1, 1)),
        "collectible": Kind(icon: .star, color: SIMD3(0.35, 0.75, 1)),
        "loot": Kind(icon: .crate, color: SIMD3(0.35, 1, 0.3)),
        "enemy": Kind(icon: .crosshair, color: SIMD3(1, 0.12, 0.08)),
    ]

    /// **A kind by its name, in any case** — the default kind (a diamond, no colour of its own) for one not listed.
    func kind(_ name: String?) -> Kind {
        name.flatMap { kinds[$0.lowercased()] } ?? Kind()
    }

    /// **The look of a path leading to a place of `kind`**: the line in that kind's colour; the look itself for nil or
    /// a kind with no colour.
    func leading(to kind: String?) -> Waymark.Look {
        guard let colour = self.kind(kind).color else { return self }
        var look = self
        look.color = colour
        return look
    }

    /// **An icon's colour for `kind`**: its own, else the scan's.
    func iconColor(_ kind: String) -> SIMD3<Float> { self.kind(kind).color ?? scan.color }
}

// MARK: What a scan can find

/// **One thing a scan can find**: what kind it is, where it is, how high over that its icon floats, and what shape to
/// outline. A world's own (``Findables/inWorld(_:propURL:propBounds:)``) and a game's (``Findables``) are found alike.
public nonisolated struct Findable: Sendable, Equatable {

    public struct ID: Hashable, Sendable {
        public let raw: Int
        public init(_ raw: Int) { self.raw = raw }
    }

    /// **The shape outlined round it**, seen through walls.
    public enum Outline: Sendable, Equatable {
        /// Only its icon.
        case none
        /// A prop file at a transform — what ``WorldRenderer`` draws and can outline itself.
        case prop(URL, simd_float4x4)
        /// Triangles a game draws itself (``MaskDraw``) — a skinned figure posed this frame, a prop of its own renderer.
        case meshes([MaskDraw])
    }

    /// **Triangles to outline**, from vertices a game already has on the GPU: positions as three floats at the start of
    /// each vertex, `stride` bytes apart — the engine's own layout puts them there — indexed as the game draws them.
    /// Kept current by the game each frame (``Findables/move(_:to:outline:)``), since a posed figure's vertices are a
    /// different buffer every frame in flight.
    public struct MaskDraw: Sendable, Equatable {
        public var vertices: UInt64
        public var stride: Int
        public var indices: UInt64
        public var indexCount: Int
        public var indexType: MTLIndexType
        public var transform: simd_float4x4
        public init(vertices: UInt64, stride: Int = 32, indices: UInt64, indexCount: Int, indexType: MTLIndexType,
                    transform: simd_float4x4 = matrix_identity_float4x4) {
            self.vertices = vertices
            self.stride = stride
            self.indices = indices
            self.indexCount = indexCount
            self.indexType = indexType
            self.transform = transform
        }
    }

    public var id: ID
    public var kind: String
    public var position: SIMD3<Float>
    /// Meters over ``position`` its icon floats.
    public var top: Float
    public var outline: Outline

    public init(id: ID, kind: String, position: SIMD3<Float>, top: Float = 1, outline: Outline = .none) {
        self.id = id
        self.kind = kind
        self.position = position
        self.top = top
        self.outline = outline
    }

    /// Where its icon stands.
    public var iconPosition: SIMD3<Float> { position + SIMD3(0, top, 0) }
}

/// **A game's things a scan can find**, registered by kind — Unity's and Unreal's "scannable" component: added when one
/// appears, moved as it moves, removed when it is gone. The scan finds, outlines and labels them; their icons and
/// colours are the world's (``Waymark/Look/kinds``).
public nonisolated struct Findables: Sendable {
    private var items: [Findable.ID: Findable] = [:]
    private var order: [Findable.ID] = []
    private var next = 1

    public init() {}

    /// Adds one; its id is what moves and removes it.
    @discardableResult
    public mutating func add(kind: String, at position: SIMD3<Float>, top: Float = 1,
                             outline: Findable.Outline = .none) -> Findable.ID {
        let id = Findable.ID(next)
        next += 1
        items[id] = Findable(id: id, kind: kind, position: position, top: top, outline: outline)
        order.append(id)
        return id
    }

    /// Moves one, and changes what is outlined when `outline` is given. One that is gone is left alone.
    public mutating func move(_ id: Findable.ID, to position: SIMD3<Float>, outline: Findable.Outline? = nil) {
        guard var item = items[id] else { return }
        item.position = position
        if let outline { item.outline = outline }
        items[id] = item
    }

    public mutating func remove(_ id: Findable.ID) {
        guard items.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
    }

    public mutating func removeAll() {
        items.removeAll()
        order.removeAll()
    }

    public subscript(id: Findable.ID) -> Findable? { items[id] }
    public var count: Int { items.count }
    /// Every one, in the order added.
    public var all: [Findable] { order.compactMap { items[$0] } }

    /// **What a world's author tagged to be found**: its markers of every kind whose ``Waymark/Look/Kind/markers`` is on,
    /// and its placements of every prop in ``WorldFile/found``, outlined as that prop. Their ids are negative, so they
    /// never meet a game's.
    ///
    /// - Parameters:
    ///   - propURL: where a prop's file is, by its index — ``WorldPackage/propURL(_:)``.
    ///   - propBounds: a prop's box in its own space, for its icon to float over; nil floats it a meter and a half up.
    public static func inWorld(_ world: WorldFile, propURL: (Int) -> URL,
                               propBounds: (URL) -> BoundingBox? = { _ in nil }) -> [Findable] {
        let look = world.waymark ?? Waymark.Look()
        var out: [Findable] = []
        for (i, marker) in world.markers.enumerated() where look.kind(marker.kind).markers {
            out.append(Findable(id: Findable.ID(-1 - i), kind: marker.kind, position: marker.position, top: 1.5))
        }
        for (i, placement) in world.placements.enumerated() {
            guard let kind = world.found[placement.prop] else { continue }
            let url = propURL(placement.prop)
            let transform = placement.transform
            out.append(Findable(id: Findable.ID(-1_000_000 - i), kind: kind, position: placement.position,
                                top: Self.top(of: propBounds(url), transform: transform),
                                outline: .prop(url, transform)))
        }
        return out
    }

    /// Meters from a placement's origin to half a meter over its box's top.
    public static func top(of bounds: BoundingBox?, transform: simd_float4x4) -> Float {
        guard let bounds else { return 1.5 }
        let box = bounds.transformed(by: transform)
        return max(box.maximum.y - transform.columns.3.y + 0.5, 0.5)
    }
}

// MARK: A scan

/// **A scan sent out from where a player stands**: a ring sweeping out over the ground to its reach, and every thing it
/// passes outlined, seen through walls, with an icon and its distance over it for a few seconds — the icon a little
/// longer, so it can be walked to. Borderlands' ECHO scan, The Division's pulse, Destiny's Ghost.
///
/// **What it finds is what the world tags plus what the game registers** (``Findables``): a thing is found when the ring
/// reaches where it is, and shown where it is from then on, moving or not. One added after the ring passed it is not.
///
/// **A value with no GPU in it**, as ``Waymark`` is: a game steps it and ``WaymarkScanRenderer`` draws it.
public nonisolated struct WaymarkScan: Sendable {

    /// **One found thing as it shows now**: how much of its outline and of its icon, and how far it is from the viewer.
    public struct Shown: Sendable, Equatable {
        public var findable: Findable
        public var outline: Float
        public var icon: Float
        public var distance: Float
    }

    public let origin: SIMD3<Float>
    public let look: Waymark.Look
    /// Seconds since it was sent out.
    public private(set) var age: Float = 0
    /// When the ring reached each thing it has found, by its age then.
    public private(set) var found: [Findable.ID: Float] = [:]

    /// Seconds an outline and an icon take to come in, and to fade at their end.
    public static let fade: (in: Float, out: Float) = (0.15, 0.6)

    public init(from origin: SIMD3<Float>, look: Waymark.Look = Waymark.Look()) {
        self.origin = origin
        self.look = look
    }

    /// **How far the ring has reached**, meters across the ground.
    public var front: Float { min(age * look.scan.speed, look.scan.reach) }

    /// The ring's opacity: full as it sets out, fading over the last third of its reach, gone once it is there.
    public var ringOpacity: Float {
        let t = age / look.scan.travel
        return t >= 1 ? 0 : 1 - simd_smoothstep(0.66, 1, t)
    }

    /// Whether nothing of it shows any more: the ring has gone and every found thing's icon with it.
    public var isOver: Bool {
        let last = found.values.max() ?? 0
        return age >= look.scan.travel && age >= last + look.scan.holds + look.scan.iconLinger
    }

    /// Steps it on and finds what the ring passes over among `findables`, measured across the ground from where it set out.
    public mutating func step(deltaTime: Float, findables: [Findable]) {
        // **Found as the ring crosses it**: between where the ring was and where it is now — so one added behind it, or
        // that walked in behind it, is not.
        let before = age == 0 ? -1 : self.front
        age += max(deltaTime, 0)
        let front = self.front
        for item in findables where found[item.id] == nil {
            let away = simd_distance(SIMD2(item.position.x, item.position.z), SIMD2(origin.x, origin.z))
            if away > before && away <= front { found[item.id] = min(age, away / look.scan.speed) }
        }
    }

    /// **The found things as they show now**, among `findables` — one that is gone shows no more — with their distance
    /// from `viewer`.
    public func shown(_ findables: [Findable], from viewer: SIMD3<Float>) -> [Shown] {
        let scan = look.scan
        var out: [Shown] = []
        for item in findables {
            guard let at = found[item.id] else { continue }
            let since = age - at
            let fadeIn = simd_clamp(since / Self.fade.in, 0, 1)
            let outline = fadeIn * simd_clamp((scan.holds - since) / Self.fade.out, 0, 1)
            let icon = fadeIn * simd_clamp((scan.holds + scan.iconLinger - since) / Self.fade.out, 0, 1)
            guard icon > 0 else { continue }
            out.append(Shown(findable: item, outline: outline, icon: icon, distance: simd_distance(item.position, viewer)))
        }
        return out
    }

    /// **Where the ring runs over the ground**: `count` points round it at ``front``, each on `surface`.
    public func ring(count: Int = 160, surface: (SIMD2<Float>) -> Float) -> [SIMD3<Float>] {
        let r = front
        return (0..<count).map { i in
            let a = Float(i) / Float(count) * 2 * .pi
            let x = origin.x + cos(a) * r, z = origin.z + sin(a) * r
            return SIMD3(x, surface(SIMD2(x, z)), z)
        }
    }
}

//
//  FallColors.swift
//  Ductane
//

import Foundation
import simd

/// **Foliage through the year** (2026-11-16): through autumn every tree turns at its own pace and to its own colour —
/// yellow, orange, red — and grass goes straw; late in autumn the leaves thin until broadleaf trees stand bare, a carpet
/// of leaves gathers under them, and in spring they green again. The standard set: Unity's Vegetation Engine and Unreal's
/// Ultra Dynamic Weather tint a pack's own leaves by the season rather than asking for autumn textures nobody ships.
///
/// **Run by a world's calendar** (``WorldClock/foliage``): ``phase(yearPosition:southern:)`` from the clock's place in the
/// year, the rest from the phase and each tree's own numbers (``seed(x:z:)``), so every player sees the same wood on the
/// same day. A renderer copies ``turn(phase:timing:)``, ``leaves(phase:timing:)``, ``brown(phase:timing:)``,
/// ``straw(phase:timing:)`` and ``litter(phase:)`` term for term; which props take part is ``Foliage``.
public nonisolated struct FallColors: Sendable, Equatable, Codable {

    /// **The colours trees turn to**, three each — a tree takes one of them or a blend of two.
    public enum Palette: String, Sendable, Codable, CaseIterable {
        /// Yellow, orange and red together — a mixed broadleaf wood.
        case mixed
        /// Yellows and ambers — birch, aspen, beech.
        case golden
        /// Oranges and reds — a maple valley.
        case fiery
        /// Three colours of the scene's own (``FallColors/custom``).
        case custom

        /// Its three colours, linear: what a leaf's own colour is turned toward. Custom's are the scene's.
        public var colours: [SIMD3<Float>] {
            switch self {
            case .mixed: [SIMD3(0.80, 0.52, 0.05), SIMD3(0.76, 0.26, 0.03), SIMD3(0.52, 0.06, 0.03)]
            case .golden: [SIMD3(0.86, 0.66, 0.10), SIMD3(0.80, 0.47, 0.05), SIMD3(0.62, 0.36, 0.05)]
            case .fiery: [SIMD3(0.80, 0.30, 0.03), SIMD3(0.62, 0.08, 0.03), SIMD3(0.40, 0.03, 0.04)]
            case .custom: Palette.mixed.colours
            }
        }
    }

    public var palette: Palette
    /// The scene's own three colours, linear — used when the palette is ``Palette/custom``.
    public var custom: [SIMD3<Float>]
    /// **How far the turning goes**, 0 none (leaves stay green) … 1 full colour.
    public var extent: Float
    /// **Whether broadleaf trees stand bare through winter.** Off, they keep their leaves, gone brown — as some oaks do.
    public var bareInWinter: Bool

    public init(palette: Palette = .mixed, custom: [SIMD3<Float>] = Palette.mixed.colours, extent: Float = 1,
                bareInWinter: Bool = true) {
        self.palette = palette
        let finite = custom.count == 3 && custom.allSatisfy { all($0 .>= 0) && all($0 .<= 1) }
        self.custom = finite ? custom : Palette.mixed.colours
        self.extent = extent.isFinite ? min(max(extent, 0), 1) : 1
        self.bareInWinter = bareInWinter
    }

    /// The three colours trees turn to.
    public var colours: [SIMD3<Float>] { palette == .custom ? custom : palette.colours }

    /// **A turned leaf's colour once winter has had it** — what a tree that keeps its leaves goes to, and old litter.
    public static let brownColour = SIMD3<Float>(0.30, 0.15, 0.05)
    /// **Grass gone to straw.**
    public static let strawColour = SIMD3<Float>(0.62, 0.48, 0.22)

    // MARK: The year

    /// **Where foliage is in its year**, 0…4 from midsummer: 1 the middle of autumn, 2 of winter, 3 of spring — from a
    /// clock's ``WorldClock/yearPosition(at:)`` (0 midwinter on the northern calendar), half a year on south of the equator.
    public static func phase(yearPosition: Double, southern: Bool) -> Float {
        let local = (yearPosition.isFinite ? yearPosition : 2) + (southern ? 2 : 0)
        let t = (local - 2) / 4
        return Float((t - t.rounded(.down)) * 4)
    }

    /// **A tree's own two numbers, 0…1, from where it stands**: how early or late it turns, and which colour it takes.
    /// An integer hash of its place to a quarter metre, so a renderer's copy gives the same numbers bit for bit.
    public static func seed(x: Float, z: Float) -> (timing: Float, pick: Float) {
        // **Never traps**: a place comes from a world file anyone can write, so a NaN, an infinity or a number past what an
        // `Int32` holds is clamped first — a GPU's float-to-int conversion saturates the same way.
        func quarter(_ v: Float) -> UInt32 {
            guard v.isFinite else { return 0 }
            let q = min(max((v * 4).rounded(.down), Float(Int32.min)), Float(Int32.max) - 128)
            return UInt32(bitPattern: Int32(q))
        }
        let qx = quarter(x), qz = quarter(z)
        var h = (qx &* 73_856_093) ^ (qz &* 19_349_663)
        h = h &* 747_796_405 &+ 2_891_336_453
        h = ((h >> ((h >> 28) &+ 4)) ^ h) &* 277_803_737
        h = (h >> 22) ^ h
        return (Float(h & 0xFFFF) / 65_535, Float(h >> 16) / 65_535)
    }

    /// How far a tree's own timing moves its year, in the phase's units: ±0.18 — some turn a week early, some late.
    public static let timingSpread: Float = 0.36

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// **Whether the season changes any foliage at `phase`** — false through high summer, before the earliest tree begins
    /// to turn and after the latest has greened, so a renderer can leave foliage alone.
    public static func changesAnything(phase: Float) -> Bool {
        phase > 0.45 - timingSpread / 2 && phase < 3.1 + timingSpread / 2
    }

    /// The phase a tree with this `timing` is at.
    static func local(_ phase: Float, _ timing: Float) -> Float { phase + (timing - 0.5) * timingSpread }

    /// **How turned a tree's leaves are**, 0 green … ``extent``: from late summer to the middle of autumn, back to green as
    /// new leaves come in spring.
    public func turn(phase: Float, timing: Float) -> Float {
        let t = Self.local(phase, timing)
        return Self.smoothstep(0.45, 1.15, t) * (1 - Self.smoothstep(2.55, 2.85, t)) * extent
    }

    /// **How much of a tree's leaves it still has**, 1 all … 0 bare: thinning from the middle of autumn to the start of
    /// winter, coming back through early spring. Always 1 when trees keep their leaves.
    public func leaves(phase: Float, timing: Float) -> Float {
        guard bareInWinter else { return 1 }
        let t = Self.local(phase, timing)
        return min(max(1 - Self.smoothstep(1.15, 1.75, t) + Self.smoothstep(2.6, 3.0, t), 0), 1)
    }

    /// **How far turned leaves have gone brown**, 0…1 — through winter on a tree that keeps them.
    public func brown(phase: Float, timing: Float) -> Float {
        let t = Self.local(phase, timing)
        return Self.smoothstep(1.3, 1.9, t) * (1 - Self.smoothstep(2.55, 2.85, t))
    }

    /// **How far grass has gone to straw**, 0…``extent``: from late summer into autumn, all winter, green again in spring.
    public func straw(phase: Float, timing: Float) -> Float {
        let t = Self.local(phase, timing)
        return Self.smoothstep(0.6, 1.3, t) * (1 - Self.smoothstep(2.7, 3.1, t)) * extent
    }

    /// **How thick fallen leaves lie under a turning tree**, 0…1: gathering as the trees shed, fading through winter. Half
    /// as thick when trees keep their leaves — a few fall regardless.
    public func litter(phase: Float) -> Float {
        let shed = Self.smoothstep(1.1, 1.7, phase) * (1 - Self.smoothstep(2.3, 2.9, phase))
        return shed * (bareInWinter ? 1 : 0.5) * max(extent, 0.3)
    }

    /// **How far fallen leaves have gone brown**, 0…1 — through the depth of winter.
    public static func litterBrown(phase: Float) -> Float { smoothstep(1.6, 2.3, phase) }

    /// **How hard leaves fall**, 0…1 — a scene's falling-leaf effects thicken by it while trees shed.
    public func shedding(phase: Float) -> Float {
        guard bareInWinter else { return 0.3 * Self.smoothstep(0.8, 1.3, phase) * (1 - Self.smoothstep(1.6, 2.0, phase)) }
        return Self.smoothstep(0.8, 1.25, phase) * (1 - Self.smoothstep(1.6, 1.95, phase))
    }

    /// **What a scene's falling leaves do at `phase`**: how many times their authored rate they fall — thicker while trees
    /// shed, a few through a bare winter — and whether they wear their autumn look. A renderer applies it to its
    /// falling-leaf effects, whatever it calls them.
    public func leafFall(phase: Float) -> (rate: Float, turned: Bool) {
        let leaves = self.leaves(phase: phase, timing: 0.5)
        let rate = max(0.15, leaves) + 4 * shedding(phase: phase)
        return (rate, turn(phase: phase, timing: 0.5) > 0.4 * max(extent, 0.01) || (leaves < 0.5 && extent > 0))
    }

    /// **The colour a tree turns to**, from its ``seed(x:z:)`` pick: between the palette's first and second colours for the
    /// lower half, the second and third for the upper.
    public func colour(pick: Float) -> SIMD3<Float> {
        let c = colours, p = min(max(pick, 0), 1) * 2
        return p < 1 ? simd_mix(c[0], c[1], SIMD3(repeating: p)) : simd_mix(c[1], c[2], SIMD3(repeating: p - 1))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case palette, custom, extent, bareInWinter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FallColors()
        let palette = ((try? c.decodeIfPresent(String.self, forKey: .palette)) ?? nil).flatMap(Palette.init) ?? d.palette
        var custom = d.custom
        if let flat = (try? c.decodeIfPresent([Float].self, forKey: .custom)) ?? nil, flat.count == 9 {
            custom = (0..<3).map { SIMD3(flat[$0 * 3], flat[$0 * 3 + 1], flat[$0 * 3 + 2]) }
        }
        self.init(palette: palette, custom: custom,
                  extent: (try? c.decodeIfPresent(Float.self, forKey: .extent)) ?? d.extent,
                  bareInWinter: (try? c.decodeIfPresent(Bool.self, forKey: .bareInWinter)) ?? d.bareInWinter)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(palette.rawValue, forKey: .palette)
        try c.encode(custom.flatMap { [$0.x, $0.y, $0.z] }, forKey: .custom)
        try c.encode(extent, forKey: .extent)
        try c.encode(bareInWinter, forKey: .bareInWinter)
    }
}

/// **What a prop does through the year** (2026-11-16) — which parts of a scene ``FallColors`` changes.
///
/// **Guessed from the prop's name** (``guess(name:)``) and set per prop where the guess is wrong: an editor keeps the
/// answer, and a world file carries it (``WorldFile/foliage``). On a prop only its leaves change — a cut-out leaf, or the
/// green of a solid canopy — never its bark.
public nonisolated enum Foliage: String, Sendable, Codable, CaseIterable {
    /// A broadleaf tree or bush: turns in autumn, bare in winter.
    case turns
    /// Green all year: pine, fir, palm, cactus.
    case evergreen
    /// Grass, reeds: straw from autumn to spring.
    case grass
    /// Not foliage, or foliage that does not change: a rock, a wall, a dead tree.
    case unchanged

    /// Whether the season changes it at all.
    public var changes: Bool { self == .turns || self == .grass }

    /// **The guess from a prop's name** — its words, split at anything not a letter and where a capital starts one:
    /// `SM_Env_Tree_Pine_01` and `PineTree01` are both a pine tree. A dead tree, stump or log is unchanged before anything
    /// else; then evergreen words, grass words, broadleaf words; anything else unchanged.
    public static func guess(name: String) -> Foliage {
        let words = Set(Self.words(name))
        if !words.isDisjoint(with: ["dead", "stump", "stumps", "log", "logs", "trunk", "trunks", "fallen", "burnt", "burned",
                                    "charred", "driftwood", "twig", "twigs"]) { return .unchanged }
        if !words.isDisjoint(with: ["pine", "pines", "fir", "firs", "spruce", "spruces", "cedar", "cedars", "conifer",
                                    "conifers", "coniferous", "cypress", "yew", "juniper", "palm", "palms", "cactus",
                                    "cacti", "succulent", "succulents", "redwood", "sequoia", "hemlock", "evergreen",
                                    "evergreens", "christmas", "hedge", "hedges", "boxwood", "holly", "bamboo"]) {
            return .evergreen
        }
        if !words.isDisjoint(with: ["grass", "grasses", "grassy", "reed", "reeds", "cattail", "cattails", "wheat", "rush",
                                    "rushes", "sedge", "sedges", "hay", "crop", "crops", "corn", "barley", "meadow"])
            && words.isDisjoint(with: ["tree", "trees"]) {
            return .grass
        }
        if !words.isDisjoint(with: ["tree", "trees", "bush", "bushes", "shrub", "shrubs", "oak", "oaks", "maple", "maples",
                                    "birch", "birches", "beech", "elm", "elms", "willow", "willows", "aspen", "poplar",
                                    "chestnut", "fruit", "apple", "cherry", "orchard", "sapling", "saplings", "vine",
                                    "vines", "ivy", "fern", "ferns", "leaf", "leaves", "foliage", "canopy", "larch",
                                    "sycamore", "linden", "alder", "hazel", "rowan", "hawthorn", "bramble", "brambles"]) {
            return .turns
        }
        return .unchanged
    }

    /// A name's words, lowercased, digits dropped: split at anything not a letter, and before a capital that follows a
    /// small letter.
    public static func words(_ name: String) -> [String] {
        var words: [String] = [], current = ""
        var previousLower = false
        for ch in name {
            if ch.isLetter {
                if ch.isUppercase && previousLower && !current.isEmpty { words.append(current); current = "" }
                current.append(contentsOf: ch.lowercased())
                previousLower = ch.isLowercase
            } else {
                if !current.isEmpty { words.append(current); current = "" }
                previousLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

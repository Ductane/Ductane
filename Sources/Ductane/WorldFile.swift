//
//  WorldFile.swift
//  Ductane
//

import Foundation
import simd

/// **A world as a game reads it**: what a world editor writes beside a scene's props so a game can draw it and walk it
/// without the editor — every prop placed and what it wears, the ground, the sky and lights, water, streams and living
/// effects, the world's edge, what a walker passes through and what it meets, and the scene's markers.
///
/// It travels inside a scene package (``WorldPackage``): `game/world.json` beside the package's props, which ``props``
/// names by their paths in the package — so a game draws the **same prop files** the scene references, through
/// ``MeshLoader``, and shows what the scene's author saw. Ground and collision shapes are binary files beside it
/// (``Ground``, ``CollisionShape``).
///
/// **Markers are the scene's, and their meaning is the game's.** A marker is a kind, a name, a place, a facing and a few
/// numbers (``Marker``); which kind is where the player starts, where enemies wait or what a mission is for is each
/// game's own reading, so nothing here names one.
///
/// **Coordinates are the scene's** — metres, Y up — and a game's, so nothing is turned or mirrored between them.
public nonisolated struct WorldFile: Codable, Equatable, Sendable {

    /// Bumped when an old file would be read wrongly; a newer file than this is refused (``ReadError/newer(_:)``).
    public static let version = 1

    public var version: Int = WorldFile.version
    /// The scene's name — its file's, without the extension.
    public var name: String
    /// The prop files, by their paths inside the package, each named once: placements refer to them by index.
    public var props: [String]
    /// **The props a walker passes through**, by index into ``props`` — grass, reeds, bushes, litter, a liquid's surface.
    /// Everything else is solid; a game never decides this itself, so what stops an author walking the scene in the
    /// editor is what stops a player.
    public var walkedThrough: [Int]
    /// **The props whose maker made a shape a walker meets instead of the prop as drawn** — a stair's flights as a ramp,
    /// a shack's walls without their trim: by index into ``props``, the path of each shape's triangles in the package
    /// (``CollisionShape``).
    public var collisionShapes: [Int: String]
    /// **The surfaces drawn as a liquid, coloured by how deep they are** — by prop and the material it replaces.
    public var liquids: [Liquid]
    /// **The props that are characters with a skeleton** — a figure made in a character tool and stood in the scene — by
    /// index into ``props``: a game draws them skinned and idling, not as props. Their placements are among the rest.
    public var characters: [Int]
    /// **The meshes effects throw** — a frog, a bubble, a fly — by the name a recipe gives (``ParticleRecipe/mesh``),
    /// each an index into ``props``: a prop placed nowhere, drawn per particle. A name not here is drawn as a disc.
    public var effectMeshes: [String: Int]
    /// **Materials grimed by where they are** — triplanar dirt by prop (its own materials, or a material file a placement
    /// wears) and material name.
    public var grime: [Grime]
    public var placements: [Placement]
    public var ground: Ground?
    public var sky: Sky
    public var lights: [Light]
    public var waters: [Water]
    public var streams: [Stream]
    public var effects: [Effect]
    /// The scene's markers, in the order they were placed. What each kind means is the game's.
    public var markers: [Marker]
    /// **The world's edge** — a dome or walls nobody leaves, and a net under the ground. Nil when the scene has none.
    public var boundary: WorldBoundary?
    /// **How the way to a place is shown in this world** (``Waymark``). Nil: the engine's own look.
    public var waymark: Waymark.Look?

    public init(name: String, props: [String], walkedThrough: [Int] = [], collisionShapes: [Int: String] = [:],
                liquids: [Liquid] = [], characters: [Int] = [], effectMeshes: [String: Int] = [:], grime: [Grime] = [],
                placements: [Placement], ground: Ground? = nil, sky: Sky = Sky(), lights: [Light] = [],
                waters: [Water] = [], streams: [Stream] = [], effects: [Effect] = [], markers: [Marker] = [],
                boundary: WorldBoundary? = nil, waymark: Waymark.Look? = nil) {
        self.name = name
        self.props = props
        self.walkedThrough = walkedThrough
        self.collisionShapes = collisionShapes
        self.liquids = liquids
        self.characters = characters
        self.effectMeshes = effectMeshes
        self.grime = grime
        self.placements = placements
        self.ground = ground
        self.sky = sky
        self.lights = lights
        self.waters = waters
        self.streams = streams
        self.effects = effects
        self.markers = markers
        self.boundary = boundary
        self.waymark = waymark
    }

    /// **What a file leaves out is empty**, not an error: a list or a table not written is none, so a description written
    /// by hand, or by an editor that knows less, still reads. Only the name, the props and the placements are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? WorldFile.version
        name = try c.decode(String.self, forKey: .name)
        props = try c.decode([String].self, forKey: .props)
        walkedThrough = try c.decodeIfPresent([Int].self, forKey: .walkedThrough) ?? []
        collisionShapes = try c.decodeIfPresent([Int: String].self, forKey: .collisionShapes) ?? [:]
        liquids = try c.decodeIfPresent([Liquid].self, forKey: .liquids) ?? []
        characters = try c.decodeIfPresent([Int].self, forKey: .characters) ?? []
        effectMeshes = try c.decodeIfPresent([String: Int].self, forKey: .effectMeshes) ?? [:]
        grime = try c.decodeIfPresent([Grime].self, forKey: .grime) ?? []
        placements = try c.decode([Placement].self, forKey: .placements)
        ground = try c.decodeIfPresent(Ground.self, forKey: .ground)
        sky = try c.decodeIfPresent(Sky.self, forKey: .sky) ?? Sky()
        lights = try c.decodeIfPresent([Light].self, forKey: .lights) ?? []
        waters = try c.decodeIfPresent([Water].self, forKey: .waters) ?? []
        streams = try c.decodeIfPresent([Stream].self, forKey: .streams) ?? []
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        boundary = try c.decodeIfPresent(WorldBoundary.self, forKey: .boundary)
        waymark = try c.decodeIfPresent(Waymark.Look.self, forKey: .waymark)
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, props, walkedThrough, collisionShapes, liquids, characters, effectMeshes, grime, placements,
             ground, sky, lights, waters, streams, effects, markers, boundary, waymark
    }

    // MARK: Markers

    /// **A marker the scene places**: its kind (`spawn`, `encounter` — whatever the game reads), its name, where it
    /// stands, which way it faces, and the numbers set on it.
    public struct Marker: Codable, Equatable, Sendable {
        public var kind: String
        public var name: String
        public var position: SIMD3<Float>
        /// Radians about +Y: 0 looks down −Z, positive turns left.
        public var yaw: Float
        public var values: [String: Double]
        public init(kind: String, name: String = "", position: SIMD3<Float>, yaw: Float = 0, values: [String: Double] = [:]) {
            self.kind = kind
            self.name = name
            self.position = position
            self.yaw = yaw
            self.values = values
        }

        /// Whether it is of `kind`, in any case.
        public func `is`(_ kind: String) -> Bool { self.kind.lowercased() == kind.lowercased() }
    }

    /// The markers of `kind`, in any case, in the order they were placed.
    public func markers(_ kind: String) -> [Marker] { markers.filter { $0.is(kind) } }

    // MARK: Props and placements

    /// One placed prop — a placement, or one copy of a scattered group.
    public struct Placement: Codable, Equatable, Sendable {
        /// An index into ``WorldFile/props``.
        public var prop: Int
        /// The scene's transform, sixteen numbers column by column.
        public var matrix: [Float]
        /// **What it wears instead of its own materials**: by the name of the material it replaces, the file and
        /// material it wears. Empty for most.
        public var materials: [String: Worn]
        /// **One copy of a scattered group** — a brush stroke of grass or rocks — rather than a prop placed on its own; for
        /// a game that treats the two differently (what is a structure, what is flora). Written only when true.
        public var scattered: Bool

        public init(prop: Int, matrix: [Float], materials: [String: Worn] = [:], scattered: Bool = false) {
            self.prop = prop
            self.matrix = matrix
            self.materials = materials
            self.scattered = scattered
        }

        public init(prop: Int, transform: simd_float4x4, materials: [String: Worn] = [:], scattered: Bool = false) {
            self.init(prop: prop, matrix: WorldFile.numbers(transform), materials: materials, scattered: scattered)
        }

        public var transform: simd_float4x4 { WorldFile.matrix(matrix) }

        /// Where it stands — the transform's translation.
        public var position: SIMD3<Float> { SIMD3(matrix[12], matrix[13], matrix[14]) }

        /// Its size along its own up — the scale a placement of one size all round was given.
        public var scale: Float { simd_length(SIMD3(matrix[4], matrix[5], matrix[6])) }

        /// **Its turn about the vertical and the lean after it** — the transform's rotation read as a world editor writes
        /// one: turned by `yaw` radians about +Y, then tipped from the vertical onto `up` by the shortest way. A lean too
        /// small to see is none. For a game that places things by turn and size rather than by matrix.
        public var turnAndLean: (yaw: Float, up: SIMD3<Float>) {
            let m = transform
            let axes = [m.columns.0, m.columns.1, m.columns.2].map { simd_normalize(SIMD3($0.x, $0.y, $0.z)) }
            let q = simd_quatf(simd_float3x3(axes[0], axes[1], axes[2]))
            guard simd_length(q.vector) > 1e-6, simd_length(q.vector).isFinite else { return (0, SIMD3(0, 1, 0)) }
            let rotation = simd_normalize(q)
            var up = simd_normalize(rotation.act(SIMD3(0, 1, 0)))
            if simd_distance(up, SIMD3(0, 1, 0)) < 1e-3 { up = SIMD3(0, 1, 0) }
            let turn = Self.lean(onto: up).inverse * rotation
            return (2 * atan2(turn.imag.y, turn.real), up)
        }

        /// The rotation that tips the vertical onto `up` by the shortest way — a half turn about +X for straight down,
        /// where every way is shortest.
        static func lean(onto up: SIMD3<Float>) -> simd_quatf {
            let up = simd_normalize(up)
            if up == SIMD3(0, 1, 0) { return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)) }
            if up.y < -0.99999 { return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)) }
            return simd_quatf(from: SIMD3(0, 1, 0), to: up)
        }

        /// Materials omitted when empty, so the thousands of placements wearing their own say nothing; `scattered` only when
        /// true.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prop = try c.decode(Int.self, forKey: .prop)
            matrix = try c.decode([Float].self, forKey: .matrix)
            materials = try c.decodeIfPresent([String: Worn].self, forKey: .materials) ?? [:]
            scattered = try c.decodeIfPresent(Bool.self, forKey: .scattered) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(prop, forKey: .prop)
            try c.encode(matrix, forKey: .matrix)
            if !materials.isEmpty { try c.encode(materials, forKey: .materials) }
            if scattered { try c.encode(true, forKey: .scattered) }
        }

        private enum CodingKeys: String, CodingKey { case prop, matrix, materials, scattered }
    }

    /// A material worn from another file: the file, by its index in ``WorldFile/props``, and the material's name in it.
    public struct Worn: Codable, Equatable, Hashable, Sendable {
        public var prop: Int
        public var name: String
        public init(prop: Int, name: String) {
            self.prop = prop
            self.name = name
        }
    }

    /// Whether a walker passes through each prop, in ``props``' order.
    public var passesThrough: [Bool] {
        var passes = [Bool](repeating: false, count: props.count)
        for index in walkedThrough where passes.indices.contains(index) { passes[index] = true }
        return passes
    }

    // MARK: Looks

    /// **A material of a prop grimed by where it is**: which prop, the material's name as the file writes it, and the
    /// grime — its map named relative to the prop's own folder, its tint linear.
    public struct Grime: Codable, Equatable, Sendable {
        public var prop: Int
        public var material: String
        public var look: Look
        public init(prop: Int, material: String, look: Look) {
            self.prop = prop
            self.material = material
            self.look = look
        }
        public struct Look: Codable, Equatable, Sendable {
            public var texture: String
            public var colour: SIMD3<Float>
            public var intensity, tiling, falloff, albedoTiling: Float
            public init(texture: String, colour: SIMD3<Float>, intensity: Float, tiling: Float, falloff: Float,
                        albedoTiling: Float) {
                self.texture = texture
                self.colour = colour
                self.intensity = intensity
                self.tiling = tiling
                self.falloff = falloff
                self.albedoTiling = albedoTiling
            }
        }
    }

    /// **A material of a prop drawn as a liquid**: which prop (an index into ``props``), the material's name as the file
    /// writes it (the name a loaded material carries), and its look.
    public struct Liquid: Codable, Equatable, Sendable {
        public var prop: Int
        public var material: String
        public var look: Look
        public init(prop: Int, material: String, look: Look) {
            self.prop = prop
            self.material = material
            self.look = look
        }

        /// **A stylised water shader's numbers**: three colours by depth behind the surface, a scrolling sheet over it, a
        /// bright band and line along its shores, specks of foam, normals panning. Textures are named relative to the
        /// prop's own folder; colours are linear.
        public struct Look: Codable, Equatable, Sendable {
            public var shallow, deep, veryDeep: SIMD3<Float>
            public var deepHeight, veryDeepHeight, shallowsOpacity, baseOpacity: Float
            public var scrollTexture: String?
            public var scrollTint: SIMD3<Float>
            public var scrollOpacity: Float
            public var scrollTiling, scrollDirection: SIMD2<Float>
            public var shoreTint: SIMD3<Float>
            public var shoreEdgeThickness, shoreEdgeOpacity, shoreWaveThickness, shoreWaveReturn: Float
            public var shoreEdgeNoiseScale, shoreFoamNoiseScale: Float
            public var foamTint: SIMD3<Float>
            public var foamOpacity, foamTiling: Float
            public var noiseTexture, normalTexture: String?
            public var normalTiling, normalIntensity, normalNoiseIntensity, normalNoiseTiling, normalPanSpeed: Float
            public var metallic, smoothness: Float
            public var shoreBand, shoreFoam, scrolling, ripples: Bool

            /// The colour at `depth` metres behind the surface, before the sheet and the shore — two gradients, shallow
            /// to deep and deep to very deep.
            public func colour(atDepth depth: Float) -> SIMD3<Float> {
                let toDeep = 1 - min(max(depth / abs(deepHeight), 0), 1)
                let toVeryDeep = min(min(max(depth / abs(veryDeepHeight), 0), 1) * 2, 1)
                return simd_mix(simd_mix(deep, shallow, SIMD3(repeating: toDeep)), veryDeep, SIMD3(repeating: toVeryDeep))
            }

            /// The texture files it names, relative to the prop's folder.
            public var textureFiles: [String] { [scrollTexture, noiseTexture, normalTexture].compactMap { $0 } }
        }
    }

    // MARK: Water, streams and effects

    /// **A body of still water**: its surface — the rectangles it fills at its level — and its own look.
    public struct Water: Codable, Equatable, Sendable {
        public var level: Float
        /// Linear.
        public var colour: [Float]
        public var opacity: Float
        /// Each rectangle as `[x0, z0, x1, z1]`.
        public var rectangles: [[Float]]
        public init(level: Float, colour: SIMD3<Float>, opacity: Float, rectangles: [SIMD4<Float>]) {
            self.level = level
            self.colour = [colour.x, colour.y, colour.z]
            self.opacity = opacity
            self.rectangles = rectangles.map { [$0.x, $0.y, $0.z, $0.w] }
        }

        /// **Whether `point` is under this water** — below its level, over one of its rectangles.
        public func covers(_ point: SIMD3<Float>) -> Bool {
            guard point.y < level else { return false }
            return rectangles.contains { r in
                r.count == 4 && point.x >= r[0] && point.x <= r[2] && point.z >= r[1] && point.z <= r[3]
            }
        }
    }

    /// **A stream's running surface**, three corners to a triangle, each ``Stream/floatsPerCorner`` numbers: x, y, z,
    /// metres along, the way it runs (x, z), how white, how fast, which bank — and the course it was drawn along and how
    /// wide, for a game that lays its own water down it.
    public struct Stream: Codable, Equatable, Sendable {
        public static let floatsPerCorner = 9
        public var length: Float
        public var corners: [Float]
        /// The points it runs through, downstream, each on its bed.
        public var course: [SIMD3<Float>]
        /// Metres from bank to bank.
        public var width: Float
        public init(length: Float, corners: [Float], course: [SIMD3<Float>] = [], width: Float = 0) {
            self.length = length
            self.corners = corners
            self.course = course
            self.width = width
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            length = try c.decode(Float.self, forKey: .length)
            corners = try c.decode([Float].self, forKey: .corners)
            course = try c.decodeIfPresent([SIMD3<Float>].self, forKey: .course) ?? []
            width = try c.decodeIfPresent(Float.self, forKey: .width) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case length, corners, course, width }
    }

    /// **A living effect**: its kind and look, where, how thick and wide, which way it blows, and **the recipe it moves
    /// by** (``ParticleRecipe``), so a game moves it exactly as the editor showed it. Only its art is the game's.
    public struct Effect: Codable, Equatable, Sendable {
        /// What the editor calls its kind — `smoke`, `fireflies` … — for a game that draws kinds its own way.
        public var kind: String
        public var variety: Int
        public var position: [Float]
        public var rate: Float
        public var radius: Float
        public var direction: [Float]
        /// Seconds to run it before the first frame, so a swarm is a swarm on arrival.
        public var prewarm: Float
        /// A shaft of light, leaned along the sun when drawn.
        public var followsSun: Bool
        public var recipe: ParticleRecipe
        /// What its particles are followed by: recipes its ``ParticleRecipe/then`` counts on, its own being 0.
        public var followers: [ParticleRecipe]
        public init(kind: String, variety: Int, position: SIMD3<Float>, rate: Float, radius: Float, direction: SIMD3<Float>,
                    prewarm: Float, followsSun: Bool, recipe: ParticleRecipe, followers: [ParticleRecipe] = []) {
            self.kind = kind
            self.variety = variety
            self.position = [position.x, position.y, position.z]
            self.rate = rate
            self.radius = radius
            self.direction = [direction.x, direction.y, direction.z]
            self.prewarm = prewarm
            self.followsSun = followsSun
            self.recipe = recipe
            self.followers = followers
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            variety = try c.decodeIfPresent(Int.self, forKey: .variety) ?? 0
            position = try c.decode([Float].self, forKey: .position)
            rate = try c.decode(Float.self, forKey: .rate)
            radius = try c.decode(Float.self, forKey: .radius)
            direction = try c.decodeIfPresent([Float].self, forKey: .direction) ?? [0, 1, 0]
            prewarm = try c.decodeIfPresent(Float.self, forKey: .prewarm) ?? 0
            followsSun = try c.decodeIfPresent(Bool.self, forKey: .followsSun) ?? false
            recipe = try c.decode(ParticleRecipe.self, forKey: .recipe)
            followers = try c.decodeIfPresent([ParticleRecipe].self, forKey: .followers) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case kind, variety, position, rate, radius, direction, prewarm, followsSun, recipe, followers
        }
    }

    // MARK: Ground, sky and lights

    /// **The scene's ground**: a square grid centred on the origin, `resolution` cells a side, heights and colours at its
    /// points (`(resolution + 1)²` of each, rows along +X, row after row along +Z) — files in the package, read into a
    /// ``WorldGround``.
    public struct Ground: Codable, Equatable, Sendable {
        public var size: Float
        public var resolution: Int
        /// Little-endian `Float32` heights, one a point (``heightsData(_:)``).
        public var heights: String
        /// Linear RGB colours as three sRGB-encoded `UInt8`s a point — the painted layers mixed (``coloursData(_:)``).
        public var colours: String
        /// **Where the ground is cut away** — a cave's mouth — as one byte a cell (`resolution²`, rows along +X), 1 for a
        /// hole; nil when it has none (``holesData(_:)``).
        public var holes: String?
        /// **How much of each painted layer is at each point** — eight bytes a point, each layer's share of 255, the
        /// same order as ``layers`` (``weights(_:points:)``) — for a game that paints the ground with textures of its
        /// own. Nil when the scene's ground was never painted.
        public var weights: String?
        /// The painted layers' names, in the weights' order.
        public var layers: [String]
        public init(size: Float, resolution: Int, heights: String = "game/ground.f32", colours: String = "game/ground.rgb",
                    holes: String? = nil, weights: String? = nil, layers: [String] = []) {
            self.size = size
            self.resolution = resolution
            self.heights = heights
            self.colours = colours
            self.holes = holes
            self.weights = weights
            self.layers = layers
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            size = try c.decode(Float.self, forKey: .size)
            resolution = try c.decode(Int.self, forKey: .resolution)
            heights = try c.decode(String.self, forKey: .heights)
            colours = try c.decode(String.self, forKey: .colours)
            holes = try c.decodeIfPresent(String.self, forKey: .holes)
            weights = try c.decodeIfPresent(String.self, forKey: .weights)
            layers = try c.decodeIfPresent([String].self, forKey: .layers) ?? []
        }

        private enum CodingKeys: String, CodingKey { case size, resolution, heights, colours, holes, weights, layers }

        /// The grid sizes a ground may have, in cells a side: 16,384 is 268 million points, far past any world's and still
        /// clear of overflowing a point count or a file size.
        public static let resolutions = 1...16_384

        /// How many layers a point's weights hold.
        public static let layerCount = 8

        /// The weights file read back: each point's eight shares, out of 255.
        public static func weights(_ data: Data, points: Int) -> [SIMD8<UInt8>]? {
            guard data.count == points * layerCount else { return nil }
            // A point's eight bytes at once: read a byte at a time, a 600,000-point ground took most of a second unoptimised.
            return data.withUnsafeBytes { raw in
                (0..<points).map { raw.loadUnaligned(fromByteOffset: $0 * layerCount, as: SIMD8<UInt8>.self) }
            }
        }

        /// The heights file.
        public static func heightsData(_ heights: [Float]) -> Data {
            var data = Data(capacity: heights.count * 4)
            for v in heights { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            return data
        }

        /// The colours file, from linear colours.
        public static func coloursData(_ colours: [SIMD3<Float>]) -> Data {
            var data = Data(capacity: colours.count * 3)
            for v in colours { data.append(contentsOf: [WorldGround.srgbByte(v.x), WorldGround.srgbByte(v.y), WorldGround.srgbByte(v.z)]) }
            return data
        }

        /// The holes file: a byte a cell.
        public static func holesData(_ holes: [Bool]) -> Data { Data(holes.map { $0 ? 1 : 0 }) }
    }

    /// The scene's sky: its hour and fog, and the sun if it was set by hand (``DaySky``).
    public struct Sky: Codable, Equatable, Sendable {
        public var timeOfDay: Float
        public var fogDensity: Float
        public var sun: Sun?
        public init(timeOfDay: Float = 15, fogDensity: Float = 0, sun: Sun? = nil) {
            self.timeOfDay = timeOfDay
            self.fogDensity = fogDensity
            self.sun = sun
        }

        public struct Sun: Codable, Equatable, Sendable {
            /// Degrees.
            public var heading: Float
            public var height: Float
            /// Linear.
            public var colour: [Float]
            public var brightness: Float
            public init(heading: Float, height: Float, colour: [Float], brightness: Float) {
                self.heading = heading
                self.height = height
                self.colour = colour
                self.brightness = brightness
            }
        }

        /// The sky as ``DaySky`` draws and lights it.
        public var daySky: DaySky {
            DaySky(timeOfDay: timeOfDay, sun: sun.map {
                DaySky.Sun(heading: $0.heading, height: $0.height,
                           colour: $0.colour.count == 3 ? SIMD3($0.colour[0], $0.colour[1], $0.colour[2]) : SIMD3(1, 1, 1),
                           brightness: $0.brightness)
            }, fogDensity: fogDensity)
        }
    }

    /// A point light.
    public struct Light: Codable, Equatable, Sendable {
        public var position: [Float]
        public var colour: [Float]
        public var intensity: Float
        public var reach: Float
        public init(position: [Float], colour: [Float], intensity: Float, reach: Float) {
            self.position = position
            self.colour = colour
            self.intensity = intensity
            self.reach = reach
        }
    }

    // MARK: Collision shapes

    /// **The triangles a walker meets** for one prop, in the prop's own space: little-endian floats, nine a triangle, no
    /// header — `x y z` three times.
    public enum CollisionShape {
        public static func data(_ triangles: [SIMD3<Float>]) -> Data {
            var data = Data(capacity: triangles.count * 12)
            for point in triangles.prefix(triangles.count / 3 * 3) {
                for value in [point.x, point.y, point.z] {
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
                }
            }
            return data
        }

        public static func triangles(_ data: Data) throws -> [SIMD3<Float>] {
            guard data.count % 36 == 0 else { throw ReadError.notWholeTriangles(bytes: data.count) }
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(data.count / 12)
            data.withUnsafeBytes { raw in
                func float(_ at: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                }
                for offset in stride(from: 0, to: data.count, by: 12) {
                    points.append(SIMD3(float(offset), float(offset + 4), float(offset + 8)))
                }
            }
            return points
        }
    }

    // MARK: Matrices

    /// A transform as sixteen numbers, column by column.
    public static func numbers(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    public static func matrix(_ c: [Float]) -> simd_float4x4 {
        guard c.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(c[0], c[1], c[2], c[3]), SIMD4(c[4], c[5], c[6], c[7]),
                                       SIMD4(c[8], c[9], c[10], c[11]), SIMD4(c[12], c[13], c[14], c[15])))
    }

    // MARK: Reading and writing

    /// Reads a description, refusing one newer than this engine reads or one whose placements name props it lacks.
    /// **A description is data from anyone**: every index into ``props`` is checked — placements and what they wear,
    /// characters, effect meshes, liquids, grime, collision shapes, what is walked through — and the ground's grid kept to
    /// a size its files can hold, so nothing read from it traps or overflows later.
    public static func read(_ data: Data) throws -> WorldFile {
        let file = try JSONDecoder().decode(WorldFile.self, from: data)
        guard file.version <= version else { throw ReadError.newer(file.version) }
        if let bad = file.placements.first(where: { !file.props.indices.contains($0.prop) || $0.matrix.count != 16 }) {
            throw ReadError.badPlacement(bad.prop)
        }
        let named = file.placements.flatMap { $0.materials.values.map(\.prop) } + file.characters + Array(file.effectMeshes.values)
            + file.liquids.map(\.prop) + file.grime.map(\.prop) + Array(file.collisionShapes.keys) + file.walkedThrough
        if let bad = named.first(where: { !file.props.indices.contains($0) }) { throw ReadError.badProp(bad) }
        if let ground = file.ground, !Ground.resolutions.contains(ground.resolution) {
            throw ReadError.badGround(ground.resolution)
        }
        return file
    }

    /// Sorted keys: the same scene writes the same file, so exporting again with nothing changed changes nothing.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case newer(Int)
        case badPlacement(Int)
        case notWholeTriangles(bytes: Int)
        case wrongWeights(String)
        case badProp(Int)
        case badGround(Int)
        public var description: String {
            switch self {
            case .newer(let v): "the world file is version \(v); this engine reads up to \(WorldFile.version)"
            case .badPlacement(let p): "a placement names prop \(p), which the file does not list, or has no transform"
            case .notWholeTriangles(let bytes): "a collision shape of \(bytes) bytes is not whole triangles (36 bytes each)"
            case .wrongWeights(let path): "\(path) is not eight bytes a point of the ground"
            case .badProp(let p): "the file names prop \(p), which it does not list"
            case .badGround(let r): "a ground of \(r) cells a side is not one this engine reads (\(Ground.resolutions))"
            }
        }
    }
}

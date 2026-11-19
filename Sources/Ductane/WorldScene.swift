//
//  WorldScene.swift
//  Ductane
//

import Foundation
import simd

/// **What a ``WorldRenderer`` draws**: every prop placed and scattered, by file, with the materials it wears; the sky, the
/// weather and the world's clock; water, streams, living effects and lights; the world's edge; and what each prop does
/// in the wind and through the year. The ground is handed over apart (``WorldRenderer/showGround(_:changed:)``), a patch
/// at a time while it is being edited.
///
/// **A game makes one from a scene package** (``init(_:)``): what a world editor exported, so the game draws exactly what
/// the scene's author saw. An editor makes one from its own scene each time the scene changes; the renderer works out
/// what changed — a placement dragged, copies moved by a brush — and redoes only that.
public nonisolated struct WorldScene: Equatable, Sendable {

    // MARK: Props

    /// **A material worn from another file**: the prop file that defines it, and the material's name in it — the last
    /// part of its path there.
    public struct Worn: Hashable, Sendable {
        public var file: URL
        public var name: String
        public init(file: URL, name: String) {
            self.file = file
            self.name = name
        }
    }

    /// **One prop placed on its own.**
    public struct Placement: Equatable, Sendable {
        /// The same while it is edited: a placement dragged is told from one added by it.
        public var id: UUID
        /// The prop's file.
        public var prop: URL
        public var transform: simd_float4x4
        /// Its largest size along any of its axes, times its own — what its level of detail is judged by.
        public var scale: Float
        /// **What it wears instead of its own materials**, by the name of the material each replaces.
        public var materials: [String: Worn]

        public init(id: UUID = UUID(), prop: URL, transform: simd_float4x4, scale: Float? = nil,
                    materials: [String: Worn] = [:]) {
            self.id = id
            self.prop = prop
            self.transform = transform
            self.scale = scale ?? WorldScene.largestScale(of: transform)
            self.materials = materials
        }
    }

    /// **A group of scattered copies** — a brush stroke of grass, rocks, trees: drawn instanced, culled and levelled by
    /// their size on screen, the heavy ones far off as their far pictures.
    public struct Scatter: Equatable, Sendable {
        /// The same while it is edited.
        public var id: UUID
        /// The props its copies are of.
        public var prototypes: [URL]
        /// **What each prototype wears**, by its index in ``prototypes``: every copy of it alike. Empty for most.
        public var looks: [Int: [String: Worn]]
        public var copies: [Copy]

        public init(id: UUID = UUID(), prototypes: [URL], looks: [Int: [String: Worn]] = [:], copies: [Copy]) {
            self.id = id
            self.prototypes = prototypes
            self.looks = looks
            self.copies = copies
        }

        /// What prototype `index` wears.
        public func look(of index: Int) -> [String: Worn] { looks[index] ?? [:] }

        /// The files its prototypes wear materials from.
        public var wornFiles: [URL] { looks.values.flatMap { $0.values.map(\.file) } }
    }

    /// **One scattered copy**: which prototype, where, and its largest size.
    public struct Copy: Equatable, Sendable {
        public var prototype: Int
        public var transform: simd_float4x4
        public var scale: Float
        public init(prototype: Int, transform: simd_float4x4, scale: Float? = nil) {
            self.prototype = prototype
            self.transform = transform
            self.scale = scale ?? WorldScene.largestScale(of: transform)
        }
    }

    public var placements: [Placement]
    public var scatters: [Scatter]

    // MARK: The world round them

    /// The sky: its hour and fog, a sun set by hand, the world's clock, aurora (``WorldFile/Sky``).
    public var sky: WorldFile.Sky
    /// **A fine grain on the ground near the eye**, 0…1: two scales of noise darkening by up to a fifth — something
    /// underfoot to see go by on ground painted one colour.
    public var groundGrain: Float
    /// **The weather as set** — a schedule's seasons on the clock's calendar. The renderer works out the weather of each
    /// moment from it (``Weather/current(at:)``).
    public var weather: Weather
    /// Still water: each body's level, look and the rectangles it fills.
    public var waters: [WorldFile.Water]
    /// Running water: each stream's surface (``WorldFile/Stream``).
    public var streams: [WorldFile.Stream]
    public var effects: [Effect]
    public var lights: [Light]
    /// **The world's edge**, fitted to the world (``WorldBoundary``); nil for none.
    public var boundary: WorldBoundary?

    // MARK: Through the year and in the wind

    /// **What each prop does through the year**, by file.
    public var foliage: [URL: Foliage]
    /// **How each prop moves in the wind**, by file.
    public var sway: [URL: Sway]
    /// **Ground cover a person decided**, by file: true or false whatever the prop's shape. The rest are judged by shape
    /// (``isGroundCover(_:size:cutOut:)``).
    public var groundCover: [URL: Bool]
    /// **Whether a prop missing from ``foliage`` and ``sway`` is guessed from its file's name** (``Foliage/guess(name:)``,
    /// ``Sway/guess(name:)``) — an editor's way, where only what someone changed is set — or left as drawn, a world file's,
    /// which lists every prop the season or the wind moves.
    public var guessesByName: Bool

    /// **What a scan finds** (``WaymarkScan``): each prop it finds, by file, with the kind it is found as — every
    /// placement and scattered copy of it.
    public var found: [URL: String]
    /// **The world's markers**, for a scan to find those of a kind it is told to (``Waymark/Look/Kind/markers``).
    public var markers: [WorldFile.Marker]

    /// **The meshes effects throw** — a frog, a bubble — by the name a recipe gives (``ParticleRecipe/mesh``): a prop
    /// file placed nowhere, drawn per particle. A name not here is drawn as a disc.
    public var effectMeshes: [String: URL]

    public init(placements: [Placement] = [], scatters: [Scatter] = [], sky: WorldFile.Sky = WorldFile.Sky(),
                groundGrain: Float = 0, weather: Weather = .clear, waters: [WorldFile.Water] = [],
                streams: [WorldFile.Stream] = [], effects: [Effect] = [], lights: [Light] = [],
                boundary: WorldBoundary? = nil, foliage: [URL: Foliage] = [:], sway: [URL: Sway] = [:],
                groundCover: [URL: Bool] = [:], guessesByName: Bool = false, effectMeshes: [String: URL] = [:], found: [URL: String] = [:],
                markers: [WorldFile.Marker] = []) {
        self.placements = placements
        self.scatters = scatters
        self.sky = sky
        self.groundGrain = groundGrain
        self.weather = weather
        self.waters = waters
        self.streams = streams
        self.effects = effects
        self.lights = lights
        self.boundary = boundary
        self.foliage = foliage
        self.sway = sway
        self.groundCover = groundCover
        self.guessesByName = guessesByName
        self.effectMeshes = effectMeshes
        self.found = found
        self.markers = markers
    }

    /// Every file a placement or a scattered prototype wears a material from.
    public var wornFiles: [URL] {
        placements.flatMap { $0.materials.values.map(\.file) } + scatters.flatMap(\.wornFiles)
    }

    /// **What a prop does through the year**: as set, else guessed from its name (``guessesByName``), else unchanged.
    public func foliage(of prop: URL) -> Foliage {
        foliage[prop] ?? (guessesByName ? Foliage.guess(name: prop.deletingPathExtension().lastPathComponent) : .unchanged)
    }

    /// **How a prop moves in the wind**: as set, else guessed from its name (``guessesByName``), else still.
    public func sway(of prop: URL) -> Sway {
        sway[prop] ?? (guessesByName ? Sway.guess(name: prop.deletingPathExtension().lastPathComponent) : .still)
    }

    /// **Whether a prop is ground cover**, which a player's ``GraphicsSettings/plantDensity`` thins: as a person set it
    /// (``groundCover``), else by its shape (``GroundCover/byShape(size:cutOut:)``) — `size` its own, `cutOut` whether it
    /// is drawn all in cut-out cards.
    public func isGroundCover(_ prop: URL, size: SIMD3<Float>, cutOut: Bool) -> Bool {
        groundCover[prop] ?? GroundCover.byShape(size: size, cutOut: cutOut)
    }

    /// The largest of a transform's three axes' lengths: how many times its own size a prop is drawn at, at most.
    public static func largestScale(of transform: simd_float4x4) -> Float {
        max(simd_length(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
            simd_length(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
            simd_length(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
    }

    // MARK: Effects

    /// **A living effect** — butterflies, smoke, falling leaves: where, how thick and wide, which way it moves, and the
    /// recipe its particles follow (``ParticleRecipe``), so a renderer moves them exactly as the scene's author saw.
    public struct Effect: Equatable, Sendable {
        /// What the editor calls its kind — `smoke`, `fireflies`, `wind` … — which picks the sprite it is drawn with.
        public var kind: String
        public var variety: Int
        public var position: SIMD3<Float>
        /// How many a second it throws.
        public var rate: Float
        public var radius: Float
        /// The way its particles are thrown: level, along its heading, for one that moves one way; up for the rest.
        public var direction: SIMD3<Float>
        /// Seconds run before the first frame, so a swarm is a swarm on arrival.
        public var prewarm: Float
        /// A shaft of light, leaned along the sun.
        public var followsSun: Bool
        public var recipe: ParticleRecipe
        /// What its particles are followed by: recipes its ``ParticleRecipe/then`` counts on, its own being 0.
        public var followers: [ParticleRecipe]
        /// **Where its particles' randomness starts** — each effect its own, the same every run.
        public var seed: Int
        /// **Whether it moves with the wind** — wind and streaks: turned to the weather's heading and thickened with its
        /// speed (``blown(by:)``).
        public var blowsWithWind: Bool
        /// **The look falling leaves take once trees have turned** — nil for anything but leaves (``inSeason(_:phase:)``).
        public var turnedVariety: Int?

        public init(kind: String, variety: Int = 0, position: SIMD3<Float>, rate: Float, radius: Float,
                    direction: SIMD3<Float> = SIMD3(0, 1, 0), prewarm: Float = 0, followsSun: Bool = false,
                    recipe: ParticleRecipe, followers: [ParticleRecipe] = [], seed: Int = 0, blowsWithWind: Bool = false,
                    turnedVariety: Int? = nil) {
            self.kind = kind
            self.variety = variety
            self.position = position
            self.rate = rate
            self.radius = radius
            self.direction = direction
            self.prewarm = prewarm
            self.followsSun = followsSun
            self.recipe = recipe
            self.followers = followers
            self.seed = seed
            self.blowsWithWind = blowsWithWind
            self.turnedVariety = turnedVariety
        }

        /// How thick an effect may be: the most a dense one throws.
        public static let rates: ClosedRange<Float> = 0.1...100

        /// **As the weather's wind has it**: one that moves with the wind turned to blow its way, and thickened by its
        /// speed — a breeze leaves it as it is, a gale throws three times as much. Clear weather or still air changes
        /// nothing.
        public func blown(by weather: Weather) -> Effect {
            guard blowsWithWind, weather != .clear else { return self }
            let speed = weather.settings.windSpeed
            guard speed >= 1 else { return self }
            var blown = self
            blown.rate = min(max(rate * min(max(speed / 6, 0.5), 3), Self.rates.lowerBound), Self.rates.upperBound)
            let heading = weather.windHeading.isFinite ? weather.windHeading.truncatingRemainder(dividingBy: 360) : 90
            let h = (heading < 0 ? heading + 360 : heading) * .pi / 180
            blown.direction = SIMD3(sin(h), 0, -cos(h))
            return blown
        }

        /// **Falling leaves through the year** (``FallColors/leafFall(phase:)``): thicker while trees shed, and the turned
        /// look once they have turned. Anything else as it is.
        public func inSeason(_ fall: FallColors, phase: Float) -> Effect {
            guard let turnedVariety else { return self }
            let season = fall.leafFall(phase: phase)
            var changed = self
            changed.rate = rate * season.rate
            if season.turned { changed.variety = turnedVariety }
            return changed
        }

        /// Every mesh its particles are drawn as, by name.
        public var meshes: [String] { ([recipe] + followers).compactMap(\.mesh) }
    }

    // MARK: Lights

    /// **A point light**: where, its colour (linear) and strength, and how far it reaches — full close by, falling to
    /// nothing at its reach.
    public struct Light: Equatable, Sendable {
        public var position: SIMD3<Float>
        public var colour: SIMD3<Float>
        public var intensity: Float
        public var reach: Float
        public init(position: SIMD3<Float>, colour: SIMD3<Float>, intensity: Float, reach: Float) {
            self.position = position
            self.colour = colour
            self.intensity = intensity
            self.reach = reach
        }

        /// **The lights nearest a point**, at most `limit` — what a frame lights with: none lights every pixel in a zone. A
        /// light whose reach does not come within `radius` of the point is left out.
        public static func nearest(_ lights: [Light], to point: SIMD3<Float>, radius: Float = 60, limit: Int = 16) -> [Light] {
            lights.filter { simd_distance($0.position, point) - $0.reach < radius }
                .sorted { simd_distance($0.position, point) < simd_distance($1.position, point) }
                .prefix(limit).map { $0 }
        }
    }
}

// MARK: - A scene package

public nonisolated extension WorldScene {

    /// **The scene a package describes** (``WorldPackage``): its props by their files in the package, placed and scattered
    /// as the world file says, with what they wear, what the season and the wind do to them, the sky and weather, water,
    /// streams, effects, lights and edge. The ground is the package's too — ``WorldPackage/groundSource()``.
    ///
    /// **An export's effects are blown by its own weather already**, as the editor wrote them, so here they are not blown
    /// again (``Effect/blowsWithWind`` off).
    init(_ package: WorldPackage) {
        let world = package.world
        let urls = world.props.indices.map(package.propURL)
        func worn(_ materials: [String: WorldFile.Worn]) -> [String: Worn] {
            materials.compactMapValues { urls.indices.contains($0.prop) ? Worn(file: urls[$0.prop], name: $0.name) : nil }
        }
        var placements: [Placement] = [], scattered: [URL: [Copy]] = [:], order: [URL] = []
        for placement in world.placements where urls.indices.contains(placement.prop) {
            let transform = placement.transform
            if placement.scattered && placement.materials.isEmpty {
                let url = urls[placement.prop]
                if scattered[url] == nil { order.append(url) }
                scattered[url, default: []].append(Copy(prototype: 0, transform: transform))
            } else {
                placements.append(Placement(prop: urls[placement.prop], transform: transform,
                                            materials: worn(placement.materials)))
            }
        }
        // **Scattered copies as one group a prop**, so each is drawn instanced and as its far picture far off.
        let scatters = order.map { Scatter(prototypes: [$0], copies: scattered[$0] ?? []) }
        let effects = world.effects.enumerated().map { index, effect in
            Effect(kind: effect.kind, variety: effect.variety, position: WorldScene.vector(effect.position),
                   rate: effect.rate, radius: effect.radius, direction: WorldScene.vector(effect.direction, or: SIMD3(0, 1, 0)),
                   prewarm: effect.prewarm, followsSun: effect.followsSun, recipe: effect.recipe,
                   followers: effect.followers, seed: index * 1_000, blowsWithWind: false,
                   turnedVariety: effect.kind == "leaves" ? 1 : nil)
        }
        var meshes: [String: URL] = [:]
        for (name, prop) in world.effectMeshes where urls.indices.contains(prop) { meshes[name] = urls[prop] }
        var foliage: [URL: Foliage] = [:], sway: [URL: Sway] = [:]
        for (prop, kind) in world.foliage where urls.indices.contains(prop) { foliage[urls[prop]] = kind }
        for (prop, kind) in world.sway where urls.indices.contains(prop) { sway[urls[prop]] = kind }
        var groundCover: [URL: Bool] = [:]
        for (prop, set) in world.groundCover where urls.indices.contains(prop) { groundCover[urls[prop]] = set }
        var found: [URL: String] = [:]
        for (prop, kind) in world.found where urls.indices.contains(prop) { found[urls[prop]] = kind }
        self.init(placements: placements, scatters: scatters, sky: world.sky, weather: world.weather ?? .clear,
                  waters: world.waters, streams: world.streams, effects: effects,
                  lights: world.lights.map {
                      Light(position: WorldScene.vector($0.position), colour: WorldScene.vector($0.colour),
                            intensity: $0.intensity, reach: $0.reach)
                  },
                  boundary: world.boundary, foliage: foliage, sway: sway, groundCover: groundCover, guessesByName: false, effectMeshes: meshes,
                  found: found, markers: world.markers)
    }

    /// Three numbers as a vector, `fallback` if there are not three.
    private static func vector(_ values: [Float], or fallback: SIMD3<Float> = .zero) -> SIMD3<Float> {
        values.count == 3 ? SIMD3(values[0], values[1], values[2]) : fallback
    }
}

// MARK: - The sky on the world's clock

public nonisolated extension WorldFile.Sky {
    /// **The sky at `time` on the world's clock**: its latitude and place in the year from the clock — and the hour too
    /// when `running`, as a game's sky runs; otherwise the hour as set, for an editor looking at one hour of a day. Without
    /// a clock, ``daySky``.
    func daySky(at time: Double, running: Bool) -> DaySky {
        guard let clock else { return daySky }
        if running { return clock.sky(daySky, at: time) }
        var sky = daySky
        sky.latitude = clock.latitude
        sky.yearPosition = clock.yearPosition(at: time)
        sky.moonAge = clock.moonAge(at: time)
        sky.nightNumber = clock.nightNumber(at: time)
        return sky
    }
}

// MARK: - Water's look

public nonisolated extension WorldScene {
    /// **Water's own colour**, linear, looking down into it, and how much of what is under it shows through: a stream's,
    /// and a body of water's unless it sets its own.
    static let waterColour = SIMD3<Float>(0.03, 0.12, 0.15)
    static let waterOpacity: Float = 0.78
}

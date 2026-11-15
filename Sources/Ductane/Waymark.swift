//
//  Waymark.swift
//  Ductane
//

import Foundation
import simd

/// **The way to a place, shown for a few seconds**: a line over the ground from where a player stands, along the way they
/// can walk, and a beam of light standing up from the place itself — what a player asks for when they press a button to
/// find where to go next.
///
/// ### The way
///
/// ``way(from:to:grid:surface:searchLimit:)`` finds it: a path over a ``NavigationGrid`` — round walls, up stairs —
/// then straight on where the grid ends or no way is found. ``init(way:target:facing:surface:look:)`` makes the mark
/// from it once, and **it is held for its seconds**: a mark, not a trail that follows the player. Its corners are
/// rounded off, so it reads as a drawn line rather than the grid's turns.
///
/// **When the way starts behind the player**, it would be drawn where they cannot see it. So it begins **in front of
/// them**, a few meters along the way they face, and turns round to join the way — the line is seen leaving, and
/// followed round. (``Look/turnsToFace``.)
///
/// ### How it shows
///
/// The line sweeps out from the player at ``Look/sweepSpeed``, the front of it brighter as it goes; pulses run along it
/// toward the place at ``Look/flow``; the beam rises at once; and all of it fades at the end of ``Look/duration``.
/// Its pattern — dots, dashes, arrows, chevrons or a plain line — its color, width, roundness and glow, and the beam's,
/// are a ``Look``: a value a world saves and an editor sets, as ``WorldBoundary/Look`` is.
///
/// **A value with no GPU in it.** ``WaymarkRenderer`` draws one.
public nonisolated struct Waymark: Sendable, Equatable {

    /// **How a waymark looks**, every part of it. Read with every key optional, so a saved look missing one added since
    /// keeps everything it did say.
    public struct Look: Sendable, Equatable, Codable {

        /// What the line is made of.
        public enum Pattern: String, Sendable, Codable, CaseIterable {
            /// Round marks one after another — square ones at no ``Look/roundness``.
            case dots
            /// Short bars along the way.
            case dashes
            /// Solid arrowheads pointing on.
            case arrows
            /// Open chevrons pointing on.
            case chevrons
            /// One unbroken line.
            case line
        }

        /// **Where the marks are**: turned to face the view, floating over the ground — a dot stays a round dot from any
        /// angle — or lying flat on it, as paint would.
        public enum Placement: String, Sendable, Codable, CaseIterable {
            case floating
            case ground
        }

        /// **What is heard as it appears** (``WaymarkSound``): made, not recorded, so nothing need be shipped for it.
        public enum Sound: String, Sendable, Codable, CaseIterable {
            /// Two soft notes a fifth apart, ringing out.
            case bell
            /// One clear high note.
            case chime
            /// A sonar's ping and its echo.
            case sonar
            /// A low swell rising.
            case pulse
            case none
        }

        public var pattern: Pattern
        public var placement: Placement
        /// The line's color, linear.
        public var color: SIMD3<Float>
        /// What the color is multiplied by into the scene's light: above 1, it glows in an HDR scene.
        public var intensity: Float
        /// How wide each mark is across the way, meters — a dot's width, a line's thickness.
        public var width: Float
        /// Meters from one mark to the next; a ``Pattern/line`` ignores it.
        public var spacing: Float
        /// 0 square corners and ends, 1 fully round.
        public var roundness: Float
        /// How far its glow spreads round each mark, 0 none to 1 a mark's width again on each side.
        public var glow: Float
        /// **Meters a second the pulses run along it toward the place**; 0 still.
        public var flow: Float
        /// Meters a second the line sweeps out from the player.
        public var sweepSpeed: Float
        /// Seconds it shows, its fade included.
        public var duration: Float
        /// Seconds of that it takes to fade at the end.
        public var fadeOut: Float
        /// How far above the ground, water or whatever lies under it the line floats, meters.
        public var lift: Float
        /// **Whether a way that starts behind the player is begun in front of them and turned round** to it.
        public var turnsToFace: Bool
        /// The beam standing up from the place.
        public var beam: Beam
        public var sound: Sound
        /// How loud, 0…1.
        public var volume: Float

        /// **The beam**: a column of light from the place, seen over whatever stands between.
        public struct Beam: Sendable, Equatable, Codable {
            public var isVisible: Bool
            /// Its color, linear.
            public var color: SIMD3<Float>
            public var intensity: Float
            /// How tall, meters.
            public var height: Float
            /// How wide its core is, meters — **at least a few pixels wide, however far off it is**.
            public var width: Float
            /// 0 a flat band with hard edges, 1 a round column, brightest down its middle and soft at its sides.
            public var roundness: Float
            /// How far its glow spreads round the core, 0 none to 1 four times the core's width.
            public var glow: Float
            /// How fast bands of light climb it; 0 still.
            public var flow: Float

            public init(isVisible: Bool = true, color: SIMD3<Float> = SIMD3(1, 0.42, 0.04), intensity: Float = 1.6,
                        height: Float = 70, width: Float = 0.4, roundness: Float = 0.8, glow: Float = 0.5,
                        flow: Float = 1) {
                self.isVisible = isVisible
                self.color = simd_max(color, .zero)
                self.intensity = max(intensity, 0)
                self.height = max(height, 1)
                self.width = max(width, 0.02)
                self.roundness = simd_clamp(roundness, 0, 1)
                self.glow = simd_clamp(glow, 0, 1)
                self.flow = max(flow, 0)
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = Beam()
                self.init(isVisible: (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? d.isVisible,
                          color: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .color)) ?? d.color,
                          intensity: (try? c.decodeIfPresent(Float.self, forKey: .intensity)) ?? d.intensity,
                          height: (try? c.decodeIfPresent(Float.self, forKey: .height)) ?? d.height,
                          width: (try? c.decodeIfPresent(Float.self, forKey: .width)) ?? d.width,
                          roundness: (try? c.decodeIfPresent(Float.self, forKey: .roundness)) ?? d.roundness,
                          glow: (try? c.decodeIfPresent(Float.self, forKey: .glow)) ?? d.glow,
                          flow: (try? c.decodeIfPresent(Float.self, forKey: .flow)) ?? d.flow)
            }
        }

        /// **Fifteen seconds by default**: long enough to take in the way and set off along it.
        public init(pattern: Pattern = .dots, placement: Placement = .floating, color: SIMD3<Float> = SIMD3(1, 0.62, 0.16),
                    intensity: Float = 2.2, width: Float = 0.14, spacing: Float = 1.5, roundness: Float = 1,
                    glow: Float = 0.6, flow: Float = 14, sweepSpeed: Float = 40, duration: Float = 15,
                    fadeOut: Float = 2, lift: Float = 0.15, turnsToFace: Bool = true, beam: Beam = Beam(),
                    sound: Sound = .bell, volume: Float = 0.6) {
            self.pattern = pattern
            self.placement = placement
            self.color = simd_max(color, .zero)
            self.intensity = max(intensity, 0)
            self.width = max(width, 0.02)
            self.spacing = max(spacing, 0.1)
            self.roundness = simd_clamp(roundness, 0, 1)
            self.glow = simd_clamp(glow, 0, 1)
            self.flow = max(flow, 0)
            self.sweepSpeed = max(sweepSpeed, 0.5)
            self.duration = max(duration, 0.5)
            self.fadeOut = simd_clamp(fadeOut, 0, self.duration)
            self.lift = max(lift, 0)
            self.turnsToFace = turnsToFace
            self.beam = beam
            self.sound = sound
            self.volume = simd_clamp(volume, 0, 1)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Look()
            self.init(pattern: (try? c.decodeIfPresent(Pattern.self, forKey: .pattern)) ?? d.pattern,
                      placement: (try? c.decodeIfPresent(Placement.self, forKey: .placement)) ?? d.placement,
                      color: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .color)) ?? d.color,
                      intensity: (try? c.decodeIfPresent(Float.self, forKey: .intensity)) ?? d.intensity,
                      width: (try? c.decodeIfPresent(Float.self, forKey: .width)) ?? d.width,
                      spacing: (try? c.decodeIfPresent(Float.self, forKey: .spacing)) ?? d.spacing,
                      roundness: (try? c.decodeIfPresent(Float.self, forKey: .roundness)) ?? d.roundness,
                      glow: (try? c.decodeIfPresent(Float.self, forKey: .glow)) ?? d.glow,
                      flow: (try? c.decodeIfPresent(Float.self, forKey: .flow)) ?? d.flow,
                      sweepSpeed: (try? c.decodeIfPresent(Float.self, forKey: .sweepSpeed)) ?? d.sweepSpeed,
                      duration: (try? c.decodeIfPresent(Float.self, forKey: .duration)) ?? d.duration,
                      fadeOut: (try? c.decodeIfPresent(Float.self, forKey: .fadeOut)) ?? d.fadeOut,
                      lift: (try? c.decodeIfPresent(Float.self, forKey: .lift)) ?? d.lift,
                      turnsToFace: (try? c.decodeIfPresent(Bool.self, forKey: .turnsToFace)) ?? d.turnsToFace,
                      beam: (try? c.decodeIfPresent(Beam.self, forKey: .beam)) ?? d.beam,
                      sound: (try? c.decodeIfPresent(Sound.self, forKey: .sound)) ?? d.sound,
                      volume: (try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? d.volume)
        }
    }

    /// Meters between the points the line is drawn through.
    public static let step: Float = 0.4
    /// At most this many points — about 1,600 m of way.
    public static let maxPoints = 4_000
    /// **The way is turned round to when it heads further than this from the way the player faces**, radians — behind
    /// and to the sides behind.
    public static let turnAngle: Float = .pi * 0.55
    /// Meters ahead the turn reaches, how far out to the side it swings, and how far along the way it joins it.
    public static let turn: (ahead: Float, out: Float, joins: Float) = (4, 2.2, 6)

    public let look: Look
    /// Where the beam stands: the place.
    public let target: SIMD3<Float>
    /// The line, a point every ``step`` meters from the player, each ``Look/lift`` over what lies under it.
    public let points: [SIMD3<Float>]
    /// How far along the line each point is.
    public let distances: [Float]
    /// Whether the line was begun in front of the player and turned round to the way.
    public let turnedToFace: Bool
    /// Seconds since it was made.
    public private(set) var age: Float = 0

    /// - Parameters:
    ///   - way: the points of the way, the first where the player stands (``way(from:to:grid:surface:searchLimit:)``).
    ///   - facing: the way the player faces, across the ground — the turn is made when the way starts behind it. Nil
    ///     makes none.
    ///   - surface: the height of what the line lies over at a point across the ground — the ground, or water over it.
    ///     The line is never under it.
    public init(way: [SIMD3<Float>], target: SIMD3<Float>, facing: SIMD3<Float>? = nil,
                surface: (SIMD2<Float>) -> Float, look: Look = Look()) {
        self.look = look
        self.target = target
        var route = way
        var turned = false
        if look.turnsToFace, let facing, let turnedRoute = Self.turnedToFace(route, facing: facing) {
            route = turnedRoute
            turned = true
        }
        route = Self.rounded(route, passes: 3)
        var points: [SIMD3<Float>] = [], distances: [Float] = []
        var travelled: Float = 0, next: Float = 0
        for (a, b) in zip(route, route.dropFirst()) {
            let length = simd_distance(a, b)
            while next <= travelled + length && points.count < Self.maxPoints {
                let t = length > 0 ? (next - travelled) / length : 0
                let p = simd_mix(a, b, SIMD3(repeating: t))
                points.append(SIMD3(p.x, max(p.y, surface(SIMD2(p.x, p.z))) + look.lift, p.z))
                distances.append(next)
                next += Self.step
            }
            travelled += length
        }
        if let last = route.last, let end = distances.last, travelled - end > 0.05, points.count < Self.maxPoints {
            points.append(SIMD3(last.x, max(last.y, surface(SIMD2(last.x, last.z))) + look.lift, last.z))
            distances.append(travelled)
        }
        self.points = points
        self.distances = distances
        turnedToFace = turned
    }

    /// The line's length, meters.
    public var length: Float { distances.last ?? 0 }

    public mutating func step(deltaTime: Float) { age += deltaTime }

    /// **Where each mark stands** — one every ``Look/spacing`` along the line, the first a spacing out — with how far along
    /// it is and the way the line heads there. A ``Look/Pattern/line`` has none: it is drawn whole.
    public var marks: [(position: SIMD3<Float>, distance: Float, tangent: SIMD3<Float>)] {
        guard look.pattern != .line, points.count > 1 else { return [] }
        var out: [(position: SIMD3<Float>, distance: Float, tangent: SIMD3<Float>)] = []
        var u = look.spacing, i = 1
        while u <= length + 1e-3 && out.count < Self.maxPoints {
            while i < points.count - 1 && distances[i] < u { i += 1 }
            let a = points[i - 1], b = points[i]
            let span = distances[i] - distances[i - 1]
            let t = span > 0 ? (u - distances[i - 1]) / span : 0
            let heading = b - a
            out.append((simd_mix(a, b, SIMD3(repeating: t)), u,
                        simd_length(heading) > 1e-5 ? simd_normalize(heading) : SIMD3(0, 0, 1)))
            u += look.spacing
        }
        return out
    }

    public var isOver: Bool { age >= look.duration }

    /// **How far the line has swept out**, meters along it.
    public var front: Float { age * look.sweepSpeed }

    /// The whole mark's fade at its end, 1 to 0.
    public var ending: Float {
        look.fadeOut > 0 ? simd_clamp((look.duration - age) / look.fadeOut, 0, 1) : (isOver ? 0 : 1)
    }

    /// How bright the beam is now: up within a third of a second, fading with the rest.
    public var beamOpacity: Float { look.beam.isVisible ? min(age / 0.35, 1) * ending : 0 }

    // MARK: The way

    /// **The way from `start` to `goal`**: `start`, then a path over `grid` to the goal — or, when the goal lies off the
    /// grid, to the furthest point toward it that the grid holds — then straight on to the goal where the path stops
    /// short of it. With no grid, the straight line.
    ///
    /// - Parameter surface: the ground's height across it, where the straight line toward the goal is tried against the
    ///   grid's places.
    public static func way(from start: SIMD3<Float>, to goal: SIMD3<Float>, grid: NavigationGrid?,
                           surface: (SIMD2<Float>) -> Float, searchLimit: Int = 60_000) -> [SIMD3<Float>] {
        var points = [start]
        if let grid, let reach = reachable(toward: goal, from: start, in: grid, surface: surface),
           let path = grid.path(from: start, to: reach, searchLimit: searchLimit) {
            points += path
        }
        if let last = points.last, simd_distance(SIMD2(last.x, last.z), SIMD2(goal.x, goal.z)) > 0.5 {
            points.append(goal)
        }
        return points
    }

    /// The goal if the grid has a place by it; else the point nearest it, on the line from `start`, that it has one by.
    static func reachable(toward goal: SIMD3<Float>, from start: SIMD3<Float>, in grid: NavigationGrid,
                          surface: (SIMD2<Float>) -> Float) -> SIMD3<Float>? {
        if grid.contains(SIMD2(goal.x, goal.z)), grid.place(near: goal) != nil { return goal }
        let across = SIMD2(goal.x, goal.z) - SIMD2(start.x, start.z)
        let length = simd_length(across)
        guard length > 1 else { return nil }
        // Back from the goal toward the start, two meters at a time.
        var along = length - 2
        while along > 0 {
            let p = SIMD2(start.x, start.z) + across * (along / length)
            if grid.contains(p) {
                let point = SIMD3(p.x, surface(p), p.y)
                if grid.place(near: point) != nil { return point }
            }
            along -= 2
        }
        return nil
    }

    /// **The way begun in front of the player and turned round to it**, when it heads off behind them: a curve from
    /// their feet out ``turn``'s `ahead` along the way they face, swinging ``turn``'s `out` to the side the way lies on,
    /// round and back to join the way ``turn``'s `joins` along it, heading as it heads. Nil when the way starts ahead.
    static func turnedToFace(_ way: [SIMD3<Float>], facing: SIMD3<Float>) -> [SIMD3<Float>]? {
        guard let start = way.first, way.count > 1 else { return nil }
        var ahead = SIMD2(facing.x, facing.z)
        guard simd_length(ahead) > 1e-4 else { return nil }
        ahead = simd_normalize(ahead)
        // Where the way heads over its first few meters.
        let (early, _, _) = pointAlong(way, distance: 3)
        var heading = SIMD2(early.x - start.x, early.z - start.z)
        guard simd_length(heading) > 1e-3 else { return nil }
        heading = simd_normalize(heading)
        guard acos(simd_clamp(simd_dot(ahead, heading), -1, 1)) > turnAngle else { return nil }
        // Out to the side the way lies on; straight behind, the right.
        let cross = ahead.x * heading.y - ahead.y * heading.x
        let side = cross < -1e-3 ? SIMD2(ahead.y, -ahead.x) : SIMD2(-ahead.y, ahead.x)
        let (join, index, tangent) = pointAlong(way, distance: turn.joins)
        let s = SIMD2(start.x, start.z), j = SIMD2(join.x, join.z)
        // A cubic from the feet, leaving along the way they face, arriving along the way.
        let p1 = s + ahead * turn.ahead * 1.6 + side * turn.out
        let p2 = j - tangent * turn.joins * 0.9 + side * turn.out * 1.4
        var curve: [SIMD3<Float>] = []
        let steps = 24
        for k in 0...steps {
            let t = Float(k) / Float(steps), u = 1 - t
            let p = u * u * u * s + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * j
            curve.append(SIMD3(p.x, start.y + (join.y - start.y) * t, p.y))
        }
        return curve + way[index...]
    }

    /// The point `distance` along a polyline, the index of the first point after it, and the way it heads there
    /// (across the ground). Past its end, its end.
    static func pointAlong(_ way: [SIMD3<Float>], distance: Float) -> (SIMD3<Float>, Int, SIMD2<Float>) {
        var travelled: Float = 0
        for i in 1..<way.count {
            let a = way[i - 1], b = way[i], length = simd_distance(a, b)
            let flat = SIMD2(b.x - a.x, b.z - a.z)
            let tangent = simd_length(flat) > 1e-4 ? simd_normalize(flat) : SIMD2(0, 1)
            if travelled + length >= distance {
                let t = length > 0 ? (distance - travelled) / length : 0
                return (simd_mix(a, b, SIMD3(repeating: t)), i, tangent)
            }
            travelled += length
        }
        let n = way.count
        let flat = SIMD2(way[n - 1].x - way[n - 2].x, way[n - 1].z - way[n - 2].z)
        return (way[n - 1], n - 1, simd_length(flat) > 1e-4 ? simd_normalize(flat) : SIMD2(0, 1))
    }

    /// **Corners cut** — Chaikin's: each segment's inner half kept, so after a few passes a turn of the grid is a curve.
    /// The ends stay where they are.
    static func rounded(_ way: [SIMD3<Float>], passes: Int) -> [SIMD3<Float>] {
        guard way.count > 2 else { return way }
        var points = way
        for _ in 0..<passes {
            var next = [points[0]]
            for (a, b) in zip(points, points.dropFirst()) {
                next.append(simd_mix(a, b, SIMD3(repeating: 0.25)))
                next.append(simd_mix(a, b, SIMD3(repeating: 0.75)))
            }
            next.append(points[points.count - 1])
            // The first and last cut points sit a quarter in from the ends: drop them so the ends run straight out.
            next.remove(at: 1)
            next.remove(at: next.count - 2)
            points = next
        }
        return points
    }
}

//
//  FootprintTrail.swift
//  Ductane
//

import Foundation
import simd

/// **Where feet have pressed**: a print for each step of each character a game reports — left, right, turned the way
/// the foot went, spaced by how fast it went — and how much of each the weather has wiped since.
///
/// **Prints last until the weather wipes them.** One clock, ``wiped``, runs at ``wipeRate(_:)``: slowly in calm weather
/// (a print is gone in about half an hour), fast while snow falls (it fills prints in) or rain falls (it washes them out
/// of mud). A print keeps where the clock stood when it was made, so how much is left of it is one subtraction, whatever
/// the weather did in between. A thaw takes prints in snow with the snow itself: they show only where snow lies.
///
/// **Only those near the viewer are kept** (``forget(beyond:of:)``), at most ``maximumPrints``: a game asks for the
/// trail round its eye, and each player's game keeps its own.
///
/// What it does not do: draw. ``FootprintGrid`` hands the prints near the eye to a shader, which works out their shapes;
/// where they show — in snow, in soft ground — is the renderer's.
public nonisolated struct FootprintTrail: Sendable {

    /// **A print's shape**: boots unless a game says otherwise.
    public enum Shape: String, Sendable, Codable, CaseIterable {
        case boot, bare
    }

    /// **One print.**
    public struct Print: Sendable, Equatable {
        /// Its middle on the ground, x and z.
        public var position: SIMD2<Float>
        /// How high the foot stood, metres: a print shows only on what is that high — the deck, not the roof over it.
        public var height: Float
        /// Which way the foot pointed, radians: 0 along −z, as the engine's yaw.
        public var heading: Float
        public var isLeft: Bool
        public var shape: Shape
        /// Where ``FootprintTrail/wiped`` stood when it was made.
        public var made: Double
        /// How hard it was pressed, 0…1: a run presses harder than a walk.
        public var weight: Float
    }

    /// Every print kept, oldest first.
    public private(set) var prints: [Print] = []
    /// **The weather's wiping, so far**: one whole is a print gone.
    public private(set) var wiped: Double = 0

    /// What is kept at most; the oldest go first.
    public static let maximumPrints = 8192
    /// How far a foot is set from the middle of the body, metres.
    public static let footSpacing: Float = 0.11
    /// How far a character must move between prints, metres: a walk's stride, longer as it goes faster.
    public static func stride(atSpeed speed: Float) -> Float { min(max(0.55 + speed * 0.09, 0.6), 1.5) }

    /// Each character's last print: where, and which foot is next.
    private var steps: [Int: (at: SIMD2<Float>, left: Bool)] = [:]

    public init() {}

    // MARK: The weather

    /// **How fast the weather wipes prints**, wholes a second: about half an hour in calm weather, a few minutes in
    /// heavy snow, two in a downpour.
    public static func wipeRate(_ weather: Weather) -> Double {
        let s = weather.settings
        let calm = 1.0 / 1800
        let falling = Double(s.precipitation)
        return calm + (s.snow ? falling / 180 : falling / 120)
    }

    /// Runs the wiping clock on by `seconds` of `weather`, and lets go of prints wiped away.
    public mutating func advance(seconds: Double, weather: Weather) {
        guard seconds > 0, seconds.isFinite else { return }
        wiped += seconds * Self.wipeRate(weather)
        if let first = prints.first, wiped - first.made >= 1 {
            prints.removeAll { wiped - $0.made >= 1 }
        }
    }

    /// How much is left of `print`, 0…1.
    public func strength(of print: Print) -> Float {
        Float(max(0, min(1, 1 - (wiped - print.made)))) * print.weight
    }

    // MARK: Steps

    /// **Where character `id` stands now**: a print is made each time it has gone a stride from its last, on the next
    /// foot, beside where it is, turned the way it went. In the air it makes none; landing starts again.
    ///
    /// - Parameters:
    ///   - id: any number the game keeps for the character.
    ///   - speed: how fast it is going, metres a second — what spaces the prints and how hard they press.
    public mutating func step(character id: Int, feet: SIMD3<Float>, speed: Float, onGround: Bool = true,
                              shape: Shape = .boot) {
        let here = SIMD2(feet.x, feet.z)
        guard onGround, feet.x.isFinite, feet.z.isFinite else {
            steps[id] = nil
            return
        }
        guard let last = steps[id] else {
            steps[id] = (here, true)
            return
        }
        let travelled = here - last.at
        let distance = simd_length(travelled)
        if distance > 6 {
            // Carried, not walked — a teleport, a respawn: no trail across the gap.
            steps[id] = (here, last.left)
            return
        }
        guard distance >= Self.stride(atSpeed: speed) else { return }
        let along = travelled / distance
        let side = SIMD2(-along.y, along.x)   // to the right of the way it went
        let heading = atan2(along.x, -along.y)
        let at = here + side * (last.left ? -Self.footSpacing : Self.footSpacing)
        prints.append(Print(position: at, height: feet.y, heading: heading, isLeft: last.left, shape: shape, made: wiped,
                            weight: min(1, 0.75 + speed * 0.04)))
        if prints.count > Self.maximumPrints { prints.removeFirst(prints.count - Self.maximumPrints) }
        steps[id] = (here, !last.left)
    }

    /// A character gone from the world: its next step starts a new trail.
    public mutating func remove(character id: Int) { steps[id] = nil }

    /// **Lets go of prints farther than `radius` from `centre`** — those past the map a renderer draws.
    public mutating func forget(beyond radius: Float, of centre: SIMD3<Float>) {
        let c = SIMD2(centre.x, centre.z), r2 = radius * radius
        if prints.contains(where: { simd_length_squared($0.position - c) > r2 }) {
            prints.removeAll { simd_length_squared($0.position - c) > r2 }
        }
    }
}

//
//  Volume.swift
//  Ductane
//

import simd

/// Something a round can hit: an extent, and where it currently is. **No mesh.**
///
/// **This is the separation `SceneObject` used not to make.** A scene object couples an `MTKMesh`
/// with a `BoundingBox`, which is right for something you both draw and shoot at — and wrong for
/// everything you only shoot at. While the hit test took scene objects, *owning a GPU mesh was the
/// price of being hittable*, and anything that could not pay it had to bring its own.
///
/// One game paid that price twice. Its logic package builds and tests without Metal, so its targets
/// could not be scene objects, so each hand-rolled its own world bounds — and firing one round ran
/// four hit tests where three were the same box-against-segment code. A scene where things *move*
/// turns that from untidy into untenable: if every crate, rail and hatch on a moving deck is its own
/// special case, each brings its own bounds and its own loop.
///
/// So a volume is an extent plus a transform, with no opinion about drawing. `SceneObject` owns one;
/// a game's own moving things own one; and ``firstHit(segmentFrom:to:against:)`` tests a shot once
/// against everything that can stop it.
///
/// > The extraction rule was met before this moved in: it arrived as working, tested code, with the
/// > duplication it removes already visible in a second consumer.
public nonisolated struct Volume: Equatable, Sendable {

    /// The extent in model space — the thing's own size, before it is placed anywhere.
    public let localBounds: BoundingBox

    /// Where it is now. For anything on a deck this is recomputed as the deck moves.
    public var transform: simd_float4x4

    public init(localBounds: BoundingBox, transform: simd_float4x4 = matrix_identity_float4x4) {
        self.localBounds = localBounds
        self.transform = transform
    }

    /// Where it is in the world, recomputed from the transform.
    ///
    /// **Computed, not stored, and that is the difference that matters.** `SceneObject` used to
    /// store its world bounds at init, which was correct only because its transform never changed —
    /// the moment something moves, a stored box is a box where the thing used to be, and a round
    /// passes through a crate that is visibly in the way.
    public var worldBounds: BoundingBox { localBounds.transformed(by: transform) }

    /// The first volume a shot's step passes through, and how far along it.
    ///
    /// **One loop, whatever the thing is.** That is the whole point: static scenery, a moving crate
    /// and a sentry are the same question to a bullet, and they are only asked separately when they
    /// cannot be put in one array.
    ///
    /// Tested as a *segment* rather than a point because a round moves several meters per simulation
    /// step — checking only where it ended up lets it pass clean through anything thinner than that.
    public static func firstHit(segmentFrom start: SIMD3<Float>,
                                to end: SIMD3<Float>,
                                against volumes: [Volume]) -> (index: Int, distance: Float)? {
        var best: (index: Int, distance: Float)?
        for (index, volume) in volumes.enumerated() {
            if let distance = volume.worldBounds.hitDistance(ofSegmentFrom: start, to: end) {
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
        }
        return best
    }

    /// The nearest volume along a ray, and how far away it is.
    ///
    /// The same list serves this and the segment form on purpose. **Ranging and hitting must agree
    /// about what is out there** — a reticle that reads the ground behind something the round will
    /// stop against is worse than no readout, because the player acts on it.
    public static func firstHit(origin: SIMD3<Float>,
                                direction: SIMD3<Float>,
                                against volumes: [Volume],
                                maxDistance: Float = .greatestFiniteMagnitude) -> (index: Int, distance: Float)? {
        var best: (index: Int, distance: Float)?
        for (index, volume) in volumes.enumerated() {
            if let distance = volume.worldBounds.hitDistance(ofRayFrom: origin,
                                                              direction: direction,
                                                              maxDistance: maxDistance) {
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
        }
        return best
    }

    /// ``firstHit(segmentFrom:to:against:)`` with **where it landed and which way that surface faces** — for a
    /// mark left on what the shot struck (``DecalSet/mark(at:normal:size:uvRect:tint:)``), a ricochet, or sparks
    /// thrown off the face rather than back along the shot.
    ///
    /// The face is one of the volume's world bounds, the same box the distance comes from: a volume turned on
    /// a deck is hit, and faced, as the axis-aligned box round it. A segment of no length enters nothing.
    public static func firstSurfaceHit(segmentFrom start: SIMD3<Float>, to end: SIMD3<Float>,
                                       against volumes: [Volume]) -> SurfaceHit? {
        let length = simd_distance(start, end)
        guard length > 0 else { return nil }
        return firstSurfaceHit(origin: start, direction: (end - start) / length, against: volumes, maxDistance: length)
    }

    /// ``firstHit(origin:direction:against:maxDistance:)`` with where it landed and which way that surface faces.
    /// Distances are in multiples of `direction`'s length, as there.
    public static func firstSurfaceHit(origin: SIMD3<Float>, direction: SIMD3<Float>, against volumes: [Volume],
                                       maxDistance: Float = .greatestFiniteMagnitude) -> SurfaceHit? {
        var best: SurfaceHit?
        for (index, volume) in volumes.enumerated() {
            if let hit = volume.worldBounds.hit(ofRayFrom: origin, direction: direction, maxDistance: maxDistance),
               best == nil || hit.distance < best!.distance {
                best = SurfaceHit(index: index, distance: hit.distance, point: origin + direction * hit.distance,
                                  normal: hit.normal)
            }
        }
        return best
    }
}

/// **What a shot struck, where, and which way that surface faces** — the answer a hit test gives when a game
/// needs more than how far: a mark laid flat on the face (``DecalSet``), dust thrown off it, a round glancing away.
public nonisolated struct SurfaceHit: Equatable, Sendable {
    /// Which of the things asked was struck: the volume's index in the list given, or the triangle's in a
    /// ``CollisionMesh``.
    public var index: Int
    /// How far along the shot, in multiples of the direction's length — metres for a unit direction or a segment.
    public var distance: Float
    /// Where it landed.
    public var point: SIMD3<Float>
    /// The struck surface's unit normal, facing the side the shot came from.
    public var normal: SIMD3<Float>

    public init(index: Int, distance: Float, point: SIMD3<Float>, normal: SIMD3<Float>) {
        self.index = index
        self.distance = distance
        self.point = point
        self.normal = normal
    }
}

//
//  GroundCover.swift
//  Ductane
//

import simd

/// **Ground cover: grass, flowers, crops — the carpet a scene is planted with**, which a player's
/// ``GraphicsSettings/plantDensity`` thins first.
///
/// **By its shape, unless a person has said otherwise.** A prop drawn all in cut-out cards that is low (``height``) or far
/// wider than it is tall is ground cover; size alone does not tell it, since one pack's grass clumps are one to seven
/// metres across and its large grass patches thirty-four. The shape gets most of a pack right and a few wrong at its
/// edges — a tall stand of flowers just over the line — so a scene keeps what a person set for a prop
/// (``WorldScene/groundCover``, ``WorldFile/groundCover``), and that wins.
///
/// Trees and bushes are never ground cover: thinning them changes the world, not its cost.
public nonisolated enum GroundCover {
    /// Metres under which a cut-out prop is ground cover.
    public static let height: Float = 1.6

    /// Low, or more than three times wider than it is tall — the size half of the rule.
    public static func isLowOrWide(_ size: SIMD3<Float>) -> Bool {
        size.y < height || max(size.x, size.z) > size.y * 3
    }

    /// Ground cover by shape: drawn all in cut-out cards, and low or spread wide.
    public static func byShape(size: SIMD3<Float>, cutOut: Bool) -> Bool {
        cutOut && isLowOrWide(size)
    }
}

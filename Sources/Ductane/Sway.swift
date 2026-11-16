//
//  Sway.swift
//  Ductane
//

import Foundation

/// **How a prop moves in the wind** (2026-11-16): a tree bends from its trunk with its leaves fluttering, a plant — grass,
/// reeds, a bush — bends harder, cloth — a flag, a banner, a tarp — ripples, and anything else stands still. With the
/// weather's wind (``Weather/foliageWind(at:)``), gently on a calm day and thrashing in a storm, its shadow moving with it.
///
/// **Guessed from the prop's name** (``guess(name:)``) and set per prop where the guess is wrong: an editor keeps the
/// answer, and a world file carries it (``WorldFile/sway``). A renderer moves the vertices in its vertex stage — a tree from
/// its root, more toward the top; a plant all of it; cloth the more the further from its pole — so nothing about a prop's
/// files changes.
public nonisolated enum Sway: String, Sendable, Codable, CaseIterable {
    /// Bends from the root, more toward the top, leaves fluttering.
    case tree
    /// Bends harder, all of it: grass, reeds, ferns, a bush.
    case plant
    /// Ripples and billows: flags, banners, tarps, awnings, hanging hides.
    case cloth
    /// Does not move.
    case still

    /// Whether it moves at all.
    public var moves: Bool { self != .still }

    /// **The guess from a prop's name** — its words (``Foliage/words(_:)``). Cloth words first, then a tree (dead and bare
    /// ones too: their branches move), then plants; anything else still. A log, stump or trunk lying down is still.
    public static func guess(name: String) -> Sway {
        let words = Set(Foliage.words(name))
        if !words.isDisjoint(with: ["flag", "flags", "banner", "banners", "tarp", "tarps", "tarpaulin", "awning", "awnings",
                                    "cloth", "cloths", "curtain", "curtains", "drape", "drapes", "sail", "sails", "rag",
                                    "rags", "laundry", "washing", "pennant", "pennants", "bunting", "hide", "hides", "pelt",
                                    "pelts", "canvas", "sheet", "sheets", "windsock", "streamer", "streamers"]) {
            return .cloth
        }
        if !words.isDisjoint(with: ["stump", "stumps", "log", "logs", "trunk", "trunks", "fallen", "driftwood"]) { return .still }
        if !words.isDisjoint(with: ["tree", "trees", "pine", "pines", "fir", "spruce", "cedar", "palm", "palms", "oak",
                                    "birch", "maple", "willow", "beech", "elm", "aspen", "poplar", "sapling", "saplings",
                                    "cypress", "redwood", "larch", "sycamore"]) {
            return .tree
        }
        if !words.isDisjoint(with: ["grass", "grasses", "reed", "reeds", "cattail", "cattails", "fern", "ferns", "bush",
                                    "bushes", "shrub", "shrubs", "plant", "plants", "flower", "flowers", "weed", "weeds",
                                    "wheat", "crop", "crops", "corn", "rush", "rushes", "sedge", "vine", "vines", "ivy",
                                    "leaf", "leaves", "foliage", "hedge", "hedges", "bramble", "brambles", "bamboo"]) {
            return .plant
        }
        return .still
    }
}

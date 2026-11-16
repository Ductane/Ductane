//
//  PropLevels.swift
//  Ductane
//

import Foundation

/// **A prop's own coarser levels of detail, as files beside it**: `Tree.usda` is the prop, and `Tree.LOD1.usda`,
/// `Tree.LOD2.usda`… are its maker's simpler versions of it, finest first.
///
/// **Why a vendor's, when ``MeshDetail`` makes levels of its own.** A tree's canopy is leaf cards, and simplifying cards
/// takes them away: at the second level made that way half a big tree's canopy had gone, so its error never let a level
/// be used and every tree in a wooded zone drew all 25,000 triangles at any distance — most of the frame. A pack's own
/// levels keep the canopy's shape with fewer, larger cards. A prop with none still gets ``MeshDetail``'s.
///
/// **Separate files, not variants in one**: any USD tool opens `Tree.usda` and sees the tree, exactly as before; the
/// levels are ordinary files that nothing else has to know about.
public nonisolated enum PropLevels {

    /// Where level `level` (1 and up) of `prop` is, whether or not it is there.
    public static func url(of prop: URL, level: Int) -> URL {
        prop.deletingLastPathComponent()
            .appending(path: prop.deletingPathExtension().lastPathComponent + ".LOD\(level).usda")
    }

    /// Whether a file is a prop's level rather than a prop.
    public static func isLevel(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.firstMatch(of: /\.LOD\d+$/) != nil
    }

    /// The levels `prop` has on disk, from 1 up, stopping at the first missing.
    public static func levels(of prop: URL) -> [URL] {
        var found: [URL] = []
        while case let next = url(of: prop, level: found.count + 1), FileManager.default.fileExists(atPath: next.path) {
            found.append(next)
        }
        return found
    }
}

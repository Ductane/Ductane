//
//  WorldPackage.swift
//  Ductane
//

import Foundation
import simd

/// **A scene package, opened for a game**: a `.usdz` holding a scene, every prop it places with its textures, and the
/// world description a game reads (``WorldFile``, at ``descriptionPath``), with the ground and collision shapes beside
/// it. A world editor writes one; a game ships it as a resource and opens it here.
///
/// **Unpacked once, kept until the package changes.** ``MeshLoader`` and ``TextureStore`` read files by URL, and a prop
/// inside a package has none of its own, so a `.usdz` is unpacked into a folder of the app's own caches and read from
/// there. The next launch finds it unpacked and uses it as it is; a package of another size or date unpacks again,
/// replacing what was there. A folder holding the same files — a package unzipped — is read in place.
///
/// **A package is data from anyone**: an entry naming a path outside the package (absolute, or climbing out with `..`)
/// is refused, never written; so is a description naming a file outside it, and ``WorldFile/read(_:)`` checks every
/// index and the ground's size, so nothing read through a package traps or overflows.
public nonisolated struct WorldPackage: Sendable {

    /// Where a package keeps its world description.
    public static let descriptionPath = "game/world.json"

    /// The package that was opened.
    public let source: URL
    /// Where its files are: the unpacked copy, or the folder itself.
    public let folder: URL
    /// What it describes.
    public let world: WorldFile
    /// **What changed since the copy this one replaced**: the paths inside the package whose bytes differ from that copy,
    /// or that it did not have — a world editor's newer export of the world a game is showing, handed to
    /// ``WorldRenderer/show(_:loaded:)`` so only what changed is read again. Empty when the copy unpacked before was used
    /// as it was; nil when there was no copy before, or the package is a folder read in place.
    public let changedFiles: Set<String>?

    /// Opens the package at `url` — a `.usdz` or a folder.
    /// - Parameter cache: where a `.usdz` is unpacked; by default the app's own caches (``defaultCache``).
    public init(contentsOf url: URL, cache: URL? = nil) throws {
        source = url
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw OpenError.missing(url.path) }
        if isFolder.boolValue {
            folder = url
            changedFiles = nil
        } else {
            guard let cache = cache ?? Self.defaultCache else { throw OpenError.noCache }
            (folder, changedFiles) = try Self.unpack(url, into: cache)
        }
        let description = folder.appending(path: Self.descriptionPath)
        guard FileManager.default.fileExists(atPath: description.path) else { throw OpenError.noDescription(url.lastPathComponent) }
        // Its paths are checked as it is read (`WorldFile.read`): every file it names stays inside the package.
        world = try WorldFile.read(Data(contentsOf: description))
    }

    /// The app's own caches, in a folder of their own — the container's when sandboxed.
    public static var defaultCache: URL? { CompressedTextures.appCache(named: "Worlds") }

    /// A file of the package, by its path inside it.
    public func url(of path: String) -> URL { folder.appending(path: path) }

    /// A prop's file, by its index in ``WorldFile/props``.
    public func propURL(_ index: Int) -> URL { url(of: world.props[index]) }

    /// The folder a prop's file is in — where the textures its look names are found.
    public func propFolder(_ index: Int) -> URL { propURL(index).deletingLastPathComponent() }

    /// The ground, read from its files; nil when the world has none.
    public func ground() throws -> WorldGround? {
        guard let description = world.ground else { return nil }
        return try WorldGround(description, heights: Data(contentsOf: url(of: description.heights)),
                               colours: Data(contentsOf: url(of: description.colours)),
                               holes: try description.holes.map { try Data(contentsOf: url(of: $0)) })
    }

    /// The ground's painted weights, a point at a time (``WorldFile/Ground/weights``); nil when it was never painted.
    public func groundWeights() throws -> [SIMD8<UInt8>]? {
        guard let ground = world.ground, let path = ground.weights else { return nil }
        let points = (ground.resolution + 1) * (ground.resolution + 1)
        guard let weights = WorldFile.Ground.weights(try Data(contentsOf: url(of: path)), points: points) else {
            throw WorldFile.ReadError.wrongWeights(path)
        }
        return weights
    }

    /// Every collision shape, by prop: triangles in the prop's own space.
    public func collisionShapes() throws -> [Int: [SIMD3<Float>]] {
        var shapes: [Int: [SIMD3<Float>]] = [:]
        for (prop, path) in world.collisionShapes where world.props.indices.contains(prop) {
            shapes[prop] = try WorldFile.CollisionShape.triangles(Data(contentsOf: url(of: path)))
        }
        return shapes
    }

    // MARK: Unpacking

    /// The name of the file beside an unpacked copy saying which package it came from.
    static let stampName = ".package"

    /// Unpacks `package` into a folder of `cache` named after it, unless the copy there came from the same package —
    /// the same size and date. Returns the folder, and the paths whose bytes differ from the copy it replaced (nil when
    /// there was none).
    static func unpack(_ package: URL, into cache: URL) throws -> (folder: URL, changed: Set<String>?) {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: package.path)
        let size = (attributes[.size] as? Int) ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let stamp = "\(size) \(modified)"
        let folder = cache.appending(path: package.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
        if (try? String(contentsOf: folder.appending(path: stampName), encoding: .utf8)) == stamp { return (folder, []) }
        let hadCopy = fm.fileExists(atPath: folder.appending(path: stampName).path)
        var changed: Set<String> = []

        // Unpacked beside it first and moved into place whole, so a copy cut short is never taken for a finished one.
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appending(path: ".\(folder.lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let data = try Data(contentsOf: package, options: .alwaysMapped)
        for (name, range) in try USDZArchive.entries(in: data) {
            guard let path = Self.safePath(name) else { throw OpenError.unsafeEntry(name) }
            if path.hasSuffix("/") { continue }
            let target = staging.appending(path: path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entry = data.subdata(in: range)
            try entry.write(to: target)
            // Compared with the copy being replaced, so a game showing it reads again only what changed.
            if hadCopy, (try? Data(contentsOf: folder.appending(path: path), options: .alwaysMapped)) == entry { continue }
            changed.insert(path)
        }
        try Data(stamp.utf8).write(to: staging.appending(path: stampName))
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
        return (folder, hadCopy ? changed : nil)
    }

    /// An entry's path if it stays inside the package: relative, no `..` or `.` parts, nothing empty but a folder's end.
    static func safePath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if part == ".." || part == "." { return nil }
            if part.isEmpty && i != parts.count - 1 { return nil }
        }
        return name
    }

    public enum OpenError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case noCache
        case noDescription(String)
        case unsafeEntry(String)
        public var description: String {
            switch self {
            case .missing(let path): "no scene package at \(path)"
            case .noCache: "no caches folder to unpack the scene package into"
            case .noDescription(let name): "\(name) holds no world description (\(WorldPackage.descriptionPath)) — export it again"
            case .unsafeEntry(let name): "the scene package names a file outside itself: \(name)"
            }
        }
    }
}

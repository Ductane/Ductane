//
//  WorldRenderer+Package.swift
//  Ductane
//

import Foundation
import simd

public extension WorldRenderer {

    /// **Shows a scene package** (``WorldPackage``) — what a world editor exported — as its author saw it: its scene
    /// (``WorldScene/init(_:)``), its ground (``WorldPackage/groundSource()``), what its props' materials draw as liquids
    /// and grime, the shapes its walkers meet. Its props load in the background, appearing as they arrive; `loaded` hears
    /// the ones that failed once they are all in, and the far shadows are fitted to the world (``fitExtent()``).
    ///
    /// ```swift
    /// let world = try WorldRenderer(engine: engine)
    /// try world.show(WorldPackage(contentsOf: Bundle.main.url(forResource: "Meadow", withExtension: "usdz")!))
    /// ```
    func show(_ package: WorldPackage, loaded: @escaping (_ failures: [(URL, Error)]) -> Void = { _ in }) throws {
        let world = package.world
        let urls = world.props.indices.map(package.propURL)
        var liquids: [URL: [String: (look: WorldFile.Liquid.Look, textures: [String: URL])]] = [:]
        for liquid in world.liquids where urls.indices.contains(liquid.prop) {
            let folder = package.propFolder(liquid.prop)
            var textures: [String: URL] = [:]
            for name in liquid.look.textureFiles { textures[name] = folder.appending(path: name) }
            liquids[urls[liquid.prop], default: [:]][liquid.material] = (liquid.look, textures)
        }
        var grime: [URL: [String: (look: WorldFile.Grime.Look, map: URL)]] = [:]
        for dirt in world.grime where urls.indices.contains(dirt.prop) {
            grime[urls[dirt.prop], default: [:]][dirt.material] = (dirt.look, package.propFolder(dirt.prop).appending(path: dirt.look.texture))
        }
        var shapes: [URL: [SIMD3<Float>]] = [:]
        for (prop, triangles) in try package.collisionShapes() where urls.indices.contains(prop) { shapes[urls[prop]] = triangles }
        self.liquids = { liquids[$0] ?? [:] }
        self.grime = { grime[$0] ?? [:] }
        self.collisionShape = { shapes[$0] }
        scene = WorldScene(package)
        showGround(try package.groundSource())
        loadPropsInBackground { [weak self] failures, _ in
            self?.fitExtent()
            loaded(failures)
        }
    }
}

//
//  WorldRenderer.swift
//  Ductane
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import ModelIO
import simd

/// **Draws a world**: the ground, painted, with its holes, puddles and fallen leaves; every placed prop and scattered copy,
/// instanced, culled and levelled by their size on screen — far ones as their far pictures; the sky, the night sky and
/// the clouds; the sun's shadows; point lights; still water and streams; living effects; the weather — rain, snow lying
/// and built up on props, wet ground, footprints, lightning; volumetric and ground fog; the seasons' colours and the wind
/// in what moves. One ``GameLoop``: the engine owns frame pacing, the HDR target and the tone map, this the passes.
///
/// **What it draws is a ``WorldScene``** — a game's from its scene package (``WorldScene/init(_:)``), an editor's from its
/// own scene each time it changes — and **a ground** (``showGround(_:changed:)``). A game sets ``camera`` each frame, and
/// either hands the renderer to the engine as its game or calls these `GameLoop` methods from its own, drawing its own
/// things after them.
///
/// **One renderer for the editor and the game**: a world editor draws its viewport with this too, so what the author sees
/// is what a player sees. What only an editor draws — handles, selection outlines, markers — it draws itself, over the
/// top (``encodeSilhouette(of:wearing:transform:scale:into:)`` gives it a selection's shape to outline).
public final class WorldRenderer: GameLoop {

    public let engine: FrameRenderer
    public var device: MTLDevice { engine.device }

    /// **Where the world is seen from**: set each frame, before it is drawn.
    public var camera = View()

    /// **A camera, as the renderer needs it**: the eye and where it looks, how far that is (the fog and the grid count
    /// from there, so an editor's view from high above is not lost in its own fog; 0 or a metre for a first-person eye),
    /// the view matrix and the lens.
    public nonisolated struct View: Sendable, Equatable {
        public var eye: SIMD3<Float>
        public var target: SIMD3<Float>
        public var distance: Float
        public var viewMatrix: simd_float4x4
        /// Vertical, radians.
        public var fieldOfView: Float
        /// The near plane, metres: the projection has no far one (reversed-Z).
        public var nearZ: Float

        public init(eye: SIMD3<Float> = SIMD3(0, 10, 20), target: SIMD3<Float> = .zero, distance: Float? = nil,
                    viewMatrix: simd_float4x4? = nil, fieldOfView: Float = 40 * .pi / 180, nearZ: Float = 0.05) {
            self.eye = eye
            self.target = target
            self.distance = distance ?? simd_distance(eye, target)
            self.viewMatrix = viewMatrix ?? Self.lookAt(eye: eye, target: target)
            self.fieldOfView = fieldOfView
            self.nearZ = nearZ
        }

        /// **What a ``Camera`` sees** — a game's first-person or flying camera, with its lens: the fog counted from the eye.
        public init(_ camera: Camera, fieldOfView: Float = 60 * .pi / 180, nearZ: Float = 0.05) {
            self.init(eye: camera.position, target: camera.position + camera.forward, distance: 0,
                      viewMatrix: camera.viewMatrix, fieldOfView: fieldOfView, nearZ: nearZ)
        }

        public func projectionMatrix(aspectRatio: Float) -> simd_float4x4 {
            simd_float4x4(perspectiveFovY: fieldOfView, aspectRatio: aspectRatio, nearZ: nearZ)
        }

        static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
            let forward = simd_normalize(target - eye)
            let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
            let up = simd_cross(right, forward)
            return simd_float4x4(columns: (SIMD4(right.x, up.x, -forward.x, 0), SIMD4(right.y, up.y, -forward.y, 0),
                                           SIMD4(right.z, up.z, -forward.z, 0),
                                           SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)))
        }
    }

    // MARK: What to draw

    /// **The world drawn**: set again whenever it changes. A placement or scattered copies moved — a drag — redo only
    /// those; anything else gathers its copies again.
    public var scene = WorldScene() {
        // Arrays that share storage compare at once, so a scene handed back unchanged costs nothing here.
        didSet {
            // Fall colors: what each prop does through the year, and where fallen leaves lie, follow what it changes.
            if oldValue.foliage != scene.foliage || oldValue.guessesByName != scene.guessesByName { foliageKinds = [:] }
            if oldValue.sway != scene.sway || oldValue.guessesByName != scene.guessesByName
                || oldValue.materialSway != scene.materialSway {
                swayKinds = [:]
                materialSwayKinds = [:]
                forgetTurning()
                rebakeFarPicturesForSway()
                // What rolls is drawn apart from what stands, so both are gathered again.
                placedCopies = nil
                scatteredCopies = nil
                rollingStale = true
            }
            if oldValue.placements != scene.placements || oldValue.scatters != scene.scatters { rollingStale = true }
            if oldValue.foliage != scene.foliage || oldValue.placements != scene.placements
                || oldValue.scatters != scene.scatters { litterStale = true }
            // **A placement dragged changes that placement's copy only**, as a scattered copy's does below.
            if oldValue.placements != scene.placements, !updatePlacedCopies(from: oldValue.placements) {
                placedCopies = nil
            }
            if let moves = knownMoves {
                knownMoves = nil
                if placeAgain(moves) { return }
            }
            guard oldValue.scatters != scene.scatters else { return }
            // **A copy moved, turned or scaled — a drag — changes those copies only**; anything else gathers every copy
            // again, which was 230 ms of each drag tick in a Debug build.
            if !updateScatteredCopies(from: oldValue.scatters) {
                scatteredCopies = nil
            }
        }
    }

    /// A prop's meshes, loaded once however many times it is placed.
    struct PropMeshes {
        let meshes: [ShownMesh]
        /// In the prop's own space: what picking and framing use.
        let bounds: BoundingBox
        /// How far each lower-detail level strays, in the prop's metres — the worst of its meshes'. Level `i + 1`'s
        /// is `detailErrors[i]`; empty when the prop has none (Ductane's `MeshDetail`), or its own levels.
        let detailErrors: [Float]
        /// **Drawn all in cut-out cards** — every submesh of its finest meshes clips against its texture — the shape half
        /// of telling ground cover (``GroundCover/byShape(size:cutOut:)``).
        var isCutOut: Bool {
            let cutoffs = meshes.flatMap(\.cutoffs)
            return !cutoffs.isEmpty && cutoffs.allSatisfy { $0 > 0 }
        }
        /// **The prop's own coarser levels** (``PropLevels``), finest first: level `i + 1` draws `levels[i]` whole.
        /// When there are any, they are the levels, chosen by size on screen, and none are made by simplifying it.
        var levels: [[ShownMesh]] = []
        /// Triangles at each level, the prop itself first — what the levels are chosen by.
        var levelTriangles: [Int] = []
        /// Its far picture (``Impostor``), for a prop heavy enough to want one; nil for the rest. A scattered prototype
        /// wearing other materials has its own, baked from it dressed (``scatteredProp(_:wearing:)``); a placement none.
        var impostor: Impostor?

        /// What to draw at a level: the meshes, and the level to take each submesh's triangles at — the prop's own
        /// level's meshes whole, or its meshes at a level made by simplifying it.
        func meshes(at level: Int) -> (meshes: [ShownMesh], tier: Int) {
            guard level > 0, !levels.isEmpty else { return (meshes, level) }
            return (levels[min(level, levels.count) - 1], 0)
        }
    }

    struct ShownMesh {
        let loaded: LoadedMesh
        /// One base-colour map per submesh, the store's white where there is none.
        let baseMaps: [MTLTexture]
        /// One emission map per submesh, white where there is none — the material's emission says how much.
        let glowMaps: [MTLTexture]
        /// Per submesh, the alpha below which it is cut out — a leaf, a blade of grass — or 0 where it is solid.
        let cutoffs: [Float]
        /// Per submesh, whether it is see-through — glass: an opacity below one and no cut-out (``isSeeThrough(_:)``).
        let seeThrough: [Bool]
        /// Per submesh, the material it is drawn in: its own, or what a placement wears instead (``dressed(_:wearing:)``).
        var materials: [Ductane.Material] = []
        /// Which look it is drawn in — 0 its own; one number for each other set of materials — so their uniforms differ.
        var look = 0
        /// Per submesh, the liquid it is drawn as (``WorldFile/Liquid``), or nil — a liquid is see-through too, and drawn after
        /// the solid scene, reading its depth. Empty for a mesh with none.
        var liquids: [LiquidLook?] = []
        /// Per submesh, the grime laid over it by where it is (``WorldFile/Grime``), or nil. Empty for a mesh with none.
        var grunge: [GrungeLook?] = []
        /// Lower-detail levels: `detail[level - 1][submesh]`, each level with its own vertices (`MeshDetail.Tier`).
        let detail: [[IndexRange]]
        /// The one buffer those levels live in — held here so it can be retired with the prop (``retire(_:)``): the
        /// ranges keep only addresses, and the residency set alone kept it alive, for ever.
        var detailBuffer: MTLBuffer?

        /// The liquid a submesh is drawn as, if any.
        func liquid(_ submesh: Int) -> LiquidLook? { liquids.indices.contains(submesh) ? liquids[submesh] : nil }
        /// The grime on a submesh, if any.
        func grime(_ submesh: Int) -> GrungeLook? { grunge.indices.contains(submesh) ? grunge[submesh] : nil }

        /// The material a submesh is drawn in.
        func material(_ submesh: Int) -> Ductane.Material {
            materials.indices.contains(submesh) ? materials[submesh] : loaded.material(forSubmesh: submesh)
        }

        /// A submesh's triangles at a level of detail, 0 being the full mesh.
        func indices(submesh: Int, level: Int) -> IndexRange {
            guard level > 0, !detail.isEmpty else { return IndexRange(loaded.mesh.submeshes[submesh]) }
            return detail[min(level, detail.count) - 1][submesh]
        }
    }

    /// **A liquid's look, loaded** (``WorldFile/Liquid``): its numbers, its textures, and its place in the frame's liquid
    /// uniforms. One per material of a prop file, shared by every copy.
    final class LiquidLook {
        let look: WorldFile.Liquid.Look
        let sheet: MTLTexture
        let noise: MTLTexture
        let normals: MTLTexture
        let index: Int
        init(look: WorldFile.Liquid.Look, sheet: MTLTexture, noise: MTLTexture, normals: MTLTexture, index: Int) {
            self.look = look
            self.sheet = sheet
            self.noise = noise
            self.normals = normals
            self.index = index
        }
    }

    /// **A material's grime, loaded** (``WorldFile/Grime``): its map, and its numbers where `propFragment` reads them — written
    /// once, as nothing about it changes. One per look, shared by every prop that wears it.
    final class GrungeLook {
        let map: MTLTexture
        let uniforms: UInt64
        init(map: MTLTexture, uniforms: UInt64) {
            self.map = map
            self.uniforms = uniforms
        }
    }

    /// Must match `GrungeUniforms` in the shaders: x…z the tint, w how much; then the tiling a metre, the falloff, the
    /// sheet's own tiling, and 1 for on.
    struct GrungeUniforms {
        var colour: SIMD4<Float>
        var params: SIMD4<Float>
    }

    /// Must match `LiquidUniforms` in the shaders.
    struct LiquidUniforms {
        var shallow, deep, veryDeep, scrollTint, scroll, shoreTint, shore, foamTint, foam, ripples, surface, switches: SIMD4<Float>

        init(_ l: WorldFile.Liquid.Look, near: Float, time: Float) {
            func on(_ b: Bool) -> Float { b ? 1 : 0 }
            shallow = SIMD4(l.shallow, l.deepHeight)
            deep = SIMD4(l.deep, l.veryDeepHeight)
            veryDeep = SIMD4(l.veryDeep, l.shallowsOpacity)
            scrollTint = SIMD4(l.scrollTint, l.scrollOpacity)
            scroll = SIMD4(l.scrollTiling.x, l.scrollTiling.y, l.scrollDirection.x, l.scrollDirection.y)
            shoreTint = SIMD4(l.shoreTint, l.shoreEdgeOpacity)
            shore = SIMD4(l.shoreEdgeThickness, l.shoreWaveThickness, l.shoreWaveReturn, l.shoreEdgeNoiseScale)
            foamTint = SIMD4(l.foamTint, l.foamOpacity)
            foam = SIMD4(l.foamTiling, l.shoreFoamNoiseScale, l.baseOpacity, near)
            ripples = SIMD4(l.normalTiling, l.normalIntensity, l.normalNoiseIntensity, l.normalNoiseTiling)
            surface = SIMD4(l.metallic, l.smoothness, l.normalPanSpeed, time)
            switches = SIMD4(on(l.shoreBand), on(l.shoreFoam), on(l.scrolling), on(l.ripples))
        }
    }

    /// Triangles to draw: the full mesh's own, or a lower-detail level's — which has its own vertices too.
    struct IndexRange {
        let address: UInt64
        let length: Int
        let count: Int
        let type: MTLIndexType
        /// A level's own vertices, bound in place of the mesh's; `nil` for the full mesh.
        let vertices: UInt64?

        init(_ submesh: MTKSubmesh) {
            address = submesh.indexBuffer.buffer.gpuAddress + UInt64(submesh.indexBuffer.offset)
            length = submesh.indexBuffer.length
            count = submesh.indexCount
            type = submesh.indexType
            vertices = nil
        }

        /// Indices of its own, into the mesh's own vertices — part of a submesh (``TurningPart``).
        init(buffer: MTLBuffer, count: Int) {
            address = buffer.gpuAddress
            length = count * 4
            self.count = count
            type = .uint32
            vertices = nil
        }

        init(buffer: MTLBuffer, offset: Int, count: Int, vertices: UInt64) {
            address = buffer.gpuAddress + UInt64(offset)
            length = count * 4
            self.count = count
            type = .uint32
            self.vertices = vertices
        }

        /// Binds the vertices these indices point into.
        func bindVertices(of mesh: MTKMesh, to table: MTL4ArgumentTable) {
            if let vertices {
                table.setAddress(vertices, index: 0)
            } else {
                for (index, buffer) in mesh.vertexBuffers.enumerated() {
                    table.setAddress(buffer.buffer.gpuAddress + UInt64(buffer.offset), index: index)
                }
            }
        }
    }

    private var props: [URL: PropMeshes] = [:] {
        // **A prop arriving adds its own copies, and only those** (2026-10-25): rebuilding every copy each time one of a
        // zone's 54 scattered props finished loading was 4.4 s of the main thread, during which nothing drew — a window
        // resized while a scene opened stayed black until it was over. A prop dropped or reloaded rebuilds them all.
        didSet {
            let added = Set(props.keys).subtracting(oldValue.keys)
            // Purely added: nothing that was there is gone, so nothing already gathered can be stale. A reload keeps
            // its key with new meshes, and rebuilds like a removal.
            //
            // **And added once a frame, not once a prop** (2026-10-28): each arrival scanned every placement and laid
            // every cell out again — on an imported map, 921 props × 11,566 placements, and the window ran at 1–3 fps
            // for the whole load. Arrivals wait in ``arrivedForScattered`` / ``arrivedForPlaced`` for the next frame.
            let purelyAdded = !added.isEmpty && props.count == oldValue.count + added.count
            if purelyAdded, scatteredCopies != nil { arrivedForScattered.formUnion(added) } else { scatteredCopies = nil }
            if purelyAdded, placedCopies != nil { arrivedForPlaced.formUnion(added) } else { placedCopies = nil }
        }
    }
    private var failedProps: Set<URL> = []
    /// Props loaded since the last frame whose copies are not gathered yet — one set per gathered set, emptied when that
    /// set is gathered whole, which takes in every loaded prop.
    private var arrivedForScattered: Set<URL> = []
    private var arrivedForPlaced: Set<URL> = []

    /// Gathers the copies of props that arrived since the last frame, all at once.
    private func addArrivedCopies() {
        if !arrivedForScattered.isEmpty || !arrivedForPlaced.isEmpty { litterStale = true }
        if !arrivedForScattered.isEmpty {
            let urls = arrivedForScattered
            arrivedForScattered = []
            if scatteredCopies != nil { addScatteredCopies(of: urls) }
        }
        if !arrivedForPlaced.isEmpty {
            let urls = arrivedForPlaced
            arrivedForPlaced = []
            if placedCopies != nil { addPlacedCopies(of: urls) }
        }
    }

    /// **A prop's far picture** (2026-11-01): its coarsest level drawn once from each of `ImpostorViews`' 64
    /// directions into a pair of texture arrays — colour, and the normal in the prop's own space — and a far copy drawn
    /// as one square facing the eye, painted from the four views nearest its direction and lit as the mesh would be
    /// (`impostorVertex`, `impostorFragment`). a 400 m wooded zone seen whole drew 1.8 million triangles of trees and bushes,
    /// every copy at the pack's coarsest level and a few dozen pixels across.
    ///
    /// Baked in a pre-pass of the first frame after the prop loads (``encodeImpostorBakes(into:)``); until then its copies
    /// draw their coarsest mesh.
    final class Impostor {
        /// The prop's name, for labels and checks.
        let name: String
        /// Colour, premultiplied by coverage — sRGB, so dark leaves keep their shades — and the normal as `n × 0.5 + 0.5`,
        /// premultiplied the same way: one slice a view, mipmapped.
        let albedo: MTLTexture
        let normals: MTLTexture
        /// How far toward the eye the surface is from the prop's centre, as `0.5 + 0.5 × d` in units of the radius,
        /// premultiplied the same way: where its shadows, sky and fog are looked up, not the square through the middle.
        let depth: MTLTexture
        /// Pixels a side of each view.
        let size: Int
        /// The sphere the pictures frame, in the prop's own space.
        let centre: SIMD3<Float>
        let radius: Float
        /// The leaves' roughness, for the sun's glint.
        let roughness: Float
        /// The meshes drawn into it, at what level.
        let source: (meshes: [ShownMesh], tier: Int)
        /// How the prop moves in the wind (`swayVector`'s x), so the bake shades its foliage as the near copies are.
        var sway: Float = 0
        var isBaked = false

        /// **Drawn as the picture at or under this many pixels across** (the copy's bounding sphere on screen): three
        /// quarters of a view's size, so the picture is never magnified.
        var drawnUnder: Float { Float(size) * 0.75 }

        init(name: String, albedo: MTLTexture, normals: MTLTexture, depth: MTLTexture, size: Int, centre: SIMD3<Float>, radius: Float, roughness: Float,
             source: (meshes: [ShownMesh], tier: Int)) {
            self.name = name
            self.albedo = albedo
            self.normals = normals
            self.depth = depth
            self.size = size
            self.centre = centre
            self.radius = radius
            self.roughness = roughness
            self.source = source
        }
    }

    // MARK: Layout shared with WorldShaders.metal

    /// The vertex layout: position, normal, uv. The attribute indices are a contract with `VertexIn`.
    nonisolated static let semantics: [Int: String] = [
        0: MDLVertexAttributePosition,
        1: MDLVertexAttributeNormal,
        2: MDLVertexAttributeTextureCoordinate,
    ]

    nonisolated static func vertexDescriptor() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3; d.attributes[0].offset = 0; d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float3; d.attributes[1].offset = 12; d.attributes[1].bufferIndex = 0
        d.attributes[2].format = .float2; d.attributes[2].offset = 24; d.attributes[2].bufferIndex = 0
        d.layouts[0].stride = 32
        d.layouts[0].stepFunction = .perVertex
        return d
    }

    /// The ground's layout: the props' three attributes, then its painted colour. Its own, because a
    /// colour on every prop vertex would be bytes spent saying "white" a million times.
    nonisolated static func groundVertexDescriptor() -> MTLVertexDescriptor {
        let d = vertexDescriptor()
        d.attributes[3].format = .float4; d.attributes[3].offset = 32; d.attributes[3].bufferIndex = 0
        d.layouts[0].stride = groundStride
        return d
    }

    /// Bytes per ground vertex: position, normal, uv, colour.
    nonisolated static let groundStride = 48

    /// `FrameUniforms` in the shader.
    struct FrameUniforms {
        var viewProjection: simd_float4x4
        var inverseViewProjection: simd_float4x4
        var cameraPosition: SIMD4<Float>
        var sunDirection: SIMD4<Float>
        var sunColour: SIMD4<Float>
        var skyColour: SIMD4<Float>
        var horizonColour: SIMD4<Float>
        var groundColour: SIMD4<Float>
        var grid: SIMD4<Float>
        var cascadeViewProjection: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4)
        var cascadeSplits: SIMD4<Float>
        var cascadeBlendStart: SIMD4<Float>
        var cascadeDepthBias: SIMD4<Float>
        var shadowParams: SIMD4<Float>
        var fogParams: SIMD4<Float>
        /// The weather on the world's surfaces (Ductane's `WeatherSurface`, `DUWeatherSurface` in the shaders).
        var weather = WeatherSurface()
    }

    /// `ObjectUniforms` in the shader.
    struct ObjectUniforms {
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var baseColour: SIMD4<Float>
        var emissive: SIMD4<Float>
        var params: SIMD4<Float>
        /// What the season does to it: x 1 turns, 2 grass, 0 neither; y the year's phase; z 1 bare in winter; w how far
        /// leaves turn (``foliageVector(for:)``).
        var foliage: SIMD4<Float> = .zero
        /// How it moves in the wind: x 1 a tree, 2 a plant, 3 cloth; y its height, z half its width (``swayVector(for:bounds:)``).
        var sway: SIMD4<Float> = .zero
        /// The frame's wind (Ductane's `Weather.foliageWind`).
        var wind: SIMD4<Float> = .zero
    }

    /// `GroundLayers` in the shader: each layer's colour and slice, then how each repeats — sixteen `float4`s, the 256
    /// bytes of one uniform slot.
    struct GroundLayerUniforms {
        var values = [SIMD4<Float>](repeating: .zero, count: 16)
    }

    /// Point lights a frame lights with, nearest the view first — `lightCount` and the two arrays after
    /// `FrameUniforms` in the shader, written straight after it (every field of it is 16-byte aligned).
    static let lightLimit = 16
    private static let lightBytes = MemoryLayout<SIMD4<Float>>.stride * (2 + lightLimit * 2)
    private static let frameStride = (MemoryLayout<FrameUniforms>.stride + lightBytes + 255) & ~255
    private static let objectStride = (MemoryLayout<ObjectUniforms>.stride + 255) & ~255
    /// Sets of uniforms a frame can hold: a prop's submeshes share one however many copies they draw.
    private static let maxObjects = 4096

    /// **What a frame could not draw for want of room, said.** A full buffer used to drop the rest of the frame without a
    /// word: an imported map of 11,566 placements drew about a third of them, and the frame time and pictures measured on
    /// it were of that third. Counted per frame, logged once.
    public private(set) var refusedObjects = 0
    /// Uniform sets the last frame wrote, of ``objectLimit``.
    public var objectsWritten: Int { nextSlot }
    public static var objectLimit: Int { maxObjects }
    private var reportedFull = false

    private func refuseObject() {
        refusedObjects += 1
        guard !reportedFull else { return }
        reportedFull = true
        NSLog("WorldRenderer: a frame needed more than \(Self.maxObjects) draws' uniforms; the rest were not drawn.")
    }

    // MARK: GPU state

    /// **The surfaces' pipelines, twice** (2026-11-16): with the weather on surfaces compiled in, and without
    /// (`weatherOnSurfaces`, function constant 0 in `WorldShaders.metal`). A frame whose weather lays nothing
    /// (``WeatherSurface/laysOnSurfaces``) draws with the plain set: compiled in and doing nothing, the weather took
    /// a wooded 400 m scene's meadow from 24 to 38 ms of GPU on a clear day.
    ///
    /// **And the seasons on foliage likewise** (function constant 1): leaves turning and falling compiled in only while a
    /// calendar changes foliage (``frameFall``) — 5 ms of a wooded scene's meadow with no calendar. Four sets, by
    /// ``SurfacePipelines/index(weather:seasons:)``.
    private var surfaceSets: [SurfacePipelines]
    /// Whether the frame being drawn lays weather on surfaces, and changes foliage by the season — set as its uniforms are
    /// written.
    ///
    /// **The ground and what stands on it are asked apart** (``WeatherSurface/laysOnSurfaces``, ``WeatherSurface/laysOnProps``):
    /// footprints, puddles and fallen leaves lie on the ground alone, so a walk leaving prints on a clear day draws only the
    /// ground with the weather compiled in.
    private var drawsWeatherOnGround = true
    private var drawsWeatherOnProps = true
    private var drawsSeasonsOnFoliage = true
    private var surfaces: SurfacePipelines {
        surfaceSets[SurfacePipelines.index(weather: drawsWeatherOnProps, seasons: drawsSeasonsOnFoliage)]
    }
    private var propPipeline: MTLRenderPipelineState { surfaces.prop }
    private var groundPipeline: MTLRenderPipelineState {
        surfaceSets[SurfacePipelines.index(weather: drawsWeatherOnGround, seasons: drawsSeasonsOnFoliage)].ground
    }
    private var texturedGroundPipeline: MTLRenderPipelineState {
        surfaceSets[SurfacePipelines.index(weather: drawsWeatherOnGround, seasons: drawsSeasonsOnFoliage)].texturedGround
    }
    private var instancedPipeline: MTLRenderPipelineState { surfaces.instanced }
    /// Snow built up on props (Ductane's `SnowCap`), drawn with their copies.
    private var snowCapPipeline: MTLRenderPipelineState
    /// See-through props — glass — blended over the finished solid scene (``preparedSeeThrough``).
    private var seeThroughPipeline: MTLRenderPipelineState { surfaces.seeThrough }
    /// Liquids — the goop — blended over the solid scene, reading its depth (``WorldFile/Liquid``).
    private var liquidPipeline: MTLRenderPipelineState
    /// Particles drawn as pack meshes — frogs, bubbles, flies — lit as props are (``encodeEffectMeshes(into:)``).
    private var effectMeshPipeline: MTLRenderPipelineState { surfaces.effectMesh }
    /// Far pictures, drawn as squares facing the eye (``Impostor``).
    private var impostorPipeline: MTLRenderPipelineState { surfaces.impostor }
    /// Far pictures baked, into their own targets.
    private let impostorBakePipeline: MTLRenderPipelineState
    private let impostorBakeDepthState: MTLDepthStencilState
    private let shadowPropPipeline: MTLRenderPipelineState
    private let shadowInstancedPipeline: MTLRenderPipelineState
    /// The shadow pass for cut-out surfaces, which reads each one's alpha; solid ones keep the vertex-only pipelines.
    private let shadowMaskPropPipeline: MTLRenderPipelineState
    private let shadowMaskInstancedPipeline: MTLRenderPipelineState
    /// The fragment stage's bindings in the shadow pass, which binds only the vertex stage's itself: 1 the object, 0 its map.
    private let shadowFragmentTable: MTL4ArgumentTable
    private let shadowGroundPipeline: MTLRenderPipelineState
    /// The sky: Ductane's `SkyPass`, drawing the scene's `DaySky` — the same sky a game built from the scene draws.
    private var skyPass: SkyPass
    private var gridPipeline: MTLRenderPipelineState
    /// The fog volume laid over the sky where nothing solid was drawn (Ductane's `FogSkyPass`).
    private var fogSkyPass: FogSkyPass
    /// Stands in for the fog volume when there is none.
    private let blankVolume: MTLTexture
    private var waterPipeline: MTLRenderPipelineState
    private var streamPipeline: MTLRenderPipelineState
    /// Tested against the scene, never written: water hides what is behind it only by covering it.
    private let waterDepthState: MTLDepthStencilState
    /// **Liquids write depth** (``encodeLiquids``): the nearest piece of goop over a pixel is shaded, those behind it are
    /// not.
    private let liquidDepthState: MTLDepthStencilState
    /// A prop's shape, for an editor to outline a selection by (``encodeSilhouette(of:wearing:transform:scale:into:)``).
    private let silhouettePipeline: MTLRenderPipelineState
    /// The shape drawn this frame, at the view's size — made again when the view changes size.
    private var silhouette: MTLTexture?
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let frameBuffer: MTLBuffer
    private let objectBuffer: MTLBuffer
    private let textures: TextureStore
    private var aspectRatio: Float = 1.6
    /// In pixels: how much a level of detail's error shows depends on it.
    private var viewportHeight = 1000
    private var viewportWidth = 1600
    /// **An editor's grid**: faint metre and ten-metre lines on the ground, and a grid where there is no ground — so
    /// distance and slope can be judged on ground painted one colour. Off for a game.
    public var showsGrid = false
    /// The slot the next object's uniforms go in, this frame.
    private var nextSlot = 0
    private var frameSlot = 0

    /// The world's shaders (`WorldShaders.metal`), compiled once.
    private let library: MTLLibrary

    /// - Parameters:
    ///   - graphics: the settings it starts at — ``graphicsSettings``.
    ///   - textureCache: where textures are kept compressed for the GPU (``CompressedTextures``); nil to load them as
    ///     they are.
    ///   - library: the world's shaders, compiled by the app — `WorldShaders.metal` built into its own library; by
    ///     default compiled from the engine's source at run time.
    public init(engine: FrameRenderer, graphics: GraphicsSettings = GraphicsSettings(),
                textureCache: URL? = CompressedTextures.appCache(), library: MTLLibrary? = nil) throws {
        self.engine = engine
        let device = engine.device
        let library = try library ?? ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "WorldShaders")
        self.library = library
        graphicsSettings = graphics
        do {
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
                let f = MTL4LibraryFunctionDescriptor()
                f.library = library
                f.name = name
                return f
            }
            func pipeline(_ label: String, _ vertex: String, _ fragment: String,
                          _ vertexDescriptor: MTLVertexDescriptor?,
                          format: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                          surfaceVertex: Bool = false) throws -> MTLRenderPipelineState {
                let d = MTL4RenderPipelineDescriptor()
                d.label = label
                // A surface's vertex function takes the function constants (``SurfacePipelines``): compiled in, as drawn.
                d.vertexFunctionDescriptor = surfaceVertex
                    ? Self.surfaceFunction(vertex, library: library, weather: true, seasons: true) : function(vertex)
                d.fragmentFunctionDescriptor = function(fragment)
                d.vertexDescriptor = vertexDescriptor
                d.colorAttachments[0].pixelFormat = format
                return try compiler.makeRenderPipelineState(descriptor: d, compilerTaskOptions: nil)
            }
            // The scene goes into the engine's HDR target, which it tone maps afterwards — at the engine's sample count,
            // rebuilt when the viewport's anti-aliasing changes (``applyGraphics``).
            let scenePipelines = try Self.buildScenePipelines(device: device, library: library, sampleCount: 1)
            surfaceSets = scenePipelines.surfaceSets
            snowCapPipeline = scenePipelines.snowCap
            liquidPipeline = scenePipelines.liquid
            gridPipeline = scenePipelines.grid
            waterPipeline = scenePipelines.water
            streamPipeline = scenePipelines.stream
            fogSkyPass = scenePipelines.fogSky
            skyPass = scenePipelines.sky
            effects = try WorldEffectsPass(device: device, sampleCount: 1)
            boundaryRenderer = try BoundaryRenderer(device: device, sampleCount: 1)
            waymarkRenderer = try WaymarkRenderer(device: device, sampleCount: 1)
            scanRenderer = try WaymarkScanRenderer(device: device, sampleCount: 1)
            weatherRenderer = try WeatherRenderer(device: device, sampleCount: 1)
            // ±64 m at 12.5 cm a texel: rain under eaves, and lying snow kept off what is under something far enough out.
            weatherCover = try WeatherCover(device: device, resolution: 1024, halfExtent: 64)
            footprintGrid = try FootprintGrid(device: device)
            // The sun's shadow pass: depth only, set up the way Ductane's `ShadowMap` requires.
            func shadow(_ label: String, _ vertex: String, _ layout: MTLVertexDescriptor,
                        fragment: String? = nil) throws -> MTLRenderPipelineState {
                try compiler.makeRenderPipelineState(
                    descriptor: ShadowMap.pipelineDescriptor(vertexFunction: function(vertex),
                                                             fragmentFunction: fragment.map(function),
                                                             vertexDescriptor: layout, label: label),
                    compilerTaskOptions: nil)
            }
            shadowPropPipeline = try shadow("Prop Shadow", "shadowPropVertex", Self.vertexDescriptor())
            shadowInstancedPipeline = try shadow("Scattered Shadow", "shadowInstancedVertex", Self.vertexDescriptor())
            shadowMaskPropPipeline = try shadow("Cut-out Prop Shadow", "shadowMaskPropVertex", Self.vertexDescriptor(),
                                                fragment: "shadowMaskFragment")
            shadowMaskInstancedPipeline = try shadow("Cut-out Scattered Shadow", "shadowMaskInstancedVertex",
                                                     Self.vertexDescriptor(), fragment: "shadowMaskFragment")
            shadowGroundPipeline = try shadow("Ground Shadow", "shadowGroundVertex", Self.groundVertexDescriptor())
            engine.residencySet.addAllocations(skyPass.allocations)
            engine.residencySet.addAllocations(effects.allocations)
            engine.residencySet.addAllocations(boundaryRenderer.allocations)
            engine.residencySet.addAllocations(waymarkRenderer.allocations)
            engine.residencySet.addAllocations(scanRenderer.allocations)
            engine.residencySet.addAllocations(weatherRenderer.allocations)
            engine.residencySet.addAllocations(weatherCover.allocations)
            engine.residencySet.addAllocations(footprintGrid.allocations)
            silhouettePipeline = try pipeline("Silhouette", "propVertex", "silhouetteFragment",
                                                 Self.vertexDescriptor(), format: .r8Unorm, surfaceVertex: true)
            // **A far picture's bake**: colour and normal into a slice a view, the view chosen per instance (layered).
            let bake = MTL4RenderPipelineDescriptor()
            bake.label = "Far Picture Bake"
            bake.vertexFunctionDescriptor = function("impostorBakeVertex")
            bake.fragmentFunctionDescriptor = function("impostorBakeFragment")
            bake.vertexDescriptor = Self.vertexDescriptor()
            bake.colorAttachments[0].pixelFormat = .rgba8Unorm_srgb
            bake.colorAttachments[1].pixelFormat = .rgba8Unorm
            bake.colorAttachments[2].pixelFormat = .r8Unorm
            bake.inputPrimitiveTopology = .triangle
            impostorBakePipeline = try compiler.makeRenderPipelineState(descriptor: bake, compilerTaskOptions: nil)
        }

        guard let depthState = engine.makeDepthStencilState() else { throw WorldRendererError.couldNotCreate("depth state") }
        self.depthState = depthState
        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = .rgba16Float
        volumeDescriptor.width = 1
        volumeDescriptor.height = 1
        volumeDescriptor.depth = 1
        volumeDescriptor.usage = .shaderRead
        volumeDescriptor.storageMode = .private
        guard let blankVolume = device.makeTexture(descriptor: volumeDescriptor) else {
            throw WorldRendererError.couldNotCreate("blank fog volume")
        }
        blankVolume.label = "No Fog Volume"
        self.blankVolume = blankVolume
        let waterDepth = MTLDepthStencilDescriptor()
        waterDepth.depthCompareFunction = .greater   // reversed-Z: nearer is greater
        waterDepth.isDepthWriteEnabled = false
        guard let waterDepthState = device.makeDepthStencilState(descriptor: waterDepth) else { throw WorldRendererError.couldNotCreate("depth state") }
        self.waterDepthState = waterDepthState
        let liquidDepth = MTLDepthStencilDescriptor()
        liquidDepth.depthCompareFunction = .greater
        liquidDepth.isDepthWriteEnabled = true
        guard let liquidDepthState = device.makeDepthStencilState(descriptor: liquidDepth) else { throw WorldRendererError.couldNotCreate("depth state") }
        self.liquidDepthState = liquidDepthState
        let bakeDepth = MTLDepthStencilDescriptor()
        bakeDepth.depthCompareFunction = .less     // the bake's own depth: nearer is smaller
        bakeDepth.isDepthWriteEnabled = true
        guard let bakeDepthState = device.makeDepthStencilState(descriptor: bakeDepth) else { throw WorldRendererError.couldNotCreate("depth state") }
        impostorBakeDepthState = bakeDepthState

        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 12   // 0: vertices · 1: object · 2: frame · 3: scattered copies' transforms · 4: the ground's vertices · 5: a liquid's look · 6, 7: footprints and their cells · 8: where puddles gather · 9: where fallen leaves lie · 10: the ground's layers · 11: their painted weights
        table.maxTextureBindCount = 12   // 0: base colour · 1: the sun's shadow cascades · 2: emission · 3–5: a far picture's colour, normals and depth (a liquid's noise and normals at 2, 3) · 6: the solid pass's depth · 7: the weather's cover, for lying snow · 8: where clouds gather, for their shadows · 9: the fog volume · 10, 11: the ground layers' colour and surface
        let shadowTable = MTL4ArgumentTableDescriptor()
        shadowTable.maxBufferBindCount = 2
        shadowTable.maxTextureBindCount = 1
        guard let argumentTable = try? device.makeArgumentTable(descriptor: table),
              let shadowFragmentTable = try? device.makeArgumentTable(descriptor: shadowTable),
              let frameBuffer = device.makeBuffer(length: Self.frameStride * FrameRenderer.maxFramesInFlight,
                                                  options: .storageModeShared),
              let objectBuffer = device.makeBuffer(
                length: Self.objectStride * Self.maxObjects * FrameRenderer.maxFramesInFlight,
                options: .storageModeShared),
              let textures = try? TextureStore(device: device) else { throw WorldRendererError.couldNotCreate("buffers") }
        self.argumentTable = argumentTable
        self.shadowFragmentTable = shadowFragmentTable
        self.frameBuffer = frameBuffer
        self.objectBuffer = objectBuffer
        self.textures = textures
        // Textures load at the viewport's quality from the first prop, so the first frame's settings change nothing.
        textures.quality = graphics.textureQuality
        // **Compressed for the GPU, and kept** (2026-10-28): every image a prop names is loaded through its ASTC 4×4 copy
        // in the app's caches — a quarter of the memory at the same resolution, and later opens skip decoding PNGs.
        // Made the first time a texture is loaded, in the background where props are read.
        textures.compressionCache = textureCache
        frameBuffer.label = "Frame Uniforms"
        objectBuffer.label = "Object Uniforms"

        engine.residencySet.addAllocations([frameBuffer, objectBuffer] + textures.allocations)
        engine.commitResidency()
        engine.toneMapping = ToneMapping(curve: .aces, exposureStops: 0)
        engine.clearColor = MTLClearColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 1)
    }

    // MARK: Props

    /// Loads every prop the scene uses that is not loaded yet, **now**, on this thread. For a check drawn off screen,
    /// which has nothing to draw until they are in. Returns the ones that failed.
    @discardableResult
    public func loadPropsNow() -> [(URL, Error)] {
        // Read side by side, as ``loadPropsInBackground(_:)`` reads them; finished here, in order.
        let urls = Array(wantedProps())
        let device = Loaded.Device(device)
        let compression = textureCompression
        let results = Results(count: urls.count)
        let files = propFiles
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            results.set(i, Result { try WorldRenderer.load(urls[i], device: device.device, files: files, compressing: compression) })
        }
        var failures: [(URL, Error)] = []
        for (url, result) in zip(urls, results.all) {
            switch result {
            case .success(let loaded): props[url] = finish(loaded, from: url)
            case .failure(let error):
                failedProps.insert(url)
                failures.append((url, error))
            }
        }
        return failures
    }

    /// Loads written from several threads at once, each to its own slot.
    private nonisolated final class Results: @unchecked Sendable {
        private var slots: [Result<Loaded, Error>?]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ result: Result<Loaded, Error>) { lock.withLock { slots[i] = result } }
        var all: [Result<Loaded, Error>] { lock.withLock { slots.map { $0! } } }
    }

    /// Loads every prop the scene uses that is not loaded yet **off the main thread**, so opening a scene
    /// of hundreds never stalls the window. Each prop appears as it arrives; `finished` hears the failures.
    ///
    /// Reading and parsing the file — the slow part — happens in the background. Textures and residency
    /// are finished on the main actor, where the texture store and the engine's residency set live.
    ///
    /// **A failure from before the failures were forgotten does not count** (``forgetFailures()``): a person granted a
    /// folder while its props were still being read under the old, refused access, and each came back "contains no
    /// meshes" and stayed failed until a relaunch. Such a prop is left unloaded and `finished` is told to look again.
    public func loadPropsInBackground(_ finished: @escaping (_ failures: [(URL, Error)], _ retry: Bool) -> Void) {
        let wanted = wantedProps()
        guard !wanted.isEmpty else { return }
        let generation = failureGeneration
        let run = loadRun
        loading.formUnion(wanted)
        loadingTotal += wanted.count
        onLoadingProgress?(loadingTotal - loading.count, loadingTotal)
        let device = Loaded.Device(device)
        let compression = textureCompression
        let files = propFiles
        Task {
            var failures: [(URL, Error)] = []
            var retry = false
            // **Several read at once** (2026-10-28): one at a time, an imported map of 921 props took most of a minute
            // to appear. Each is still finished here, on the main actor, as it arrives.
            await withTaskGroup(of: (URL, Result<Loaded, Error>).self) { group in
                var pending = wanted.makeIterator()
                func readNext() {
                    guard let url = pending.next() else { return }
                    group.addTask {
                        let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
                            // Converting a prop to its USD copy, and simplifying it, are the slow parts: they happen here.
                            Result { try WorldRenderer.load(url, device: device.device, files: files, compressing: compression) }
                        }.value
                        return (url, result)
                    }
                }
                for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount - 2) { readNext() }
                for await (url, result) in group {
                    // **Stopped when the view goes** (``stopLoading()``): what is in flight finishes and is let go.
                    if run != loadRun { continue }
                    readNext()
                    loading.remove(url)
                    if loading.isEmpty { loadingTotal = 0 }
                    onLoadingProgress?(loadingTotal - loading.count, loadingTotal)
                    switch result {
                    case .success(let loaded): props[url] = finish(loaded, from: url)
                    case .failure where generation != failureGeneration:
                        retry = true
                    case .failure(let error):
                        failedProps.insert(url)
                        failures.append((url, error))
                    }
                }
            }
            if run == loadRun { finished(failures, retry) }
        }
    }

    /// **Where a prop's meshes are read from** — called off the main thread, as props load.
    public struct PropFiles: Sendable {
        /// **The file a prop is drawn from**: itself, or a copy an app made of it in a format the engine reads.
        public var drawn: @Sendable (URL) throws -> URL
        /// **Its own coarser levels**, finest first (``PropLevels/levels(of:)``); a prop with none is simplified as it
        /// loads (``MeshDetail``).
        public var levels: @Sendable (URL) -> [URL]
        public init(drawn: @escaping @Sendable (URL) throws -> URL = { $0 },
                    levels: @escaping @Sendable (URL) -> [URL] = { PropLevels.levels(of: $0) }) {
            self.drawn = drawn
            self.levels = levels
        }
    }
    /// Set before the props load.
    public var propFiles = PropFiles()

    /// **Reads a prop and its levels** — off the main thread when loading in the background: the file it is drawn from
    /// (``PropFiles/drawn``), and its own levels beside that; only a prop without them is simplified here.
    nonisolated private static func load(_ url: URL, device: MTLDevice, files: PropFiles,
                                         compressing: TextureCompression? = nil) throws -> Loaded {
        let usd = try files.drawn(url)
        func meshes(_ file: URL) throws -> [LoadedMesh] {
            try MeshLoader.load(url: file, device: device, vertexDescriptor: vertexDescriptor(), semantics: semantics,
                                reportingTo: { NSLog("WorldRenderer: \($0)") })
        }
        let base = try meshes(usd)
        // **Its textures compressed here, off the main thread**, so finishing the prop on the main actor only reads the
        // cached files (``textureCompression``). Several props sharing a sheet wait for one encoding.
        if let compressing {
            for mesh in base {
                for material in mesh.materials {
                    for (slot, source) in material.textures {
                        guard case .url(let file) = source, file.isFileURL, file.fragment(percentEncoded: false) == nil,
                              CompressedTextures.compressible.contains(file.pathExtension.lowercased()) else { continue }
                        _ = try? CompressedTextures.prepare(file, isColor: slot.isColor, quality: compressing.quality,
                                                            in: compressing.cache)
                    }
                }
            }
        }
        // A level that cannot be read is left out, and the levels after it: the prop still draws.
        var levels: [[LoadedMesh]] = []
        for file in files.levels(usd) {
            guard let level = try? meshes(file), !level.isEmpty else { break }
            levels.append(level)
        }
        return Loaded(meshes: base, detail: levels.isEmpty ? base.map(detailLevels) : base.map { _ in [] }, levels: levels)
    }

    /// What a background load hands back. `Sendable` because Ductane's `LoadedMesh` is: the meshes
    /// are made there and never touched there again, so handing them to the main actor shares nothing.
    private nonisolated struct Loaded: Sendable {
        let meshes: [LoadedMesh]
        /// Per mesh, its levels.
        let detail: [[MeshDetail.Tier]]
        /// The prop's own coarser levels, if it has any (``PropLevels``); then `detail` is empty.
        let levels: [[LoadedMesh]]
        struct Device: @unchecked Sendable {
            let device: MTLDevice
            init(_ device: MTLDevice) { self.device = device }
        }
    }

    private var loading: Set<URL> = []
    /// Props asked for since loading last finished — the total a progress bar counts to.
    private var loadingTotal = 0
    /// Props are being read in the background.
    public var isLoadingProps: Bool { !loading.isEmpty }
    /// Moved on by ``stopLoading()``: a load from before it finishes nothing.
    private var loadRun = 0

    /// **Reads no more props** — the view is gone, closed or paused (2026-11-02). The loading task holds the renderer, so
    /// without this a scene closed or paused mid-load kept reading every prop it had asked for into a renderer nobody
    /// draws, and gave nothing back until it had.
    public func stopLoading() {
        loadRun += 1
        loading = []
        loadingTotal = 0
    }
    /// Told how many of how many props have loaded, after each one; `(0, 0)` when none are loading.
    public var onLoadingProgress: ((Int, Int) -> Void)?

    private func wantedProps() -> Set<URL> {
        Set(scene.placements.map(\.prop) + scene.scatters.flatMap(\.prototypes) + scene.wornFiles
            + scene.effectMeshes.values).filter {
            props[$0] == nil && !failedProps.contains($0) && !loading.contains($0)
        }
    }

    /// The main-actor half of loading: textures, bounds, the lower-detail levels' buffers, residency.
    private func finish(_ loaded: Loaded, from url: URL) -> PropMeshes {
        var box: BoundingBox?
        var meshes: [ShownMesh] = []
        var errors: [Float] = []
        // **What the prop file says is a liquid** (``WorldFile/Liquid``), by material: drawn as one, see-through.
        let liquids = self.liquids(url)
        let grime = self.grime(url)
        func shown(_ mesh: LoadedMesh, detail levels: [MeshDetail.Tier]) -> ShownMesh {
            let sets = (0..<mesh.mesh.submeshes.count).map { index in
                textures.textures(for: mesh.material(forSubmesh: index), reportingTo: { NSLog("WorldRenderer: \($0)") })
            }
            let maps = sets.map { $0[.baseColor] ?? textures.white }
            let glows = sets.map { $0[.emissive] ?? textures.white }
            let cutoffs = (0..<mesh.mesh.submeshes.count).map { mesh.material(forSubmesh: $0).alphaCutoff ?? 0 }
            let liquid = (0..<mesh.mesh.submeshes.count).map { index in
                liquids[Self.materialName(mesh.material(forSubmesh: index))].flatMap { liquidLook($0.look, textures: $0.textures) }
            }
            let seeThrough = (0..<mesh.mesh.submeshes.count).map {
                liquid[$0] != nil || Self.isSeeThrough(mesh.material(forSubmesh: $0))
            }
            let dirt = (0..<mesh.mesh.submeshes.count).map { index in
                grime[Self.materialName(mesh.material(forSubmesh: index))].flatMap { grungeLook($0.look, map: $0.map) }
            }
            engine.residencySet.addAllocations(mesh.mesh.vertexBuffers.map(\.buffer))
            engine.residencySet.addAllocations(mesh.mesh.submeshes.map(\.indexBuffer.buffer))
            let (ranges, buffer) = detailRanges(levels)
            return ShownMesh(loaded: mesh, baseMaps: maps, glowMaps: glows, cutoffs: cutoffs, seeThrough: seeThrough,
                             materials: (0..<mesh.mesh.submeshes.count).map { mesh.material(forSubmesh: $0) },
                             liquids: liquid.contains { $0 != nil } ? liquid : [],
                             grunge: dirt.contains { $0 != nil } ? dirt : [], detail: ranges, detailBuffer: buffer)
        }
        func triangles(_ meshes: [LoadedMesh]) -> Int {
            meshes.reduce(0) { $0 + $1.mesh.submeshes.reduce(0) { $0 + $1.indexCount / 3 } }
        }
        for (mesh, levels) in zip(loaded.meshes, loaded.detail) {
            meshes.append(shown(mesh, detail: levels))
            // **In metres, as everything they are compared with is** (2026-10-25). A tier's error is in the mesh's own
            // units, and a pack converted from FBX is in centimetres under a 0.01 node scale: left unscaled, every error
            // read a hundred times too big, and no prop made from an FBX ever drew a coarser level.
            let unitScale = [mesh.nodeTransform.columns.0, mesh.nodeTransform.columns.1, mesh.nodeTransform.columns.2]
                .map { simd_length(SIMD3($0.x, $0.y, $0.z)) }.max() ?? 1
            let meshErrors = levels.map { $0.error * unitScale }
            errors = (0..<max(errors.count, meshErrors.count)).map { level in
                max(errors.isEmpty ? 0 : errors[min(level, errors.count - 1)],
                    meshErrors.isEmpty ? 0 : meshErrors[min(level, meshErrors.count - 1)])
            }
            let local = mesh.bounds.transformed(by: mesh.nodeTransform)
            box = box.map { BoundingBox(minimum: simd_min($0.minimum, local.minimum),
                                        maximum: simd_max($0.maximum, local.maximum)) } ?? local
        }
        var prop = PropMeshes(meshes: meshes, bounds: box ?? BoundingBox(minimum: .zero, maximum: .zero),
                              detailErrors: loaded.levels.isEmpty ? errors : [])
        if !loaded.levels.isEmpty {
            prop.levels = loaded.levels.map { level in level.map { shown($0, detail: []) } }
            prop.levelTriangles = [triangles(loaded.meshes)] + loaded.levels.map(triangles)
        }
        engine.residencySet.addAllocations(textures.allocations)
        engine.commitResidency()
        return prop
    }

    /// **What a prop's materials are drawn as liquids** — a stylised water's look and its textures, by the material's name
    /// (the last part of its path) — asked once a prop as it loads. Nothing, unless set: a game's from its world file
    /// (``WorldFile/liquids``), an editor's from wherever it keeps them.
    public var liquids: (URL) -> [String: (look: WorldFile.Liquid.Look, textures: [String: URL])] = { _ in [:] }
    /// **What a prop's materials are grimed with** by where they are, and the map, by the material's name — asked as it loads.
    public var grime: (URL) -> [String: (look: WorldFile.Grime.Look, map: URL)] = { _ in [:] }

    /// Every liquid look loaded, by its numbers and textures: one each however many props wear it.
    private var liquidLooks: [LiquidKey: LiquidLook] = [:]
    private struct LiquidKey: Hashable { let look: WorldFile.Liquid.Look; let textures: [String: URL] }
    /// How many liquid looks a frame's uniforms hold.
    private static let liquidCapacity = 32

    /// Every grime look loaded, by its numbers and map.
    private var grungeLooks: [GrungeKey: GrungeLook] = [:]
    private struct GrungeKey: Hashable { let look: WorldFile.Grime.Look; let map: URL }
    private lazy var grungeBuffer: MTLBuffer = {
        let buffer = device.makeBuffer(length: 256 * MemoryLayout<GrungeUniforms>.stride, options: .storageModeShared)!
        buffer.label = "Grime Uniforms"
        engine.residencySet.addAllocation(buffer)
        engine.commitResidency()
        return buffer
    }()
    /// What a submesh without grime binds: its numbers say off, and the store's white stands in for a map.
    private lazy var noGrunge: GrungeLook = {
        var off = GrungeUniforms(colour: .zero, params: SIMD4(0, 1, 1, 0))
        grungeBuffer.contents().copyMemory(from: &off, byteCount: MemoryLayout<GrungeUniforms>.stride)
        return GrungeLook(map: textures.white, uniforms: grungeBuffer.gpuAddress)
    }()

    /// A grime look with its map loaded, made once — nil past the 255 the buffer holds, or a map that will not load.
    private func grungeLook(_ look: WorldFile.Grime.Look, map url: URL) -> GrungeLook? {
        let key = GrungeKey(look: look, map: url)
        if let known = grungeLooks[key] { return known }
        _ = noGrunge
        guard grungeLooks.count < 255, let map = try? textures.texture(.url(url), isColor: true) else { return nil }
        var uniforms = GrungeUniforms(colour: SIMD4(look.colour, look.intensity),
                                      params: SIMD4(look.tiling, look.falloff, look.albedoTiling, 1))
        let offset = (grungeLooks.count + 1) * MemoryLayout<GrungeUniforms>.stride
        grungeBuffer.contents().advanced(by: offset).copyMemory(from: &uniforms, byteCount: MemoryLayout<GrungeUniforms>.stride)
        let made = GrungeLook(map: map, uniforms: grungeBuffer.gpuAddress + UInt64(offset))
        grungeLooks[key] = made
        return made
    }

    /// Binds a submesh's grime for `propFragment` — or none.
    private func bindGrunge(_ grime: GrungeLook?) {
        let look = grime ?? noGrunge
        argumentTable.setAddress(look.uniforms, index: 5)
        argumentTable.setTexture(look.map.gpuResourceID, index: 3)
    }

    /// A liquid's look with its textures loaded — the store's white for any it cannot load, said once.
    private func liquidLook(_ look: WorldFile.Liquid.Look, textures files: [String: URL]) -> LiquidLook? {
        let key = LiquidKey(look: look, textures: files)
        if let known = liquidLooks[key] { return known }
        guard liquidLooks.count < Self.liquidCapacity else { return nil }
        func load(_ name: String?, colour: Bool) -> MTLTexture {
            guard let name, let url = files[name] else { return textures.white }
            do { return try textures.texture(.url(url), isColor: colour) } catch {
                NSLog("WorldRenderer: a liquid's texture \(url.lastPathComponent) did not load — \(error)")
                return textures.white
            }
        }
        let made = LiquidLook(look: look, sheet: load(look.scrollTexture, colour: true),
                              noise: load(look.noiseTexture, colour: false), normals: load(look.normalTexture, colour: false),
                              index: liquidLooks.count)
        liquidLooks[key] = made
        return made
    }

    /// **Far pictures, made the first time a scatter needs one** — `nil` where a prop was asked and has none (2026-11-01).
    /// Only scattered copies are drawn as pictures: a placed building or a cave piece under the ground is laid out by
    /// hand, seen at every distance, and a camera-facing square of a piece below the ground could show above it.
    private var farPictures: [URL: Impostor?] = [:]

    /// A loaded prop as a scatter draws it: its far picture made first, if it can have one.
    private func scatteredProp(_ url: URL) -> PropMeshes? {
        guard var prop = props[url] else { return nil }
        if farPictures[url] == nil {
            let made = makeImpostor(for: prop, named: url.deletingPathExtension().lastPathComponent)
            made?.sway = swayVector(for: url, bounds: prop.bounds).x
            farPictures[url] = .some(made)
            if made != nil { engine.commitResidency() }
        }
        prop.impostor = farPictures[url] ?? nil
        return prop
    }

    /// **A scattered prototype as it is drawn** (2026-11-01, `WorldScene.Scatter.looks`): its prop dressed in what it wears, with a
    /// far picture of its own baked from it dressed — the plain prop's picture would show its own materials far off.
    /// The plain prop until what it wears is loaded.
    private func scatteredProp(_ url: URL, wearing look: [String: WorldScene.Worn]) -> PropMeshes? {
        guard !look.isEmpty else { return scatteredProp(url) }
        guard let plain = props[url] else { return nil }
        guard var prop = dressed(plain, wearing: look) else { return scatteredProp(url) }
        let key = LookKey(prop: url, materials: look)
        if dressedFarPictures[key] == nil {
            let worn = look.values.map(\.name).sorted().joined(separator: ", ")
            let made = makeImpostor(for: prop, named: "\(url.deletingPathExtension().lastPathComponent) wearing \(worn)")
            made?.sway = swayVector(for: url, bounds: prop.bounds).x
            dressedFarPictures[key] = .some(made)
            if made != nil { engine.commitResidency() }
        }
        prop.impostor = dressedFarPictures[key] ?? nil
        return prop
    }

    /// **A far picture shades its foliage by the prop's kind** (`foliageBend`), so one whose kind the scene changed is baked
    /// again where it is — the same textures, drawn over at the next frame's pre-pass.
    private func rebakeFarPicturesForSway() {
        let pictures = farPictures.compactMap { url, picture in picture.map { (url, $0) } }
            + dressedFarPictures.compactMap { key, picture in picture.map { (key.prop, $0) } }
        for (url, picture) in pictures {
            guard let bounds = props[url]?.bounds else { continue }
            let kind = swayVector(for: url, bounds: bounds).x
            guard kind != picture.sway else { continue }
            picture.sway = kind
            picture.isBaked = false
            if !impostorsToBake.contains(where: { $0 === picture }) { impostorsToBake.append(picture) }
        }
    }

    /// Far pictures of scattered prototypes dressed in other materials, by prop and look — `nil` where one has none.
    private var dressedFarPictures: [LookKey: Impostor?] = [:]

    /// Props whose coarsest level is fewer triangles than this get no far picture: two triangles a copy would save little.
    static let impostorTriangles = 256

    /// **A far picture for a prop that is worth one**, its textures made and the bake queued (``impostorsToBake``); nil for
    /// a light prop, glass, or anything that glows. Drawn from the level a far copy draws — the prop's own coarsest, or
    /// its full mesh where the levels are made by simplifying it (they stray under half a pixel from it).
    private func makeImpostor(for prop: PropMeshes, named name: String) -> Impostor? {
        let source = prop.levels.isEmpty ? (meshes: prop.meshes, tier: 0) : prop.meshes(at: prop.levels.count)
        var triangles = 0
        for shown in source.meshes {
            for submesh in shown.loaded.mesh.submeshes.indices {
                if shown.seeThrough[submesh] || simd_reduce_max(shown.material(submesh).emissive) > 0 { return nil }
                triangles += shown.indices(submesh: submesh, level: source.tier).count / 3
            }
        }
        guard triangles >= Self.impostorTriangles else { return nil }
        let radius = simd_length(prop.bounds.maximum - prop.bounds.minimum) / 2
        guard radius > 0 else { return nil }
        // A tree's picture at 128 pixels a view, a clump of flowers' at 64: 12 MB and 3 MB with its three maps and mipmaps.
        let size = radius >= 3 ? 128 : 64
        func array(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = size
            d.height = size
            d.arrayLength = ImpostorViews.count
            d.mipmapLevelCount = Int(log2(Double(size))) + 1
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            let texture = device.makeTexture(descriptor: d)
            texture?.label = label
            return texture
        }
        guard let albedo = array(.rgba8Unorm_srgb, "\(name), far picture"),
              let normals = array(.rgba8Unorm, "\(name), far picture normals"),
              let depth = array(.r8Unorm, "\(name), far picture depth")
        else { return nil }
        engine.residencySet.addAllocations([albedo, normals, depth])
        let leaves = source.meshes.lazy.flatMap { shown in shown.cutoffs.indices.map { (shown, $0) } }
            .first { $0.0.cutoffs[$0.1] > 0 } ?? source.meshes.first.map { ($0, 0) }
        let impostor = Impostor(name: name, albedo: albedo, normals: normals, depth: depth, size: size, centre: prop.bounds.center,
                                radius: radius, roughness: leaves.map { $0.0.material($0.1).roughness } ?? 1, source: source)
        impostorsToBake.append(impostor)
        return impostor
    }

    /// Far pictures made but not drawn yet — baked in the next frame's pre-passes.
    private var impostorsToBake: [Impostor] = []
    /// Whether this frame baked any: the scene pass then waits for their mipmaps (``encode(into:frameSlot:interpolation:)``).
    private var bakedImpostorsThisFrame = false
    /// Depth for the bake, one array per picture size, kept.
    private var impostorDepth: [Int: MTLTexture] = [:]

    /// **Draws every queued far picture**: each view of the prop's meshes into its slice — all 64 in one draw a submesh,
    /// a layer each — then their mipmaps.
    private func encodeImpostorBakes(into commandBuffer: MTL4CommandBuffer) {
        bakedImpostorsThisFrame = false
        guard !impostorsToBake.isEmpty else { return }
        var baked: [Impostor] = []
        for impostor in impostorsToBake {
            let size = impostor.size
            if impostorDepth[size] == nil {
                let d = MTLTextureDescriptor()
                d.textureType = .type2DArray
                d.pixelFormat = .depth32Float
                d.width = size
                d.height = size
                d.arrayLength = ImpostorViews.count
                d.usage = .renderTarget
                d.storageMode = .private
                guard let depth = device.makeTexture(descriptor: d) else { continue }
                depth.label = "Far picture depth"
                engine.residencySet.addAllocations([depth])
                engine.commitResidency()
                impostorDepth[size] = depth
            }
            guard let depth = impostorDepth[size] else { continue }
            // Each mesh into the unit sphere round the prop's centre; the views look at it from outside.
            let toUnit = simd_float4x4(diagonal: SIMD4(1 / impostor.radius, 1 / impostor.radius, 1 / impostor.radius, 1))
                * simd_float4x4(translation: -impostor.centre)
            var parts: [ShadowPart] = []
            for shown in impostor.source.meshes {
                for submesh in shown.loaded.mesh.submeshes.indices {
                    let material = shown.material(submesh)
                    guard let address = write(ObjectUniforms(
                        model: toUnit * shown.loaded.nodeTransform, normalMatrix: matrix_identity_float4x4,
                        baseColour: material.baseColor, emissive: .zero,
                        params: SIMD4(material.roughness, 0, shown.cutoffs[submesh], 0),
                        sway: SIMD4(impostor.sway, 0, 0, 0))) else { return }
                    parts.append(ShadowPart(mesh: shown.loaded.mesh, indices: shown.indices(submesh: submesh, level: impostor.source.tier),
                                            uniforms: address, baseMap: shown.baseMaps[submesh], copies: nil))
                }
            }
            let pass = MTL4RenderPassDescriptor()
            pass.renderTargetArrayLength = ImpostorViews.count
            for (index, target) in [impostor.albedo, impostor.normals, impostor.depth].enumerated() {
                pass.colorAttachments[index].texture = target
                pass.colorAttachments[index].loadAction = .clear
                pass.colorAttachments[index].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[index].storeAction = .store
            }
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Far picture"
            // **One depth array serves every bake**, and Metal 4 orders nothing between passes unasked: without this a
            // bake clears the depth the one before it is still testing against.
            encoder.barrier(afterQueueStages: .fragment, beforeStages: [.vertex, .fragment], visibilityOptions: .device)
            encoder.setRenderPipelineState(impostorBakePipeline)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(size), height: Double(size), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: size, height: size))
            encoder.setDepthStencilState(impostorBakeDepthState)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(.none)
            for part in parts {
                part.indices.bindVertices(of: part.mesh, to: argumentTable)
                argumentTable.setAddress(part.uniforms, index: 1)
                argumentTable.setTexture(part.baseMap.gpuResourceID, index: 0)
                encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: part.indices.count,
                                              indexType: part.indices.type, indexBuffer: part.indices.address,
                                              indexBufferLength: part.indices.length, instanceCount: ImpostorViews.count)
            }
            encoder.endEncoding()
            baked.append(impostor)
        }
        guard !baked.isEmpty, let mipmaps = commandBuffer.makeComputeCommandEncoder() else { return }
        mipmaps.label = "Far picture mipmaps"
        mipmaps.barrier(afterQueueStages: .fragment, beforeStages: .blit, visibilityOptions: .device)
        for impostor in baked {
            mipmaps.generateMipmaps(texture: impostor.albedo)
            mipmaps.generateMipmaps(texture: impostor.normals)
            mipmaps.generateMipmaps(texture: impostor.depth)
            impostor.isBaked = true
        }
        mipmaps.endEncoding()
        impostorsToBake.removeAll(where: \.isBaked)
        bakedImpostorsThisFrame = true
    }

    /// **A prop's far picture as one image**, its 64 views in their 8 × 8 grid — colour over magenta where it is empty, or
    /// with `normals` the normals — to look at one. Nil if the prop has no baked picture.
    public func farPicturePNG(named name: String, normals: Bool = false) -> Data? {
        guard let impostor = (farPictures.values.compactMap({ $0 }) + dressedFarPictures.values.compactMap({ $0 }))
                .first(where: { $0.name == name }), impostor.isBaked,
              let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        let size = impostor.size, side = ImpostorViews.side, row = size * 4, slice = row * size
        guard let buffer = device.makeBuffer(length: slice * ImpostorViews.count, options: .storageModeShared) else { return nil }
        let source = normals ? impostor.normals : impostor.albedo
        for view in 0..<ImpostorViews.count {
            blit.copy(from: source, sourceSlice: view, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: size, height: size, depth: 1), to: buffer,
                      destinationOffset: view * slice, destinationBytesPerRow: row, destinationBytesPerImage: slice)
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let width = size * side
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: slice * ImpostorViews.count)
        for view in 0..<ImpostorViews.count {
            let ox = (view % side) * size, oy = (view / side) * size
            for y in 0..<size {
                for x in 0..<size {
                    let i = view * slice + y * row + x * 4, o = ((oy + y) * width + ox + x) * 4
                    let a = Float(bytes[i + 3]) / 255
                    for c in 0..<3 {
                        // Premultiplied: what is drawn, over magenta where it is not.
                        let back: Float = c == 1 ? 0 : 255
                        pixels[o + c] = UInt8(min(255, Float(bytes[i + c]) + back * (1 - a)))
                    }
                    pixels[o + 3] = 255
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage(), let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// One run of far pictures in view, its uniforms written.
    private struct ImpostorDraw {
        let impostor: Impostor
        let uniforms: UInt64
        let instances: (address: UInt64, count: Int)
    }
    private var preparedImpostors: [ImpostorDraw] = []
    /// The last frame's far pictures in view, by prop, and how many copies each.
    public var impostorsDrawn: [(String, Int)] { preparedImpostors.map { ($0.impostor.name, $0.instances.count) } }

    /// **See-through: an opacity below one, and no cut-out** (2026-10-31) — glass, which a pack's material says is as
    /// see-through as its tint (a converted prop carries it as a plain opacity). Drawn after everything solid, blended,
    /// and casting no shadow. Until then it was drawn solid, and a town's windows were white panes.
    static func isSeeThrough(_ material: Ductane.Material) -> Bool {
        material.alphaCutoff == nil && material.baseColor.w < 0.999
    }

    /// A mesh's lower-detail levels in one buffer — each level's vertices, then its indices — as ranges to draw.
    private func detailRanges(_ levels: [MeshDetail.Tier]) -> ([[IndexRange]], MTLBuffer?) {
        let total = levels.reduce(0) { $0 + $1.vertices.count + $1.submeshes.reduce(0) { $0 + $1.count * 4 } }
        guard total > 0, let buffer = device.makeBuffer(length: total, options: .storageModeShared) else { return ([], nil) }
        buffer.label = "Lower-detail levels"
        var at = 0
        func append(_ bytes: UnsafeRawBufferPointer) -> Int {
            let offset = at
            if bytes.count > 0 { (buffer.contents() + at).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            at += bytes.count
            return offset
        }
        let ranges = levels.map { level in
            let vertices = buffer.gpuAddress + UInt64(level.vertices.withUnsafeBytes(append))
            return level.submeshes.map { indices in
                IndexRange(buffer: buffer, offset: indices.withUnsafeBytes(append), count: indices.count,
                           vertices: vertices)
            }
        }
        engine.residencySet.addAllocations([buffer])
        return (ranges, buffer)
    }

    /// A loaded mesh's lower-detail tiers (Ductane's `MeshDetail`).
    nonisolated static func detailLevels(_ mesh: LoadedMesh) -> [MeshDetail.Tier] {
        MeshDetail.tiers(for: mesh, vertexDescriptor: vertexDescriptor(), positionAttribute: 0, normalAttribute: 1)
    }

    /// Lets props that failed be tried again — a drive has come back.
    public func forgetFailures() {
        failedProps.removeAll()
        failureGeneration += 1
    }
    /// Counts ``forgetFailures()``, so a load that began before it knows its failures are out of date.
    private var failureGeneration = 0

    /// Props whose files changed on disk — a character Rigkin exported again over the same file — are read again,
    /// textures included, at the next load.
    public func reload(_ urls: Set<URL>) {
        // **What the dropped props held on the GPU is retired**, not left in the residency set (2026-10-28): it kept every
        // mesh, level and texture alive, and switching texture quality from half to full and back took the
        // app from 1.9 GB to 6.1 and climbing. The same leak was in reloading a prop whose file changed.
        let texturesBefore = textures.allocations
        var dropped: [any MTLAllocation] = []
        for url in urls {
            if let prop = props[url] { dropped += Self.allocations(of: prop) }
            if let impostor = farPictures[url] ?? nil {
                impostorsToBake.removeAll { $0 === impostor }
                dropped += [impostor.albedo, impostor.normals, impostor.depth]
            }
            farPictures[url] = nil
            if let cap = snowCaps[url] ?? nil { dropped += [cap.vertices, cap.indexBuffer] }
            snowCaps[url] = nil
            // A dressed picture shows both its prop and what it wears: either changing, it is baked again.
            for (key, picture) in dressedFarPictures where key.prop == url || key.materials.values.contains(where: { $0.file == url }) {
                if let picture {
                    impostorsToBake.removeAll { $0 === picture }
                    dropped += [picture.albedo, picture.normals, picture.depth]
                }
                dressedFarPictures[key] = nil
            }
            props[url] = nil
            collisionCache[url] = nil
            failedProps.remove(url)
            textures.forget(file: url)
        }
        retire(dropped + Self.forgotten(texturesBefore, now: textures.allocations))
        forgetTurning(urls)
    }

    /// Everything a prop's meshes hold on the GPU but textures, which the store shares between props.
    private static func allocations(of prop: PropMeshes) -> [any MTLAllocation] {
        (prop.meshes + prop.levels.flatMap { $0 }).flatMap { shown -> [any MTLAllocation] in
            shown.loaded.mesh.vertexBuffers.map(\.buffer) + shown.loaded.mesh.submeshes.map(\.indexBuffer.buffer)
                + (shown.detailBuffer.map { [$0] } ?? [])
        }
    }

    /// The textures the store held before and holds no longer.
    private static func forgotten(_ before: [any MTLAllocation], now: [any MTLAllocation]) -> [any MTLAllocation] {
        let kept = Set(now.map { ObjectIdentifier($0) })
        return before.filter { !kept.contains(ObjectIdentifier($0)) }
    }

    /// Out of the residency set once every frame that might still draw them is done — and so freed.
    private func retire(_ allocations: [any MTLAllocation]) {
        guard !allocations.isEmpty else { return }
        retired.append(([], allocations, framesEncoded + FrameRenderer.maxFramesInFlight + 1))
    }

    /// A prop's box in its own space, if it is loaded.
    public func bounds(of url: URL) -> BoundingBox? { props[url]?.bounds }

    /// Whether a prop is drawn all in cut-out cards — grass, flowers, leaves — with nothing solid.
    public func isCutOut(_ url: URL) -> Bool {
        guard let prop = props[url] else { return false }
        return prop.meshes.allSatisfy { !$0.cutoffs.isEmpty && $0.cutoffs.allSatisfy { $0 > 0 } }
    }

    /// **A prop's solid triangles, in its own space** — what a walker stands on and walks into (``CollisionMesh``); nil
    /// if it is not loaded. Read once from the full-detail mesh and kept.
    ///
    /// **Leaves and grass are left out**: a submesh cut out by its texture's alpha is foliage, and a bush or a grass
    /// clump made of walls would stop a walker in a meadow. A tree keeps its trunk. Whether a walker passes through the
    /// whole prop — some packs' reeds are solid meshes — is the scene's rule, not this (``WorldFile/walkedThrough``).
    ///
    /// **Where the prop's maker made a shape to meet, that is it** (``collisionShape``): a pack's simpler collision model,
    /// a stair's flights as ramps, a shack's walls without their trim.
    public func collisionTriangles(of url: URL) -> [SIMD3<Float>]? {
        if let kept = collisionCache[url] { return kept }
        guard let prop = props[url] else { return nil }
        if let triangles = collisionShape(url) {
            collisionCache[url] = triangles
            return triangles
        }
        var triangles: [SIMD3<Float>] = []
        for shown in prop.meshes {
            let mesh = shown.loaded.mesh
            guard let vertices = mesh.vertexBuffers.first, vertices.buffer.storageMode != .private else { continue }
            let stride = 32   // ``vertexDescriptor()``: the position first
            let base = vertices.buffer.contents() + vertices.offset
            for (index, submesh) in mesh.submeshes.enumerated()
            where submesh.primitiveType == .triangle && (index >= shown.cutoffs.count || shown.cutoffs[index] == 0) {
                let indices = submesh.indexBuffer
                guard indices.buffer.storageMode != .private else { continue }
                TriangleReader.append(vertices: base, stride: stride, indices: indices.buffer.contents() + indices.offset,
                                        count: submesh.indexCount, wide: submesh.indexType == .uint32,
                                        node: shown.loaded.nodeTransform, to: &triangles)
            }
        }
        collisionCache[url] = triangles
        return triangles
    }

    private var collisionCache: [URL: [SIMD3<Float>]] = [:]

    /// **The shape a walker meets where a prop's maker made one** — its triangles in the prop's own space — or nil to meet
    /// the prop as drawn. A game's from its world file (``WorldPackage/collisionShapes()``).
    public var collisionShape: (URL) -> [SIMD3<Float>]? = { _ in nil }

    /// **The props a walker passes through**, by file — grass, reeds, litter — left out of ``solids(around:reach:)``. A
    /// game's from its world file (``WorldFile/walkedThrough``), set by ``show(_:loaded:)``.
    public var walkedThrough: Set<URL> = []

    // MARK: Ground

    /// Shows a ground, or none. Cheap to call every tick of a brush stroke: given what the tick `changed`, only that
    /// patch is written, and the GPU's copies catch up a frame at a time.
    ///
    /// **The ground is not kept here.** Its vertices are written at once into ``terrainMirror`` and the value let go —
    /// because holding it would share an editor's stroke's arrays, and the stroke's next tick would then copy all of them:
    /// a million heights, and eight million weights, sixty times a second. Whether a ground was already shown is told by
    /// its ``WorldGroundSource/lineage`` and ``WorldGroundSource/revision``, not by comparing it.
    public func showGround(_ ground: (any WorldGroundSource)?, changed: WorldGroundRegion? = nil) {
        guard let terrain = ground else {
            if terrainKey != nil { terrainKey = nil; terrainShape = nil; terrainMirror = []; terrainHoles = []; groundChunks = nil }
            if !groundLayers.isEmpty { groundLayers = []; refreshGroundTextures() }
            return
        }
        let key = TerrainKey(lineage: terrain.lineage, revision: terrain.revision)
        guard key != terrainKey else { return }
        terrainKey = key
        let shape = TerrainShape(size: terrain.size, resolution: terrain.resolution)
        if let changed, shape == terrainShape, !terrainMirror.isEmpty {
            let region = changed.expanded(by: 1, within: terrain.resolution)
            writeMirror(terrain, region)
            groundChunksDirty = groundChunksDirty.map { $0.union(region) } ?? region
            writeHoles(terrain, region)
            for i in terrainPending.indices { terrainPending[i] = terrainPending[i].map { $0.union(region) } ?? region }
        } else {
            terrainShape = shape
            terrainMirror = [Float](repeating: 0, count: terrain.pointsPerSide * terrain.pointsPerSide * 12)
            writeMirror(terrain, terrain.allPoints)
            groundChunks = GroundChunks(resolution: terrain.resolution, size: terrain.size)
            groundChunksDirty = terrain.allPoints
            // Copied, not shared: sharing would make the stroke's next cut copy every cell.
            terrainHoles = terrain.holes.map { $0 }
            terrainPending = []   // every GPU copy is rebuilt with the new shape
        }
        terrainDirty = true
    }

    private struct TerrainKey: Equatable { let lineage: UUID; let revision: Int }
    private struct TerrainShape: Equatable { let size: Float; let resolution: Int }
    private var terrainKey: TerrainKey?
    private var terrainShape: TerrainShape?
    /// Every vertex of the shown ground, as the GPU takes it: position, normal, uv, colour.
    private var terrainMirror: [Float] = []
    /// Per GPU copy, the patch it has not caught up with yet.
    private var terrainPending: [WorldGroundRegion?] = []
    /// The shown ground's cut cells, as ``WorldGroundSource/holes``: empty while there are none.
    private var terrainHoles: [Bool] = [] { didSet { groundHoleChunksDirty = true } }
    /// Which ground chunks hold a hole — drawn full however far away (``GroundChunks/viewRanges``).
    private var groundHoleChunks: [Bool] = []
    private var groundHoleChunksDirty = true

    /// **A hole is drawn as nothing**: its cell's two triangles become points, which draw nothing and cast no shadow,
    /// so the index buffer keeps its layout and a cut rewrites only the cells it touched. Written in place — a frame
    /// still in flight may show a cell cut a frame early, which is nothing anyone can see.
    private func writeHoles(_ terrain: any WorldGroundSource, _ region: WorldGroundRegion) {
        guard terrain.hasHoles || !terrainHoles.isEmpty else { return }
        let resolution = terrain.resolution
        if terrainHoles.count != resolution * resolution { terrainHoles = Array(repeating: false, count: resolution * resolution) }
        let xs = region.x.lowerBound..<min(region.x.upperBound + 1, resolution)
        let zs = region.z.lowerBound..<min(region.z.upperBound + 1, resolution)
        guard !xs.isEmpty, !zs.isEmpty else { return }
        for z in zs { for x in xs { terrainHoles[z * resolution + x] = terrain.isHole(x, z) } }
        if !terrainHoles.contains(true) { terrainHoles = [] }
        guard let indices = terrainIndices, terrainResolution == resolution else { return }
        let out = indices.contents().bindMemory(to: UInt32.self, capacity: resolution * resolution * 6)
        for z in zs { for x in xs { writeCell(x, z, resolution: resolution, into: out) } }
    }

    /// One cell's six indices: two triangles, or — a hole — six times its first corner.
    private func writeCell(_ x: Int, _ z: Int, resolution: Int, into out: UnsafeMutablePointer<UInt32>) {
        let n = resolution + 1
        let a = UInt32(z * n + x), b = a + UInt32(n), c = b + 1, d = a + 1
        let o = groundChunks?.offset(x, z) ?? (z * resolution + x) * 6
        if !terrainHoles.isEmpty, terrainHoles[z * resolution + x] {
            for k in 0..<6 { out[o + k] = a }
        } else {
            out[o] = a; out[o + 1] = b; out[o + 2] = c; out[o + 3] = a; out[o + 4] = c; out[o + 5] = d
        }
    }

    /// **The shown ground's height under (x, z)**, between points by bilinear interpolation — read from what the GPU
    /// draws, since the ground itself is not kept. `nil` off it, and over a hole unless `holes` is false.
    public func groundHeight(x: Float, z: Float, holes: Bool = true) -> Float? {
        guard let shape = terrainShape, !terrainMirror.isEmpty, abs(x) <= shape.size / 2, abs(z) <= shape.size / 2 else { return nil }
        let n = shape.resolution + 1, spacing = shape.size / Float(shape.resolution)
        let gx = (x + shape.size / 2) / spacing, gz = (z + shape.size / 2) / spacing
        let x0 = min(Int(gx), shape.resolution - 1), z0 = min(Int(gz), shape.resolution - 1)
        if holes, !terrainHoles.isEmpty, terrainHoles[z0 * shape.resolution + x0] { return nil }
        let fx = gx - Float(x0), fz = gz - Float(z0)
        func h(_ x: Int, _ z: Int) -> Float { terrainMirror[(z * n + x) * 12 + 1] }
        return (h(x0, z0) * (1 - fx) + h(x0 + 1, z0) * fx) * (1 - fz) + (h(x0, z0 + 1) * (1 - fx) + h(x0 + 1, z0 + 1) * fx) * fz
    }

    private func writeMirror(_ terrain: any WorldGroundSource, _ region: WorldGroundRegion) {
        writeGroundLayers(terrain, region)
        // Written by the ground, optimised (`WorldGroundVertices`): point by point here it was a second and a half of
        // opening a big scene in a Debug build.
        terrainMirror.withUnsafeMutableBufferPointer { vertices in
            terrain.writeVertices(xs: region.x, zs: region.z, into: vertices.baseAddress!)
        }
        // **Where puddles gather** follows the ground: worked out over the changed patch and as far round it as a point's
        // hollow is judged (``WorldGroundSource/puddleReach``), straight into the buffer the shader reads.
        let points = terrain.pointsPerSide * terrain.pointsPerSide
        if puddleFieldBuffer == nil || puddleFieldBuffer!.length < points * 4 {
            puddleFieldBuffer = engine.device.makeBuffer(length: points * 4, options: .storageModeShared)
            puddleFieldBuffer?.label = "Puddle Field"
            if let puddleFieldBuffer { engine.residencySet.addAllocation(puddleFieldBuffer); engine.commitResidency() }
            writePuddleField(terrain, terrain.allPoints)
        } else {
            let reach = Int((terrain.puddleReach / terrain.spacing).rounded(.up)) + 1
            writePuddleField(terrain, region.expanded(by: reach, within: terrain.resolution))
        }
    }

    // MARK: Textured layers

    /// The shown ground's layers (``WorldGroundSource/layers``): empty, or while none has a texture, the ground is drawn in
    /// its vertices' colours.
    private var groundLayers: [WorldGroundLayer] = []
    /// Their textures on the GPU, once loaded; nil while none has one, and while the first set loads.
    private var groundTextures: WorldGroundTextures?
    /// What ``groundTextures`` holds, or is being loaded with: the texture sets and the slice size.
    private var groundTexturesKey: GroundTexturesKey?
    private struct GroundTexturesKey: Equatable { let maps: [WorldGroundTexture]; let size: Int }
    /// Each point's painted weights, eight bytes a point (``WorldGroundWeights``) — written only while a layer has a texture.
    private var groundWeightBuffer: MTLBuffer?
    /// **Loads the ground's layer textures on the calling thread** rather than in the background — for a single frame
    /// drawn to check a scene, which has no later frame to show them in.
    public var loadsGroundTexturesAtOnce = false
    /// Called when the ground's layer textures have loaded, or could not be: an editor redraws, or says which file failed.
    public var onGroundTexturesLoaded: ((Error?) -> Void)?

    /// Keeps the layers, and while any has a texture, the patch's weights and the textures to draw them with.
    private func writeGroundLayers(_ terrain: any WorldGroundSource, _ region: WorldGroundRegion) {
        let layers = terrain.paintedLayers
        if layers != groundLayers { groundLayers = layers }
        guard terrain.isTextured else {
            if groundWeightBuffer != nil {
                retired.append(([], [groundWeightBuffer!], framesEncoded + FrameRenderer.maxFramesInFlight + 1))
                groundWeightBuffer = nil
            }
            refreshGroundTextures()
            return
        }
        let points = terrain.pointsPerSide * terrain.pointsPerSide
        let length = points * WorldGroundWeights.bytesPerPoint
        if groundWeightBuffer == nil || groundWeightBuffer!.length != length {
            if let old = groundWeightBuffer { retired.append(([], [old], framesEncoded + FrameRenderer.maxFramesInFlight + 1)) }
            groundWeightBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            groundWeightBuffer?.label = "Ground Layer Weights"
            if let buffer = groundWeightBuffer { engine.residencySet.addAllocation(buffer); engine.commitResidency() }
            if let buffer = groundWeightBuffer {
                terrain.writeWeights(xs: 0...terrain.resolution, zs: 0...terrain.resolution,
                                     into: buffer.contents().bindMemory(to: UInt8.self, capacity: length))
            }
        } else if let buffer = groundWeightBuffer {
            // Written in place, as the puddles are: a frame in flight may blend a brushed patch a frame early.
            terrain.writeWeights(xs: region.x, zs: region.z, into: buffer.contents().bindMemory(to: UInt8.self, capacity: length))
        }
        refreshGroundTextures()
    }

    /// **Loads the layers' textures when the set of them changes** — or the texture quality does — in the background, the
    /// old ones drawn until the new are ready; at once with ``loadsGroundTexturesAtOnce``.
    private func refreshGroundTextures() {
        var maps: [WorldGroundTexture] = []
        for layer in groundLayers { if let t = layer.texture?.maps, !maps.contains(t) { maps.append(t) } }
        guard !maps.isEmpty else {
            if let old = groundTextures {
                retired.append(([old], old.allocations, framesEncoded + FrameRenderer.maxFramesInFlight + 1))
            }
            groundTextures = nil
            groundTexturesKey = nil
            return
        }
        let key = GroundTexturesKey(maps: maps, size: WorldGroundTextures.size(for: graphics.textureQuality))
        guard key != groundTexturesKey else { return }
        groundTexturesKey = key
        if loadsGroundTexturesAtOnce {
            adoptGroundTextures(Result { try WorldGroundTextures.make(device: device, textures: maps, size: key.size) }, for: key)
            return
        }
        let device = Loaded.Device(self.device)
        let wanted = maps, size = key.size
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<WorldGroundTextures, Error> in
                Result { try WorldGroundTextures.make(device: device.device, textures: wanted, size: size) }
            }.value
            adoptGroundTextures(result, for: key)
        }
    }

    private func adoptGroundTextures(_ result: Result<WorldGroundTextures, Error>, for key: GroundTexturesKey) {
        // A newer set was asked for while this one loaded: it is not shown.
        guard key == groundTexturesKey else { return }
        switch result {
        case .success(let fresh):
            if let old = groundTextures {
                retired.append(([old], old.allocations, framesEncoded + FrameRenderer.maxFramesInFlight + 1))
            }
            groundTextures = fresh
            engine.residencySet.addAllocations(fresh.allocations)
            engine.commitResidency()
            onGroundTexturesLoaded?(nil)
        case .failure(let error):
            NSLog("WorldRenderer: the ground's layer textures did not load — \(error)")
            onGroundTexturesLoaded?(error)
        }
    }

    /// The layers as the textured ground pipeline reads them, or nil when the ground is drawn in its colours.
    private func groundLayerUniforms() -> GroundLayerUniforms? {
        guard let textures = groundTextures, groundWeightBuffer != nil, groundLayers.contains(where: { $0.texture != nil })
        else { return nil }
        var uniforms = GroundLayerUniforms()
        for (index, layer) in groundLayers.prefix(8).enumerated() {
            let slice = textures.slice(of: layer.texture).map(Float.init) ?? -1
            uniforms.values[index] = SIMD4(layer.colour, slice)
            uniforms.values[8 + index] = SIMD4(1 / (layer.texture?.tileSize ?? WorldGroundTexture.defaultTileSize), 1, 0, 0)
        }
        // Layers the ground does not have are never painted, so never read; untextured all the same.
        for index in min(groundLayers.count, 8)..<8 { uniforms.values[index].w = -1 }
        return uniforms
    }

    private func writePuddleField(_ terrain: any WorldGroundSource, _ region: WorldGroundRegion) {
        guard let puddleFieldBuffer else { return }
        terrain.writePuddles(xs: region.x, zs: region.z,
                             into: puddleFieldBuffer.contents().bindMemory(to: Float.self, capacity: terrain.heights.count))
    }

    private var terrainDirty = false
    /// **Several vertex buffers, written in turn**, so a stroke never rewrites heights a frame still in
    /// flight is reading — which would draw a torn ground for a frame.
    private var terrainVertices: [MTLBuffer] = []
    private var terrainVertexIndex = 0
    private var terrainIndices: MTLBuffer?
    /// The ground's coarser levels' indices (``GroundChunks/coarseIndices()``), into the same vertices.
    private var terrainCoarseIndices: MTLBuffer?
    private var terrainIndexCount = 0
    private var terrainResolution = 0

    /// **The ground in chunks of 32 by 32 cells, each drawn only where it can be seen** (2026-10-26). It was drawn whole
    /// into the view and into each of the sun's four cascades — 1.3 million triangles of a 400 m zone five times a
    /// frame, the nearest cascade 24 m across. The index buffer is laid out chunk after chunk, so the chunks a frustum
    /// keeps are a few runs of indices.
    private struct GroundChunks {
        static let cells = 32
        let resolution: Int
        let perSide: Int
        let size: Float
        /// Where each chunk's indices start, and how many it has.
        private(set) var starts: [Int] = []
        private(set) var counts: [Int] = []
        /// Each chunk's box, its heights from the ground as last shown.
        var low: [SIMD3<Float>] = []
        var high: [SIMD3<Float>] = []

        /// **Coarser levels** (`WorldGroundDetail`, 2026-11-01): per step, where each chunk's indices start in the coarse
        /// index buffer and how many — laid out step by step, so neighbouring chunks at one step are one run.
        private(set) var coarseStarts: [[Int]] = []
        private(set) var coarseCounts: [[Int]] = []
        /// Per chunk, how far each step strays from the full ground, metres; infinite until measured, or where it does
        /// not fit.
        private(set) var errors: [[Float]] = []
        /// A chunk's triangles at a step, by its width, height and step — nearly every chunk shares one shape.
        private var shapes: [SIMD3<Int32>: [SIMD2<Int32>]] = [:]

        init(resolution: Int, size: Float) {
            self.resolution = resolution
            self.size = size
            perSide = (resolution + Self.cells - 1) / Self.cells
            let spacing = size / Float(resolution)
            var start = 0
            for cz in 0..<perSide {
                for cx in 0..<perSide {
                    let w = min(Self.cells, resolution - cx * Self.cells), h = min(Self.cells, resolution - cz * Self.cells)
                    starts.append(start)
                    counts.append(w * h * 6)
                    start += w * h * 6
                    let x0 = -size / 2 + Float(cx * Self.cells) * spacing, z0 = -size / 2 + Float(cz * Self.cells) * spacing
                    low.append(SIMD3(x0, 0, z0))
                    high.append(SIMD3(x0 + Float(w) * spacing, 0, z0 + Float(h) * spacing))
                }
            }
            var coarse = 0
            for step in WorldGroundDetail.steps {
                var stepStarts: [Int] = [], stepCounts: [Int] = []
                for chunk in starts.indices {
                    let count = shape(chunk, step).count
                    stepStarts.append(coarse)
                    stepCounts.append(count)
                    coarse += count
                }
                coarseStarts.append(stepStarts)
                coarseCounts.append(stepCounts)
            }
            errors = Array(repeating: Array(repeating: .infinity, count: WorldGroundDetail.steps.count), count: starts.count)
        }

        /// A chunk's width and height in cells, and its first point.
        private func extent(_ chunk: Int) -> (w: Int, h: Int, x: Int, z: Int) {
            let cx = chunk % perSide, cz = chunk / perSide
            return (min(Self.cells, resolution - cx * Self.cells), min(Self.cells, resolution - cz * Self.cells),
                    cx * Self.cells, cz * Self.cells)
        }

        private mutating func shape(_ chunk: Int, _ step: Int) -> [SIMD2<Int32>] {
            let e = extent(chunk)
            let key = SIMD3(Int32(e.w), Int32(e.h), Int32(step))
            if let known = shapes[key] { return known }
            let made = WorldGroundDetail.triangles(width: e.w, height: e.h, step: step)
            shapes[key] = made
            return made
        }

        /// Every coarse level's indices, laid out as ``coarseStarts`` says.
        mutating func coarseIndices() -> [UInt32] {
            var out: [UInt32] = []
            out.reserveCapacity((coarseStarts.last?.last ?? 0) + (coarseCounts.last?.last ?? 0))
            for step in WorldGroundDetail.steps {
                for chunk in starts.indices {
                    let e = extent(chunk)
                    let n = UInt32(resolution + 1)
                    out += shape(chunk, step).map { (UInt32(e.z) + UInt32($0.y)) * n + UInt32(e.x) + UInt32($0.x) }
                }
            }
            return out
        }

        /// Where cell (x, z)'s six indices go.
        func offset(_ x: Int, _ z: Int) -> Int {
            let cx = x / Self.cells, cz = z / Self.cells
            let w = min(Self.cells, resolution - cx * Self.cells)
            return starts[cz * perSide + cx] + ((z - cz * Self.cells) * w + (x - cx * Self.cells)) * 6
        }

        /// The chunks' heights again where `region` (grid points) changed, from the shown vertices.
        mutating func updateHeights(_ mirror: [Float], _ region: WorldGroundRegion) {
            let n = resolution + 1
            let cxs = (max(region.x.lowerBound - 1, 0) / Self.cells)...min(region.x.upperBound / Self.cells, perSide - 1)
            let czs = (max(region.z.lowerBound - 1, 0) / Self.cells)...min(region.z.upperBound / Self.cells, perSide - 1)
            for cz in czs {
                for cx in cxs {
                    var lo = Float.infinity, hi = -Float.infinity
                    for z in (cz * Self.cells)...min((cz + 1) * Self.cells, resolution) {
                        for x in (cx * Self.cells)...min((cx + 1) * Self.cells, resolution) {
                            let y = mirror[(z * n + x) * 12 + 1]
                            lo = min(lo, y); hi = max(hi, y)
                        }
                    }
                    // A metre either way: the GPU's copy of a stroke's heights can be a frame or two behind these.
                    low[cz * perSide + cx].y = lo - 1
                    high[cz * perSide + cx].y = hi + 1
                    let chunk = cz * perSide + cx, e = extent(chunk)
                    errors[chunk] = WorldGroundDetail.steps.map { step in
                        guard WorldGroundDetail.fits(width: e.w, height: e.h, step: step) else { return .infinity }
                        let triangles = shape(chunk, step)
                        return mirror.withUnsafeBufferPointer {
                            WorldGroundDetail.error(of: triangles, heights: $0.baseAddress!,
                                                 floatsPerPoint: WorldGroundVertices.floatsPerPoint, pointsPerRow: n,
                                                 originX: e.x, originZ: e.z)
                        }
                    }
                }
            }
        }

        /// **What to draw of the ground for the view**: the chunks the frustum may hold, each at the coarsest step that
        /// strays from the full ground by under half a pixel from `eye` (`WorldGroundDetail.step`) — the full chunks as runs
        /// of the full index buffer, the rest as runs of the coarse one. A chunk with a hole in it is always full: a
        /// coarse level would fill the hole in.
        func viewRanges(_ planes: [SIMD4<Float>], eye: SIMD3<Float>, pixelsPerRadian: Float,
                        holes: [Bool]) -> (full: [Range<Int>], coarse: [Range<Int>]) {
            var full: [Range<Int>] = [], coarse: [Range<Int>] = []
            func add(_ range: Range<Int>, to out: inout [Range<Int>]) {
                if let last = out.last, last.upperBound == range.lowerBound {
                    out[out.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    out.append(range)
                }
            }
            for chunk in starts.indices where Self.mayIntersect(planes, low[chunk], high[chunk]) {
                let nearest = simd_distance(eye, simd_clamp(eye, low[chunk], high[chunk]))
                let step = chunk < holes.count && holes[chunk]
                    ? 1 : WorldGroundDetail.step(errors: errors[chunk], distance: nearest, pixelsPerRadian: pixelsPerRadian)
                if step == 1 {
                    add(starts[chunk]..<(starts[chunk] + counts[chunk]), to: &full)
                } else {
                    let k = WorldGroundDetail.steps.firstIndex(of: step)!
                    add(coarseStarts[k][chunk]..<(coarseStarts[k][chunk] + coarseCounts[k][chunk]), to: &coarse)
                }
            }
            return (full, coarse)
        }

        /// Which chunks hold a hole, from the ground's cut cells.
        func chunksWithHoles(_ holes: [Bool]) -> [Bool] {
            guard !holes.isEmpty else { return [] }
            var out = Array(repeating: false, count: starts.count)
            for (cell, cut) in holes.enumerated() where cut {
                out[(cell / resolution / Self.cells) * perSide + (cell % resolution) / Self.cells] = true
            }
            return out
        }

        private static func mayIntersect(_ planes: [SIMD4<Float>], _ low: SIMD3<Float>, _ high: SIMD3<Float>) -> Bool {
            for plane in planes {
                let normal = SIMD3(plane.x, plane.y, plane.z)
                if simd_dot(normal, low.replacing(with: high, where: normal .>= 0)) + plane.w < 0 { return false }
            }
            return true
        }

        /// The runs of indices to draw for a frustum's planes: the chunks that may be inside it, neighbours merged.
        func ranges(_ planes: [SIMD4<Float>]) -> [Range<Int>] {
            var out: [Range<Int>] = []
            for chunk in starts.indices {
                var inside = true
                for plane in planes {
                    let normal = SIMD3(plane.x, plane.y, plane.z)
                    let positive = low[chunk].replacing(with: high[chunk], where: normal .>= 0)
                    if simd_dot(normal, positive) + plane.w < 0 { inside = false; break }
                }
                guard inside else { continue }
                let range = starts[chunk]..<(starts[chunk] + counts[chunk])
                if let last = out.last, last.upperBound == range.lowerBound {
                    out[out.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    out.append(range)
                }
            }
            return out
        }
    }
    private var groundChunks: GroundChunks?
    private var groundChunksDirty: WorldGroundRegion?
    /// This frame's runs of ground indices: in view, and per cascade.
    private var groundRanges: [Range<Int>] = []
    /// This frame's runs of the coarse ground indices in view.
    private var groundCoarseRanges: [Range<Int>] = []
    private var groundCascadeRanges: [[Range<Int>]] = []

    private func drawGround(_ ranges: [Range<Int>], indices: MTLBuffer, into encoder: MTL4RenderCommandEncoder) {
        for range in ranges {
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: range.count, indexType: .uint32,
                                          indexBuffer: indices.gpuAddress + UInt64(range.lowerBound * 4),
                                          indexBufferLength: (indices.length - range.lowerBound * 4))
        }
    }

    /// Called every simulation step with its length: a held brush works from here.
    public var onStep: ((Float) -> Void)?
    /// Once a frame, after its steps and before it is drawn.
    public var onFrame: (() -> Void)?


    /// Brings the next GPU copy of the ground up to date from ``terrainMirror`` — the whole of it after a new
    /// ground, otherwise only the patch the brush has touched since that copy was last drawn.
    private func rebuildTerrain() {
        guard let shape = terrainShape, !terrainMirror.isEmpty else { terrainDirty = false; return }
        let n = shape.resolution + 1
        if terrainResolution != shape.resolution || terrainVertices.isEmpty || terrainPending.isEmpty {
            engine.residencySet.removeAllocations(terrainVertices + (terrainIndices.map { [$0] } ?? [])
                                                  + (terrainCoarseIndices.map { [$0] } ?? []))
            terrainVertices = (0..<(FrameRenderer.maxFramesInFlight + 1)).compactMap { _ in
                terrainMirror.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            }
            let indexCount = shape.resolution * shape.resolution * 6
            terrainIndices = device.makeBuffer(length: indexCount * 4, options: .storageModeShared)
            if let indices = terrainIndices {
                let out = indices.contents().bindMemory(to: UInt32.self, capacity: indexCount)
                for z in 0..<shape.resolution { for x in 0..<shape.resolution { writeCell(x, z, resolution: shape.resolution, into: out) } }
            }
            terrainIndexCount = indexCount
            terrainResolution = shape.resolution
            terrainCoarseIndices = groundChunks?.coarseIndices().withUnsafeBytes {
                $0.isEmpty ? nil : device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            terrainCoarseIndices?.label = "Ground, coarser levels"
            terrainPending = Array(repeating: nil, count: terrainVertices.count)
            engine.residencySet.addAllocations(terrainVertices + (terrainIndices.map { [$0] } ?? [])
                                               + (terrainCoarseIndices.map { [$0] } ?? []))
            engine.commitResidency()
            terrainDirty = false
            return
        }
        terrainVertexIndex = (terrainVertexIndex + 1) % terrainVertices.count
        if let region = terrainPending[terrainVertexIndex] {
            let target = terrainVertices[terrainVertexIndex].contents().bindMemory(to: Float.self, capacity: n * n * 12)
            terrainMirror.withUnsafeBufferPointer { source in
                for z in region.z {
                    let start = (z * n + region.x.lowerBound) * 12
                    (target + start).update(from: source.baseAddress! + start, count: region.x.count * 12)
                }
            }
            terrainPending[terrainVertexIndex] = nil
        }
        // Done once every copy has caught up; until then each frame brings the next one up to date.
        terrainDirty = terrainPending.contains { $0 != nil }
    }

    // MARK: GameLoop

    public func beginFrame() {}
    public func step(deltaTime: Float) {
        onStep?(deltaTime)
        streamTime += deltaTime
        weatherTime += Double(deltaTime)
        // What rolls goes as far as the wind drives it, the way it blows.
        let blowing = SIMD2(frameWeather.wind.x, frameWeather.wind.z)
        if simd_length(blowing) > 0.1 { rollHeading = simd_normalize(blowing) }
        rollSpeed = Self.rollSpeed(windSpeed: frameWeather.settings.windSpeed)
        rollDistance += rollSpeed * deltaTime
        // Turning parts go round as fast as the wind drives them.
        turnAngle = (turnAngle + TurningPart.speed(windSpeed: frameWeather.settings.windSpeed) * deltaTime)
            .truncatingRemainder(dividingBy: 2 * .pi)
        // The weather wipes footprints as it goes: slowly when calm, fast in falling snow or rain.
        if !footprints.prints.isEmpty { footprints.advance(seconds: Double(deltaTime), weather: frameWeather) }
        // Wind effects blow the weather's way (``WorldScene/Effect/blown(by:)``), falling leaves follow the season
        // (``WorldScene/Effect/inSeason(_:phase:)``) and butterflies keep to fine days
        // (``WorldScene/Effect/living(in:sunElevation:yearPosition:)``).
        let fall = frameFall
        let daySky = frameDaySky, weather = frameWeather
        let year = scene.sky.clock.map { daySky.yearPosition + ($0.southern ? 2 : 0) }
        let elevation = daySky.lighting.elevation
        let shown = scene.effects.map { effect in
            let blown = effect.blown(by: weather).living(in: weather, sunElevation: elevation, yearPosition: year)
            return fall.map { blown.inSeason($0.fall, phase: $0.phase) } ?? blown
        }
        effects.wind = weather.wind
        effects.sync(shown, lighting: frameWeather.lighting(frameDaySky.lighting),
                     meshes: Set(scene.effectMeshes.filter { props[$0.value] != nil }.keys))
        guard drawsEffects else { return }
        effects.step(deltaTime: deltaTime)
    }

    // MARK: Effect meshes

    /// One copy of an effect mesh as `effectMeshVertex` reads it: where, and the colour that tints it.
    private struct EffectCopy { var transform: simd_float4x4; var tint: SIMD4<Float> }
    /// The copies a frame draws, a buffer per frame in flight.
    private static let effectCopyCapacity = 4096
    private lazy var effectCopyBuffer: MTLBuffer = {
        let buffer = device.makeBuffer(length: Self.effectCopyCapacity * FrameRenderer.maxFramesInFlight
                                       * MemoryLayout<EffectCopy>.stride, options: .storageModeShared)!
        buffer.label = "Effect Mesh Copies"
        engine.residencySet.addAllocation(buffer)
        engine.commitResidency()
        return buffer
    }()

    /// **The particles drawn as pack meshes**, solid among the scene: each mesh's copies instanced, lit as props are,
    /// tinted by their particle's colour.
    private func encodeEffectMeshes(into encoder: MTL4RenderCommandEncoder) {
        guard drawsEffects else { return }
        let copies = effects.meshCopies()
        guard !copies.isEmpty else { return }
        let base = (frameSlot % FrameRenderer.maxFramesInFlight) * Self.effectCopyCapacity
        let stride = MemoryLayout<EffectCopy>.stride
        var used = 0
        encoder.setRenderPipelineState(effectMeshPipeline)
        for (name, list) in copies.sorted(by: { $0.key < $1.key }) {
            guard let url = scene.effectMeshes[name], let prop = props[url], used + list.count <= Self.effectCopyCapacity else { continue }
            let pointer = effectCopyBuffer.contents().advanced(by: (base + used) * stride).bindMemory(to: EffectCopy.self,
                                                                                                     capacity: list.count)
            for (i, copy) in list.enumerated() { pointer[i] = EffectCopy(transform: copy.transform, tint: SIMD4(copy.tint, 1)) }
            argumentTable.setAddress(effectCopyBuffer.gpuAddress + UInt64((base + used) * stride), index: 3)
            used += list.count
            for shown in prop.meshes {
                for submesh in shown.loaded.mesh.submeshes.indices {
                    guard let uniforms = instancedUniforms(for: shown, submesh: submesh) else { break }
                    let indices = shown.indices(submesh: submesh, level: 0)
                    indices.bindVertices(of: shown.loaded.mesh, to: argumentTable)
                    argumentTable.setAddress(uniforms, index: 1)
                    argumentTable.setTexture(shown.baseMaps[submesh].gpuResourceID, index: 0)
                    argumentTable.setTexture(shown.glowMaps[submesh].gpuResourceID, index: 2)
                    bindGrunge(shown.grime(submesh))
                    encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: indices.count, indexType: indices.type,
                                                  indexBuffer: indices.address, indexBufferLength: indices.length,
                                                  instanceCount: list.count)
                    drawn.view += 1
                    drawn.viewTriangles += indices.count / 3 * list.count
                }
            }
        }
    }

    /// The scene's living effects — ``WorldEffectsPass``.
    private var effects: WorldEffectsPass!
    /// The scene's edge (``WorldScene/boundary``), drawn last.
    private var boundaryRenderer: BoundaryRenderer!
    /// **The way to a place** (``waymark``).
    private var waymarkRenderer: WaymarkRenderer!
    /// **The scene's weather**: ``WeatherRenderer`` draws its rain or snow, kept out from under roofs by ``WeatherCover`` —
    /// the scene's shadow casters seen from straight above.
    private var weatherRenderer: WeatherRenderer!
    private var weatherCover: WeatherCover!
    /// **Whether the rain, snow and lightning are shown.** Its clouds and fog are the scene's look, always shown; an editor
    /// may leave the falling weather out of a view it works in.
    public var showsWeather = true
    /// Seconds on the weather's clock — what lightning strikes by, and its thunder is heard by (``Soundscape``).
    public var weatherTime: Double = 0
    /// **The world's clock**, seconds since 1970: what the sky's hour and season and a weather schedule are read at. Nil
    /// is the real time (UTC) — players on one map share one sky with no server; a game with a server gives the server's.
    public var scheduleTime: Double?
    /// **The weather this frame draws**: the scene's, at the schedule's moment when it has one that is on. **Worked out
    /// once and kept for a twentieth of a second** (2026-11-15): it is asked about ten times a frame, and a schedule's
    /// moment includes how much snow it has laid — a marsh map fell to 2 frames a second when every ask worked that out
    /// afresh. A schedule changes over minutes, so a twentieth is never seen.
    public var frameWeather: Weather {
        let time = scheduleTime ?? Weather.realTime()
        let set = scene.weather
        if let kept = keptWeather, kept.scene == set, abs(kept.time - time) < 0.05 { return kept.weather }
        let weather = set.current(at: time)
        keptWeather = (set, time, weather)
        return weather
    }
    private var keptWeather: (scene: Weather, time: Double, weather: Weather)?
    /// **Whether the world's clock runs the hour**, as a game's does. Off, the hour is the one set, with the clock's
    /// latitude and place in the year — an editor looking at one hour of a day.
    public var previewsClock = true
    /// **The sky this frame**, on the world's clock when the scene has one (``WorldFile/Sky/daySky(at:running:)``).
    public var frameDaySky: DaySky { scene.sky.daySky(at: scheduleTime ?? Weather.realTime(), running: previewsClock) }
    /// The sky as this frame draws it: the scene's, under its weather, with lightning's flash in it.
    private var frameLighting = WorldFile.Sky().daySky.lighting
    /// Whether this frame drew what is overhead, for the rain to keep out from under.
    private var coverDrawn = false
    /// The cover as last drawn, and frames since: drawn again when it moves or ``coverRefresh`` frames have passed.
    private var coverDrawnMatrix: simd_float4x4?
    private var coverAge = 0
    /// Metres the cover's centre moves in, and frames between redraws for what changed in the scene.
    private static let coverStep: Float = 8
    private static let coverRefresh = 30
    /// **Lying snow this frame** (Ductane's `Weather.lyingSnow`, at the schedule's moment): how much, and how
    /// deep on the ground — none when the scene gives it no depth or the graphics settings turn depth off.
    public private(set) var snowLying: Float = 0
    /// **The clouds this frame** (Ductane's `CloudLayer`): the weather's, drifting by the weather's clock, and
    /// ``cloudPass``'s volumetric picture of them unless graphics quality asks for the flat layer.
    private var frameClouds: SkyPass.Clouds?
    private lazy var cloudPass: CloudPass? = {
        let pass = try? CloudPass(device: engine.device)
        if let pass { engine.residencySet.addAllocations(pass.allocations); engine.commitResidency() }
        return pass
    }()

    /// **How far the view's clouds are moved on from where the clock alone puts them**, metres, and the cloud speed it was
    /// worked out for. A cloud's place is speed × the clock's seconds since 1970, so a new Speed would put them
    /// somewhere else entirely — every step of the slider as it is dragged. When the speed changes
    /// the view keeps them where they were and lets them go on at the new speed. Only the view's: a game puts them where
    /// the clock says, which nobody compares with an editor's sky.
    private var cloudTravelOffset: Double = 0
    private var cloudTravelSpeed: Float?

    /// **The clouds at the view's moment**, kept in place through a change of speed (``cloudTravelOffset``).
    private func steadyClouds() -> CloudLayer {
        var layer = frameWeather.clouds(at: weatherTime)
        let speed = frameWeather.cloudShape.speed
        let period = CloudLayer.period
        if let was = cloudTravelSpeed, was != speed {
            cloudTravelOffset += Double(was - speed) * CloudLayer.speedAloft * weatherTime
            cloudTravelOffset -= (cloudTravelOffset / period).rounded(.down) * period
        }
        cloudTravelSpeed = speed
        let along = Double(layer.motion.z) + cloudTravelOffset
        layer.motion.z = Float(along - (along / period).rounded(.down) * period)
        return layer
    }

    /// **Raymarches the clouds** into their picture, before the scene pass that lays it over the sky.
    private func encodeClouds(into commandBuffer: MTL4CommandBuffer, lighting: DaySky.Lighting) {
        guard cloudsAsked != .none else { frameClouds = nil; return }
        let layer = steadyClouds()
        let quality = cloudsAsked.quality ?? graphics.clouds
        var picture: MTLTexture?
        if quality != .flat, let cloudPass {
            let size = engine.sceneSize
            picture = cloudPass.encode(into: commandBuffer, frameSlot: frameSlot, viewProjection: viewProjection,
                                       eye: camera.eye, lighting: lighting, layer: layer, quality: quality,
                                       width: max(size.width, 1), height: max(size.height, 1))
            if cloudPass.picturesChanged {
                cloudPass.picturesChanged = false
                engine.residencySet.addAllocations(cloudPass.allocations)
                engine.commitResidency()
            }
        }
        frameClouds = SkyPass.Clouds(layer: layer, picture: picture)
    }

    /// **Fall colors this frame** (Ductane's `FallColors`), from the clock's place in the year where the view is —
    /// nil with no clock, when foliage stays as drawn.
    private var frameFall: (fall: FallColors, phase: Float)?
    /// What the season does to each prop file, as last asked — cleared when the scene's foliage choices change.
    private var foliageKinds: [URL: Foliage] = [:]

    /// **What the season does to a prop, for its uniforms**: x 1 turns, 2 grass, 0 neither; y the year's phase; z 1 when
    /// trees stand bare in winter; w how far leaves turn. Zero with no clock.
    private func foliageVector(for prop: URL) -> SIMD4<Float> {
        // In high summer the season changes nothing: no tree's leaves have begun to turn and grass is green.
        guard let frameFall, FallColors.changesAnything(phase: frameFall.phase) else { return .zero }
        let kind: Foliage
        if let known = foliageKinds[prop] { kind = known } else {
            kind = scene.foliage(of: prop)
            foliageKinds[prop] = kind
        }
        let code: Float = switch kind {
        case .turns: 1
        case .grass: 2
        case .evergreen, .unchanged: 0
        }
        guard code > 0 else { return .zero }
        return SIMD4(code, frameFall.phase, frameFall.fall.bareInWinter ? 1 : 0, frameFall.fall.extent)
    }

    /// **Whether a turning tree may be missing leaves now** — late autumn to spring with bare trees, allowing for the
    /// earliest and latest trees: its solid canopy then casts through the mask, which drops what has fallen.
    // MARK: Lightning

    /// **Where a strike lands**: on the ground under it, or for a close one on the top of the tallest thing within 12 m —
    /// a tree, a mast, a roof — as lightning finds the highest point.
    private func strikeLanding(_ strike: Weather.Strike) -> SIMD3<Float> {
        let p = strike.position
        let ground = groundHeight(x: p.x, z: p.y) ?? 0
        guard strike.isClose else { return SIMD3(p.x, ground, p.y) }
        var best = SIMD3(p.x, ground, p.y)
        for gathered in [placedCopies, scatteredCopies].compactMap({ $0 }) {
            for copy in gathered.copies where copy.maximum.y > best.y {
                let centre = SIMD2((copy.minimum.x + copy.maximum.x) / 2, (copy.minimum.z + copy.maximum.z) / 2)
                if simd_distance(centre, p) < 12 { best = SIMD3(centre.x, copy.maximum.y, centre.y) }
            }
        }
        return best
    }

    // MARK: Snow caps

    /// **How deep snow builds up on props** at the most, metres — a hand's breadth less than on the ground.
    static let snowCapDepth: Float = 0.2
    /// Whether this frame draws snow caps: snow lies, and the viewport's graphics allow depth.
    private var capsShown: Bool { snowLying > 0.01 && graphics.snowDepth && drawsSnowCaps }
    /// Whether snow builds up on props — off to measure what it costs.
    public var drawsSnowCaps = true
    /// Each prop's cap, made the first time snow needs it; nil for a prop with nothing facing up.
    private var snowCaps: [URL: SnowCapMesh?] = [:]
    private struct SnowCapMesh { let vertices: MTLBuffer; let indexBuffer: MTLBuffer; let indices: IndexRange }

    /// **A prop's snow cap** (Ductane's `SnowCap.make`), from its solid surfaces — cut-out leaves and grass hold the
    /// white layer, not a slab — made once and kept.
    private func snowCap(for url: URL, meshes: [ShownMesh]) -> SnowCapMesh? {
        if let known = snowCaps[url] { return known }
        var triangles: [SIMD3<Float>] = []
        for shown in meshes {
            let mesh = shown.loaded.mesh
            guard let vertices = mesh.vertexBuffers.first, vertices.buffer.storageMode != .private else { continue }
            let base = vertices.buffer.contents() + vertices.offset
            for (index, submesh) in mesh.submeshes.enumerated()
            where submesh.primitiveType == .triangle && (index >= shown.cutoffs.count || shown.cutoffs[index] == 0)
                && !(index < shown.seeThrough.count && shown.seeThrough[index]) {
                let indices = submesh.indexBuffer
                guard indices.buffer.storageMode != .private else { continue }
                TriangleReader.append(vertices: base, stride: 32, indices: indices.buffer.contents() + indices.offset,
                                        count: submesh.indexCount, wide: submesh.indexType == .uint32,
                                        node: shown.loaded.nodeTransform, to: &triangles)
            }
        }
        let cap = SnowCap.make(triangles)
        guard !cap.indices.isEmpty,
              let vertexBuffer = engine.device.makeBuffer(length: cap.vertices.count * 32, options: .storageModeShared),
              let indexBuffer = engine.device.makeBuffer(bytes: cap.indices, length: cap.indices.count * 4,
                                                         options: .storageModeShared) else {
            snowCaps[url] = .some(nil)
            return nil
        }
        let out = vertexBuffer.contents().bindMemory(to: Float.self, capacity: cap.vertices.count * 8)
        for (i, v) in cap.vertices.enumerated() {
            let values = [v.position.x, v.position.y, v.position.z, v.normal.x, v.normal.y, v.normal.z, v.lift, v.push]
            for k in 0..<8 { out[i * 8 + k] = values[k] }
        }
        vertexBuffer.label = "Snow Cap"
        indexBuffer.label = "Snow Cap"
        engine.residencySet.addAllocations([vertexBuffer, indexBuffer])
        engine.commitResidency()
        let mesh = SnowCapMesh(vertices: vertexBuffer, indexBuffer: indexBuffer,
                               indices: IndexRange(buffer: indexBuffer, offset: 0, count: cap.indices.count,
                                                   vertices: vertexBuffer.gpuAddress))
        snowCaps[url] = mesh
        return mesh
    }

    /// **The wind this frame** (Ductane's `Weather.foliageWind`), for what moves in it.
    private var frameWind: SIMD4<Float> = .zero
    /// How each prop file moves in the wind, as last asked — cleared when the scene's choices change.
    private var swayKinds: [URL: Sway] = [:]

    /// How a prop file moves in the wind, as the scene says.
    private func swayKind(of prop: URL) -> Sway {
        if let known = swayKinds[prop] { return known }
        let kind = scene.sway(of: prop)
        swayKinds[prop] = kind
        return kind
    }

    // MARK: Turning parts

    /// **A prop's turning part, ready to draw** (``TurningPart``): per mesh and submesh, the triangles that stay and those
    /// that turn, each with indices of its own into the mesh's vertices — nil where there are none.
    final class TurningDraw {
        let part: TurningPart
        let still: [[IndexRange?]]
        let turning: [[IndexRange?]]
        let buffers: [MTLBuffer]
        init(part: TurningPart, still: [[IndexRange?]], turning: [[IndexRange?]], buffers: [MTLBuffer]) {
            self.part = part
            self.still = still
            self.turning = turning
            self.buffers = buffers
        }
    }
    /// Per prop file set to turn: what turns, or nil when nothing in it was found to (asked once, until the scene's wind
    /// choices change or the prop is read again).
    private var turningDraws: [URL: TurningDraw?] = [:]
    /// **How far every turning part has gone round**, radians — stepped by the wind's speed each frame, never worked out
    /// from a clock, so a wind that changes speeds them up or slows them rather than throwing them round at once.
    private var turnAngle: Float = 0

    /// **A prop's turning part, if it is set to turn and one is found** — read from its meshes the first time it is asked
    /// for, in the prop's own space.
    private func turningDraw(for url: URL, prop: PropMeshes) -> TurningDraw? {
        guard swayKind(of: url) == .turns else { return nil }
        if let known = turningDraws[url] { return known }
        var meshes: [(positions: [SIMD3<Float>], submeshes: [[UInt32]])] = []
        for shown in prop.meshes {
            let mesh = shown.loaded.mesh
            guard let vertexBuffer = mesh.vertexBuffers.first, vertexBuffer.buffer.storageMode != .private else {
                turningDraws[url] = .some(nil)
                return nil
            }
            let base = vertexBuffer.buffer.contents() + vertexBuffer.offset
            let node = shown.loaded.nodeTransform
            let vertexCount = min(mesh.vertexCount, (vertexBuffer.buffer.length - vertexBuffer.offset) / 32)
            let positions = (0..<vertexCount).map { i -> SIMD3<Float> in
                let p = base.advanced(by: i * 32).loadUnaligned(as: SIMD3<Float>.self)
                let q = node * SIMD4(p, 1)
                return SIMD3(q.x, q.y, q.z)
            }
            var submeshes: [[UInt32]] = []
            for submesh in mesh.submeshes {
                let indices = submesh.indexBuffer
                guard indices.buffer.storageMode != .private else { turningDraws[url] = .some(nil); return nil }
                let start = indices.buffer.contents() + indices.offset
                submeshes.append(submesh.indexType == .uint32
                    ? (0..<submesh.indexCount).map { start.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self) }
                    : (0..<submesh.indexCount).map { UInt32(start.advanced(by: $0 * 2).loadUnaligned(as: UInt16.self)) })
            }
            meshes.append((positions, submeshes))
        }
        guard let part = TurningPart.find(meshes: meshes) else {
            NSLog("WorldRenderer: nothing found to turn in \(url.lastPathComponent)")
            turningDraws[url] = .some(nil)
            return nil
        }
        let total = meshes.reduce(0) { $0 + $1.submeshes.reduce(0) { $0 + $1.count / 3 } }
        NSLog("WorldRenderer: %@ turns %d of its %d triangles about (%.2f, %.2f, %.2f), axis (%.2f, %.2f, %.2f)",
              url.lastPathComponent, part.count, total, part.hub.x, part.hub.y, part.hub.z, part.axis.x, part.axis.y, part.axis.z)
        var still: [[IndexRange?]] = [], turning: [[IndexRange?]] = [], buffers: [MTLBuffer] = []
        func range(_ indices: [UInt32]) -> IndexRange? {
            guard !indices.isEmpty,
                  let buffer = engine.device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            else { return nil }
            buffer.label = "Turning Part"
            buffers.append(buffer)
            return IndexRange(buffer: buffer, count: indices.count)
        }
        for (m, mesh) in meshes.enumerated() {
            var meshStill: [IndexRange?] = [], meshTurning: [IndexRange?] = []
            for (s, indices) in mesh.submeshes.enumerated() {
                let flags = part.turns[m][s]
                if !flags.contains(true) {
                    meshStill.append(IndexRange(prop.meshes[m].loaded.mesh.submeshes[s]))
                    meshTurning.append(nil)
                    continue
                }
                var stays: [UInt32] = [], goes: [UInt32] = []
                for (t, turns) in flags.enumerated() {
                    if turns { goes += indices[(t * 3)..<(t * 3 + 3)] } else { stays += indices[(t * 3)..<(t * 3 + 3)] }
                }
                meshStill.append(range(stays))
                meshTurning.append(range(goes))
            }
            still.append(meshStill)
            turning.append(meshTurning)
        }
        if !buffers.isEmpty {
            engine.residencySet.addAllocations(buffers)
            engine.commitResidency()
        }
        let draw = TurningDraw(part: part, still: still, turning: turning, buffers: buffers)
        turningDraws[url] = draw
        return draw
    }

    /// Forgets what turns in these props, or in all — retiring what it held on the GPU.
    private func forgetTurning(_ urls: Set<URL>? = nil) {
        var dropped: [any MTLAllocation] = []
        for (url, draw) in turningDraws where urls?.contains(url) ?? true {
            if let draw { dropped += draw.buffers }
        }
        if let urls { for url in urls { turningDraws[url] = nil } } else { turningDraws = [:] }
        retire(dropped)
    }

    /// **How a prop moves in the wind, for its uniforms**: x 1 a tree, 2 a plant, 3 cloth, 0 still; y its height and z half
    /// its width, in its own space — what `swayed` bends it by.
    private func swayVector(for prop: URL, bounds: BoundingBox) -> SIMD4<Float> {
        let kind = swayKind(of: prop)
        let code: Float = switch kind {
        case .tree: 1
        case .plant: 2
        case .cloth: 3
        // Turning is a part going round its hub (``TurningPart``), rolling a whole copy going over (``rolling``) — not bends.
        case .still, .turns, .rolls: 0
        }
        guard code > 0 else { return .zero }
        let size = bounds.maximum - bounds.minimum
        return SIMD4(code, max(bounds.maximum.y, 0.1), max(size.x, size.z) / 2, 0)
    }

    /// How one material of a prop file moves when not as its prop, as last asked — cleared when the scene's choices change.
    private var materialSwayKinds: [MaterialSwayKey: Sway?] = [:]
    private struct MaterialSwayKey: Hashable { let prop: URL; let material: String }
    /// Each submesh's height in its prop — bottom and top — for cloth fastened to the rest (``swayVector(for:bounds:shown:submesh:)``).
    private var submeshSpans: [SubmeshKey: ClosedRange<Float>?] = [:]
    private struct SubmeshKey: Hashable { let mesh: ObjectIdentifier; let submesh: Int }

    /// **How one submesh moves in the wind**: as its prop (``swayVector(for:bounds:)``) unless its material is set apart —
    /// cloth fastened to the rest of the prop (4: y its hem's height, z its own), or still — by its own material's name,
    /// whatever it wears.
    private func swayVector(for prop: URL, bounds: BoundingBox, shown: ShownMesh, submesh: Int) -> SIMD4<Float> {
        let base = swayVector(for: prop, bounds: bounds)
        let name = Self.materialName(shown.loaded.material(forSubmesh: submesh))
        let key = MaterialSwayKey(prop: prop, material: name)
        let part: Sway?
        if let known = materialSwayKinds[key] { part = known } else {
            part = scene.sway(of: prop, material: name)
            materialSwayKinds[key] = .some(part)
        }
        guard let part else { return base }
        switch part {
        case .cloth:
            guard let span = submeshSpan(shown, submesh) else { return base }
            return SIMD4(4, span.lowerBound, max(span.upperBound - span.lowerBound, 0.05), 0)
        case .tree, .plant:
            let size = bounds.maximum - bounds.minimum
            return SIMD4(part == .tree ? 1 : 2, max(bounds.maximum.y, 0.1), max(size.x, size.z) / 2, 0)
        case .still, .turns, .rolls:
            return .zero
        }
    }

    /// A submesh's lowest and highest point in its prop's space, read once from its vertices.
    private func submeshSpan(_ shown: ShownMesh, _ submesh: Int) -> ClosedRange<Float>? {
        let key = SubmeshKey(mesh: ObjectIdentifier(shown.loaded.mesh), submesh: submesh)
        if let known = submeshSpans[key] { return known }
        var span: ClosedRange<Float>?
        let mesh = shown.loaded.mesh
        if let vertices = mesh.vertexBuffers.first, vertices.buffer.storageMode != .private,
           mesh.submeshes.indices.contains(submesh), mesh.submeshes[submesh].indexBuffer.buffer.storageMode != .private {
            let base = vertices.buffer.contents() + vertices.offset
            let part = mesh.submeshes[submesh]
            let start = part.indexBuffer.buffer.contents() + part.indexBuffer.offset
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            let vertexCount = min(mesh.vertexCount, (vertices.buffer.length - vertices.offset) / 32)
            for i in 0..<part.indexCount {
                let index = part.indexType == .uint32 ? Int(start.advanced(by: i * 4).loadUnaligned(as: UInt32.self))
                    : Int(start.advanced(by: i * 2).loadUnaligned(as: UInt16.self))
                // An index past the mesh's vertices is a damaged file's, and left out.
                guard index < vertexCount else { continue }
                let p = base.advanced(by: index * 32).loadUnaligned(as: SIMD3<Float>.self)
                let y = (shown.loaded.nodeTransform * SIMD4(p, 1)).y
                low = min(low, y); high = max(high, y)
            }
            if low <= high { span = low...high }
        }
        submeshSpans[key] = .some(span)
        return span
    }

    /// **Whether every turning tree is bare** — the middle of winter with bare trees, allowing for the earliest and latest:
    /// their leaf submeshes are then not drawn at all, rather than drawn to be dropped.
    static func isBare(_ foliage: SIMD4<Float>) -> Bool {
        foliage.x == 1 && foliage.z > 0.5 && foliage.y >= 1.75 + FallColors.timingSpread / 2
            && foliage.y <= 2.6 - FallColors.timingSpread / 2
    }

    /// **Whether a material is a tree's leaves alone** — named so: an import that splits a tree's leaves from its bark calls
    /// them "… Leaf", and packs name theirs leaves or foliage.
    static func isLeafMaterial(_ name: String) -> Bool {
        if let known = leafMaterials[name] { return known }
        let words = Set(Foliage.words(name))
        let leaf = !words.isDisjoint(with: ["leaf", "leaves", "foliage", "canopy"])
        leafMaterials[name] = leaf
        return leaf
    }
    private static var leafMaterials: [String: Bool] = [:]

    static func isThinning(_ foliage: SIMD4<Float>) -> Bool {
        foliage.x == 1 && foliage.z > 0.5 && foliage.y > 1.15 - FallColors.timingSpread / 2
            && foliage.y < 3.0 + FallColors.timingSpread / 2
    }

    /// **Where fallen leaves lie**, a float a ground point: 1 under the middle of a turning tree, fading to its canopy's
    /// edge and a little past (``refreshLitterField()``). Made only once leaves lie, again when trees or the ground change.
    private var litterFieldBuffer: MTLBuffer?
    private var litterStale = true
    private var litterShape: TerrainShape?

    /// **Works out where fallen leaves lie** — under every placed and scattered copy of a prop that turns, out to its box's
    /// half-width and a little more, as leaves drift — when leaves lie at all and something it depends on has changed.
    private func refreshLitterField() {
        guard let frameFall, frameFall.fall.litter(phase: frameFall.phase) > 0, let shape = terrainShape else { return }
        guard litterStale || litterShape != shape || litterFieldBuffer == nil else { return }
        // The placed copies, gathered now if they are being gathered again — the frame would a moment later.
        if placedCopies == nil, !scene.placements.isEmpty { _ = gatherPlacedCopies() }
        litterStale = false
        litterShape = shape
        let n = shape.resolution + 1
        if litterFieldBuffer == nil || litterFieldBuffer!.length < n * n * 4 {
            if let old = litterFieldBuffer { engine.residencySet.removeAllocation(old) }
            litterFieldBuffer = engine.device.makeBuffer(length: n * n * 4, options: .storageModeShared)
            litterFieldBuffer?.label = "Litter Field"
            if let litterFieldBuffer { engine.residencySet.addAllocation(litterFieldBuffer); engine.commitResidency() }
        }
        guard let litterFieldBuffer else { return }
        let field = litterFieldBuffer.contents().bindMemory(to: Float.self, capacity: n * n)
        field.update(repeating: 0, count: n * n)
        let spacing = shape.size / Float(shape.resolution), half = shape.size / 2
        for gathered in [placedCopies, scatteredCopies].compactMap({ $0 }) {
            let turns = gathered.urls.map { foliageVector(for: $0).x == 1 }
            for copy in gathered.copies where turns.indices.contains(copy.prop) && turns[copy.prop] {
                let centre = (copy.minimum + copy.maximum) / 2
                let r = max(copy.maximum.x - copy.minimum.x, copy.maximum.z - copy.minimum.z) * 0.6
                guard r > 0.3 else { continue }
                func cell(_ v: Float) -> Int { min(max(Int(((v + half) / spacing).rounded(.down)), 0), n - 1) }
                let x0 = cell(centre.x - r), x1 = cell(centre.x + r), z0 = cell(centre.z - r), z1 = cell(centre.z + r)
                guard x0 < x1 || z0 < z1 else { continue }
                for j in z0...z1 {
                    let dz = Float(j) * spacing - half - centre.z
                    for i in x0...x1 {
                        let dx = Float(i) * spacing - half - centre.x
                        let d2 = (dx * dx + dz * dz) / (r * r)
                        guard d2 < 1 else { continue }
                        field[j * n + i] = max(field[j * n + i], 1 - d2)
                    }
                }
            }
        }
    }

    /// **Wet ground this frame**: surfaces' wetness, the puddles' fill, and how hard it rains now.
    private var frameWet: (surface: Float, puddles: Float, rain: Float) = (0, 0, 0)
    /// **Where puddles gather**, a float a ground point (`WorldPuddleField`), worked out where the ground changes.
    private var puddleFieldBuffer: MTLBuffer?
    public private(set) var snowDepthShown: Float = 0
    /// **Where feet have pressed** (``FootprintTrail``): a game's characters' steps, wiped by the weather, handed to the
    /// shaders round the eye through ``footprintGrid`` each frame there are any.
    public var footprints = FootprintTrail()
    private var footprintGrid: FootprintGrid!
    private var footprintsDrawn = false
    /// The ground's chunks under the cover, this frame.
    private var groundCoverRanges: [Range<Int>] = []
    /// **All of the world's edge**, whatever its look — a boundary that shows only near a player, or never, would be
    /// nowhere to be seen while an editor sets it.
    public var showsWholeBoundary = false
    /// **Whether the world's edge is drawn** at all while nobody is near it to see it (``boundaryPlayer``).
    public var drawsBoundary = true
    /// **Where the player is**, for the edge to show round as it nears it; nil is where the view looks.
    public var boundaryPlayer: SIMD3<Float>?
    private let boundaryClock = ContinuousClock.now
    /// **How bright the edge's glow is in the scene's light**: by eye in daylight, where lit surfaces are around one; a
    /// game picks its own for its own exposure.
    public var boundaryBrightness: Float = 2.5

    /// **The way to a place, shown now** (``Waymark``) — a game makes one when it wants the way shown and steps it; drawn
    /// over the scene until it is over.
    public var waymark: Waymark?

    // MARK: The scan

    /// **A scan sent out now** (``WaymarkScan``) — ``sendScan(from:look:)`` sends one, ``stepScan(deltaTime:)`` steps it;
    /// drawn over the scene until it is over.
    public private(set) var scan: WaymarkScan?
    /// **A game's things a scan can find** (``Findables``): its loot, its enemies, other players — added, moved and
    /// removed as they come and go. What the world tags (``WorldScene/found``, its markers of a kind the look finds) is
    /// found as well, without being registered.
    public var findables = Findables()
    /// **Where distances are measured from** — the player; nil is where the view is.
    public var scanViewer: SIMD3<Float>?
    /// What the world itself tags, gathered when a scan is sent.
    private var scanSceneFindables: [Findable] = []
    /// The found things as they show this frame, worked out once in the pre-passes and drawn in the scene.
    private var scanShown: [WaymarkScan.Shown] = []
    private var scanMask: MTLTexture?
    private var scanRenderer: WaymarkScanRenderer!

    /// **Sends a scan out from `origin`**, in `look` — the world's (``WorldFile/waymark``) unless a game has its own. One
    /// already out is replaced. Nothing is sent when the look's scan is off.
    public func sendScan(from origin: SIMD3<Float>, look: Waymark.Look) {
        guard look.scan.isOn else { scan = nil; return }
        scan = WaymarkScan(from: origin, look: look)
        scanSceneFindables = sceneFindables(look: look)
    }

    /// Steps the scan on, finding what its ring reaches; drops it once it is over.
    public func stepScan(deltaTime: Float) {
        guard var current = scan else { return }
        current.step(deltaTime: deltaTime, findables: allFindables)
        scan = current.isOver ? nil : current
    }

    /// Ends the scan at once.
    public func endScan() { scan = nil; scanShown = [] }

    private var allFindables: [Findable] { scanSceneFindables + findables.all }

    /// **What the world tags to be found**: every placement and scattered copy of a prop in ``WorldScene/found``, outlined
    /// as that prop, and its markers of every kind the look finds. Negative ids, never a game's.
    public func sceneFindables(look: Waymark.Look) -> [Findable] {
        var out: [Findable] = []
        for (i, marker) in scene.markers.enumerated() where look.kind(marker.kind).markers {
            out.append(Findable(id: Findable.ID(-1 - i), kind: marker.kind, position: marker.position, top: 1.5))
        }
        guard !scene.found.isEmpty else { return out }
        var next = -1_000_000
        func add(_ url: URL, _ kind: String, _ transform: simd_float4x4) {
            out.append(Findable(id: Findable.ID(next), kind: kind, position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                                top: Findables.top(of: props[url]?.bounds, transform: transform),
                                outline: .prop(url, transform)))
            next -= 1
        }
        for placement in scene.placements {
            if let kind = scene.found[placement.prop] { add(placement.prop, kind, placement.transform) }
        }
        for scatter in scene.scatters {
            for copy in scatter.copies where scatter.prototypes.indices.contains(copy.prototype) {
                let url = scatter.prototypes[copy.prototype]
                if let kind = scene.found[url] { add(url, kind, copy.transform) }
            }
        }
        return out
    }

    /// The scan's mask made resident when the view's size makes one, and let go when it is retired.
    private func watchScanMasks() {
        scanRenderer.allocationsChanged = { [unowned self] added, removed in
            if !added.isEmpty { engine.residencySet.addAllocations(added) }
            for old in removed { engine.residencySet.removeAllocation(old) }
            engine.commitResidency()
        }
    }

    /// **The height a scan's ring runs over** at a point: the ground, or still water over it.
    private func scanSurface(_ p: SIMD2<Float>) -> Float {
        var height = groundHeight(x: p.x, z: p.y) ?? scan?.origin.y ?? 0
        for water in scene.waters where water.level > height {
            if water.rectangles.contains(where: { $0.count == 4 && p.x >= $0[0] && p.y >= $0[1] && p.x <= $0[2] && p.y <= $0[3] }) {
                height = water.level
            }
        }
        return height
    }

    /// **The scan's outlines, into their mask** — every shown thing with an outline, at full detail, whatever stands
    /// in front of it.
    private func encodeScanMask(into commandBuffer: MTL4CommandBuffer, viewProjection: simd_float4x4) {
        scanMask = nil
        guard let scan else { scanShown = []; return }
        scanShown = scan.shown(allFindables, from: scanViewer ?? camera.eye)
        var parts: [WaymarkScanRenderer.MaskPart] = []
        for item in scanShown where item.outline > 0 {
            switch item.findable.outline {
            case .none:
                continue
            case .meshes(let draws):
                parts += draws.map { WaymarkScanRenderer.MaskPart(draw: $0, opacity: item.outline) }
            case .prop(let url, let transform):
                guard let prop = props[url] else { continue }
                for shown in prop.meshes(at: 0).meshes {
                    guard let vertices = shown.loaded.mesh.vertexBuffers.first else { continue }
                    let model = transform * shown.loaded.nodeTransform
                    for submesh in shown.loaded.mesh.submeshes.indices where !shown.seeThrough[submesh] {
                        let range = shown.indices(submesh: submesh, level: 0)
                        parts.append(WaymarkScanRenderer.MaskPart(
                            draw: Findable.MaskDraw(vertices: vertices.buffer.gpuAddress + UInt64(vertices.offset),
                                                    stride: 32, indices: range.address, indexCount: range.count,
                                                    indexType: range.type, transform: model),
                            opacity: item.outline))
                    }
                }
            }
        }
        let size = engine.sceneSize
        if scanRenderer.allocationsChanged == nil { watchScanMasks() }
        scanMask = scanRenderer.encodeMask(parts, viewProjection: viewProjection, width: size.width, height: size.height,
                                           frameSlot: frameSlot, into: commandBuffer)
    }

    public func viewportSizeChanged(width: Int, height: Int) {
        aspectRatio = Float(max(width, 1)) / Float(max(height, 1))
        viewportHeight = max(height, 1)
        viewportWidth = max(width, 1)
    }

    /// Frames drawn so far.
    public private(set) var framesEncoded = 0

    /// **What the last frame drew** — counted as each draw is encoded, so the frame's own numbers rather than an
    /// estimate of them.
    public struct DrawCounts: Equatable, Sendable {
        /// Draw calls and triangles into the view: the ground's chunks and every prop's submeshes, copies included.
        public var view = 0, viewTriangles = 0
        /// The same into the sun's shadow cascades, all of them together; 0 while the sun casts nothing.
        public var shadows = 0, shadowTriangles = 0
        public init() {}
    }
    public private(set) var drawn = DrawCounts()
    /// The frames' times since the statistics last took them (``takeFrameAverage()``).
    private var frameAverage = FrameTimesAverage()

    /// The average frame since the last call, and the slowest; starts a new stretch.
    public func takeFrameAverage() -> (mean: FrameTimes, slowest: Double)? {
        defer { frameAverage.reset() }
        return frameAverage.mean.map { ($0, frameAverage.slowest) }
    }

    /// **What the GPU holds for the scene**, in bytes: its textures, and its meshes — every loaded prop's buffers at
    /// every level of detail, and the ground's.
    public func graphicsMemory() -> (textures: Int, textureCount: Int, meshes: Int, propCount: Int) {
        let maps = textures.allocations
        let meshes = props.values.flatMap(Self.allocations(of:)) + terrainVertices + (terrainIndices.map { [$0] } ?? [])
            + (terrainCoarseIndices.map { [$0] } ?? [])
        return (MemoryUse.bytes(of: maps), maps.count, MemoryUse.bytes(of: meshes), props.count)
    }

    /// The view's projection times its view matrix, at the view's shape.
    public var viewProjection: simd_float4x4 {
        camera.projectionMatrix(aspectRatio: aspectRatio) * camera.viewMatrix
    }

    public func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
        framesEncoded += 1
        frameAverage.add(engine.lastFrameTimes)
        drawn.view = 0
        drawn.viewTriangles = 0
        // **Wait for the far pictures' mipmaps**, made by a blit this frame: the engine's barrier at the start of the pass
        // waits for the pre-passes' fragments, not for blits.
        if bakedImpostorsThisFrame {
            encoder.barrier(afterQueueStages: .blit, beforeStages: .fragment, visibilityOptions: .device)
        }
        // **Wait for the fog's compute pass**, which wrote the volume this frame.
        if frameFogVolume != nil {
            encoder.barrier(afterQueueStages: .dispatch, beforeStages: .fragment, visibilityOptions: .device)
        }
        // Sky first, covering everything; it writes no depth, and sets its own state — so before ours.
        // With the night's stars and moon, and the clouds — volumetric from ``encodeClouds``, or a flat layer.
        skyPass.encode(into: encoder, frameSlot: frameSlot, viewProjection: viewProjection, eye: camera.eye,
                       lighting: frameLighting, night: frameDaySky.night, clouds: frameClouds,
                       time: Float(weatherTime.truncatingRemainder(dividingBy: 3600)),
                       rainbow: frameWeather.rainbow(sunElevation: frameDaySky.sunPosition.elevation))
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameSlot * Self.frameStride), index: 2)
        // The sun's shadows, recorded in `encodePrePasses`; the white texture's slot stands in when there are none.
        if let shadowMap { argumentTable.setTexture(shadowMap.texture.gpuResourceID, index: 1) }
        // What is overhead, for lying snow (`snowOn`); read only when the frame says it was drawn.
        if let weatherCover { argumentTable.setTexture(weatherCover.texture.gpuResourceID, index: 7) }
        // Where clouds gather (Ductane's `CloudLayer.coverageMap`), for their shadows; read only with clouds.
        if let cloudPass { argumentTable.setTexture(cloudPass.coverageMap.gpuResourceID, index: 8) }
        // The fog volume (`encodeFog`), or a blank one the frame says not to read.
        argumentTable.setTexture((frameFogVolume ?? blankVolume).gpuResourceID, index: 9)
        // The footprints near the eye and the cells that list them (`FootprintGrid`); the frame's buffer stands in until
        // there are any — the frame says whether to look.
        argumentTable.setAddress(footprintGrid.map { $0.printsAddress(frameSlot: frameSlot) } ?? frameBuffer.gpuAddress, index: 6)
        argumentTable.setAddress(footprintGrid.map { $0.cellsAddress(frameSlot: frameSlot) } ?? frameBuffer.gpuAddress, index: 7)
        // Where puddles gather on the ground (`WorldPuddleField`); the frame's buffer stands in with no ground.
        argumentTable.setAddress(puddleFieldBuffer?.gpuAddress ?? frameBuffer.gpuAddress, index: 8)
        // Where fallen leaves lie, under turning trees (``refreshLitterField()``); the frame's buffer stands in.
        argumentTable.setAddress(litterFieldBuffer?.gpuAddress ?? frameBuffer.gpuAddress, index: 9)
        // The ground's heights, for what is under it; the frame's own buffer stands in when there is no ground.
        argumentTable.setAddress(terrainVertices.isEmpty ? frameBuffer.gpuAddress : terrainVertices[terrainVertexIndex].gpuAddress,
                                 index: 4)

        encoder.setDepthStencilState(depthState)
        // The grid is the ground until there is ground; drawn under it as well, they fight for the pixels.
        if terrainShape == nil, showsGrid {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // **USD winds a front face counter-clockwise; Metal assumes clockwise.** Left at Metal's default,
        // every face is its own back, the shader flips each normal for the far side, and a crate's top is
        // lit as if it faced the ground.
        encoder.setFrontFacing(.counterClockwise)
        if let ground = preparedGround, let indices = terrainIndices, !terrainVertices.isEmpty {
            if let layers = preparedGroundLayers, let textures = groundTextures, let weights = groundWeightBuffer {
                encoder.setRenderPipelineState(texturedGroundPipeline)
                argumentTable.setAddress(layers, index: 10)
                argumentTable.setAddress(weights.gpuAddress, index: 11)
                argumentTable.setTexture(textures.albedo.gpuResourceID, index: 10)
                argumentTable.setTexture(textures.surface.gpuResourceID, index: 11)
            } else {
                encoder.setRenderPipelineState(groundPipeline)
            }
            argumentTable.setAddress(terrainVertices[terrainVertexIndex].gpuAddress, index: 0)
            argumentTable.setAddress(ground, index: 1)
            argumentTable.setTexture(textures.white.gpuResourceID, index: 0)
            bindGrunge(nil)
            argumentTable.setTexture(textures.white.gpuResourceID, index: 2)
            drawGround(groundRanges, indices: indices, into: encoder)
            drawn.view += groundRanges.count
            drawn.viewTriangles += groundRanges.reduce(0) { $0 + $1.count } / 3
            // The far chunks at their coarser levels, their colour, normal and height read from the full ground.
            if let coarse = preparedCoarseGround, let coarseIndices = terrainCoarseIndices, !groundCoarseRanges.isEmpty {
                argumentTable.setAddress(coarse, index: 1)
                drawGround(groundCoarseRanges, indices: coarseIndices, into: encoder)
                drawn.view += groundCoarseRanges.count
                drawn.viewTriangles += groundCoarseRanges.reduce(0) { $0 + $1.count } / 3
            }
        }
        var pipeline: MTLRenderPipelineState?
        for draw in prepared {
            let wanted = draw.snowCap ? snowCapPipeline : draw.instances == nil ? propPipeline : instancedPipeline
            if pipeline !== wanted { encoder.setRenderPipelineState(wanted); pipeline = wanted }
            draw.indices.bindVertices(of: draw.mesh, to: argumentTable)
            argumentTable.setAddress(draw.uniforms, index: 1)
            argumentTable.setTexture(draw.baseMap.gpuResourceID, index: 0)
            argumentTable.setTexture(draw.glowMap.gpuResourceID, index: 2)
            bindGrunge(draw.grime)
            let indices = draw.indices
            if let instances = draw.instances {
                argumentTable.setAddress(instances.address, index: 3)
            }
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: indices.count, indexType: indices.type,
                                          indexBuffer: indices.address, indexBufferLength: indices.length,
                                          instanceCount: draw.instances?.count ?? 1)
            drawn.view += 1
            drawn.viewTriangles += indices.count / 3 * (draw.instances?.count ?? 1)
        }
        // **The far copies as their pictures**: a square each, facing the eye, lit as the mesh is.
        if !preparedImpostors.isEmpty {
            encoder.setRenderPipelineState(impostorPipeline)
            for draw in preparedImpostors {
                argumentTable.setAddress(draw.uniforms, index: 1)
                argumentTable.setAddress(draw.instances.address, index: 3)
                argumentTable.setTexture(draw.impostor.albedo.gpuResourceID, index: 3)
                argumentTable.setTexture(draw.impostor.normals.gpuResourceID, index: 4)
                argumentTable.setTexture(draw.impostor.depth.gpuResourceID, index: 5)
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: draw.instances.count)
                drawn.view += 1
                drawn.viewTriangles += 2 * draw.instances.count
            }
        }
        encodeEffectMeshes(into: encoder)
        // **The fog over the sky**, where nothing solid was drawn.
        if frameFog != nil {
            fogSkyPass.encode(into: encoder, fog: frameFog)
            encoder.setDepthStencilState(depthState)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        }
        // With a liquid or a soft particle in view, what is drawn over the solid scene waits for the second pass, which
        // can read its depth.
        if !wantsOpaqueTextures { encodeOverSolid(into: encoder, solidDepth: nil) }
    }

    /// **The second pass, over the solid scene**, when a liquid is in view (``wantsOpaqueTextures``): the same state
    /// bound again on its new encoder, and everything see-through drawn, the liquids reading the solid pass's depth.
    public func encodeTransparent(into encoder: MTL4RenderCommandEncoder, opaque: OpaqueTextures, frameSlot: Int,
                           interpolation: Float) {
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameSlot * Self.frameStride), index: 2)
        if let shadowMap { argumentTable.setTexture(shadowMap.texture.gpuResourceID, index: 1) }
        argumentTable.setAddress(terrainVertices.isEmpty ? frameBuffer.gpuAddress : terrainVertices[terrainVertexIndex].gpuAddress,
                                 index: 4)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise)
        solidForReflections = waterReflects ? opaque : nil
        defer { solidForReflections = nil }
        encodeOverSolid(into: encoder, solidDepth: opaque.depth)
    }

    /// **Everything see-through, over everything solid**: blended, tested against the scene's depth and writing none, so
    /// a pane hides nothing behind it — and so drawn back to front (2026-11-01): the props farthest first
    /// (``sortSeeThrough()``), the water between those under its surface and those above it. Unsorted, a far pane drawn
    /// after a near one blended over it, and water drawn after a window above it lost the window's tint. Then the
    /// effects and the scene's edge. `solidDepth` is the solid pass's, for the liquids; nil in one pass, which has none.
    private func encodeOverSolid(into encoder: MTL4RenderCommandEncoder, solidDepth: MTLTexture?) {
        encodeSeeThrough(preparedSeeThroughUnder, into: encoder, solidDepth: solidDepth)
        encoder.setRenderPipelineState(propPipeline)
        encodeWater(into: encoder)
        encodeStreams(into: encoder)
        encodeLiquids(into: encoder, solidDepth: solidDepth)
        encodeSeeThrough(preparedSeeThrough, into: encoder, solidDepth: solidDepth)
        // Last: they blend over everything solid, and are hidden behind it.
        if drawsEffects {
            effects.draw(into: encoder, frameSlot: frameSlot, viewProjection: viewProjection, camera: camera,
                         lighting: frameLighting, solidDepth: solidDepth,
                         nearPlane: camera.projectionMatrix(aspectRatio: aspectRatio).columns.3.z)
        }
        if showsWeather, drawsEffects {
            weatherRenderer.draw(frameWeather, into: encoder, frameSlot: frameSlot, viewProjection: viewProjection,
                                 eye: camera.eye, time: weatherTime, lighting: frameLighting,
                                 fogDensity: frameWeather.fogDensity(over: scene.sky.fogDensity),
                                 cover: coverDrawn ? weatherCover : nil,
                                 pixelAngle: camera.fieldOfView / Float(max(viewportHeight, 1)),
                                 brightness: 1)
        }
        // **Lightning's bolts** (2026-11-16) — whenever lightning flashes, the weather shown or not, as the flash is: a far
        // strike to the ground under it, a close one to the tallest thing near it.
        if drawsEffects, frameWeather.settings.lightning > 0 || !frameWeather.addedStrikes.isEmpty {
            weatherRenderer.drawLightning(frameWeather, into: encoder, frameSlot: frameSlot, viewProjection: viewProjection,
                                          eye: camera.eye, time: weatherTime,
                                          fogDensity: frameWeather.fogDensity(over: scene.sky.fogDensity),
                                          pixelAngle: camera.fieldOfView / Float(max(viewportHeight, 1)),
                                          cloudBase: frameClouds?.layer.base ?? 1500) { [unowned self] strike in
                strikeLanding(strike)
            }
        }
        encodeBoundary(into: encoder, frameSlot: frameSlot, viewProjection: viewProjection)
        if let waymark {
            let elapsed = ContinuousClock.now - boundaryClock
            let time = Float(elapsed.components.seconds) + Float(elapsed.components.attoseconds) * 1e-18
            waymarkRenderer.draw(waymark, into: encoder, frameSlot: frameSlot, viewProjection: viewProjection,
                                 camera: camera.eye, time: time,
                                 pixelAngle: camera.fieldOfView / Float(max(viewportHeight, 1)))
        }
        if let scan {
            let size = engine.sceneSize
            scanRenderer.draw(scan, shown: scanShown, surface: { [unowned self] in scanSurface($0) }, mask: scanMask,
                              into: encoder, frameSlot: frameSlot, viewProjection: viewProjection, camera: camera.eye,
                              viewportSize: SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1))))
        }
    }

    /// **The liquids above the water, nearest first, each writing depth** (2026-11-01). Drawn back to front and blended,
    /// as the pack's material is (it writes no depth), every one of the goop pieces stacked over a pixel was shaded — a marsh map
    /// lays 105 of them, overlapping, and that was a quarter of a frame on the GPU. Nearest first with depth written, the
    /// first piece over a pixel is shaded and those behind it are turned away before they are, and overlapping pieces read
    /// as the one surface of goop they are, without the outlines where a single layer let the water through. The glass is
    /// drawn after, back to front, tested against the goop.
    private func encodeLiquids(into encoder: MTL4RenderCommandEncoder, solidDepth: MTLTexture?) {
        guard !preparedLiquids.isEmpty, solidDepth != nil else { return }
        encodeSeeThrough(Array(preparedLiquids.reversed()), into: encoder, solidDepth: solidDepth, depthState: liquidDepthState)
    }

    private func encodeSeeThrough(_ draws: [PreparedDraw], into encoder: MTL4RenderCommandEncoder, solidDepth: MTLTexture?,
                                  depthState drawState: MTLDepthStencilState? = nil) {
        guard !draws.isEmpty else { return }
        var pipeline: MTLRenderPipelineState?
        encoder.setDepthStencilState(drawState ?? waterDepthState)
        for draw in draws {
            let wanted = draw.liquid == nil ? seeThroughPipeline : liquidPipeline
            if draw.liquid != nil && solidDepth == nil { continue }
            if pipeline !== wanted { encoder.setRenderPipelineState(wanted); pipeline = wanted }
            if let liquid = draw.liquid, let solidDepth {
                argumentTable.setAddress(liquid.uniforms, index: 5)
                argumentTable.setTexture(liquid.look.noise.gpuResourceID, index: 2)
                argumentTable.setTexture(liquid.look.normals.gpuResourceID, index: 3)
                argumentTable.setTexture(solidDepth.gpuResourceID, index: 6)
            }
            draw.indices.bindVertices(of: draw.mesh, to: argumentTable)
            argumentTable.setAddress(draw.uniforms, index: 1)
            argumentTable.setTexture((draw.liquid?.look.sheet ?? draw.baseMap).gpuResourceID, index: 0)
            if draw.liquid == nil {
                argumentTable.setTexture(draw.glowMap.gpuResourceID, index: 2)
                bindGrunge(draw.grime)
            }
            if let instances = draw.instances { argumentTable.setAddress(instances.address, index: 3) }
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: draw.indices.count,
                                          indexType: draw.indices.type, indexBuffer: draw.indices.address,
                                          indexBufferLength: draw.indices.length,
                                          instanceCount: draw.instances?.count ?? 1)
            drawn.view += 1
            drawn.viewTriangles += draw.indices.count / 3 * (draw.instances?.count ?? 1)
        }
        encoder.setRenderPipelineState(propPipeline)
        encoder.setDepthStencilState(depthState)
    }

    /// **The scene's edge, after everything**, as the game shows it — round the walker, or round where the view looks —
    /// and all of it while it is being set (``showsWholeBoundary``).
    private func encodeBoundary(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, viewProjection: simd_float4x4) {
        let feet = boundaryPlayer
        guard drawsBoundary || feet != nil || showsWholeBoundary else { return }
        guard var boundary = scene.boundary else { return }
        if showsWholeBoundary {
            boundary.look.visibility = .always
            boundary.look.opacity = max(boundary.look.opacity, 0.3)
        }
        let elapsed = ContinuousClock.now - boundaryClock
        let time = Float(elapsed.components.seconds) + Float(elapsed.components.attoseconds) * 1e-18
        boundaryRenderer.draw(boundary, into: encoder, frameSlot: frameSlot, viewProjection: viewProjection,
                              camera: camera.eye, player: feet ?? camera.target, time: time,
                              brightness: boundaryBrightness)
    }

    // MARK: A frame, prepared

    /// One submesh to draw in the main pass, its uniforms already written.
    private struct PreparedDraw {
        let mesh: MTKMesh
        let indices: IndexRange
        let uniforms: UInt64
        let baseMap: MTLTexture
        let glowMap: MTLTexture
        /// Copies to draw, with their transforms' address — `nil` for a placed prop, drawn once.
        let instances: (address: UInt64, count: Int)?
        /// Drawn as a liquid (``liquidFragment``), with its uniforms' address this frame; nil for anything else.
        var liquid: (look: LiquidLook, uniforms: UInt64)? = nil
        /// The grime `propFragment` lays over it, or nil.
        var grime: GrungeLook? = nil
        /// Snow built up on its copies (``snowCapVertex``), not the prop itself.
        var snowCap = false
    }

    /// **Everything the frame draws, with its uniforms written before any pass runs** — because the sun's
    /// shadow pass comes first and reads the same `model` matrices the scene will, which is what keeps a
    /// shadow attached to the thing that cast it (Ductane's `ShadowMap` contract).
    private var prepared: [PreparedDraw] = []
    /// The see-through submeshes in view (``isSeeThrough(_:)``), farthest first (``sortSeeThrough()``): those under a
    /// body of water, drawn before it, and the rest, after.
    private var preparedSeeThroughUnder: [PreparedDraw] = []
    private var preparedSeeThrough: [PreparedDraw] = []
    /// The liquids in view above the water, farthest first as sorted — drawn nearest first (``encodeLiquids``).
    private var preparedLiquids: [PreparedDraw] = []
    /// The copies in view with see-through submeshes, placed and scattered together, before ``sortSeeThrough()`` puts
    /// them in order.
    private var seeThroughCopies: [SeeThroughCopy] = []
    private struct SeeThroughCopy {
        let meshes: [ShownMesh]
        let tier: Int
        let transform: simd_float4x4
        let centre: SIMD3<Float>
    }
    /// The see-through copies' transforms, one each, farthest first.
    private lazy var seeThroughTransforms = InstanceBuffer(renderer: engine)
    private var preparedGround: UInt64?
    /// The ground's layers this frame, while it is drawn from their textures (``groundLayerUniforms()``).
    private var preparedGroundLayers: UInt64?
    /// The ground's uniforms for its coarser chunks: `params.w` 2 tells the shader to read the full ground under them.
    private var preparedCoarseGround: UInt64?

    /// **Every pipeline that draws into the scene pass**, built for one sample count — all must match the engine's
    /// (``FrameRenderer/sampleCount``). Props and scattered copies **turn a cut-out edge into coverage** when
    /// multisampled (alpha to coverage; `propFragment` hands over the edge), so leaves and grass are smoothed too.
    /// The pipelines that draw surfaces with `propFragment` — built once with the weather on surfaces compiled in and once
    /// without (``fullSurfaces``, ``plainSurfaces``).
    private struct SurfacePipelines {
        /// `texturedGround`: the ground drawn from its layers' textures (function constant 2), while a layer has one.
        let prop, ground, texturedGround, instanced, seeThrough, effectMesh, impostor: MTLRenderPipelineState
        var all: [AnyObject] { [prop, ground, texturedGround, instanced, seeThrough, effectMesh, impostor] }
        /// Where the set with or without the weather on surfaces and the seasons on foliage is kept.
        static func index(weather: Bool, seasons: Bool) -> Int { (weather ? 1 : 0) + (seasons ? 2 : 0) }
    }

    private struct ScenePipelines {
        /// By ``SurfacePipelines/index(weather:seasons:)``.
        let surfaceSets: [SurfacePipelines]
        let snowCap, liquid, grid, water, stream: MTLRenderPipelineState
        let fogSky: FogSkyPass
        let sky: SkyPass
    }

    /// **A surface function with the weather on surfaces (constant 0) and the seasons on foliage (constant 1) compiled in
    /// or out** — every function that reads them must be made with both set (``SurfacePipelines``).
    private static func surfaceFunction(_ name: String, library: MTLLibrary, weather: Bool, seasons: Bool,
                                        texturedGround: Bool = false) -> MTL4FunctionDescriptor {
        let base = MTL4LibraryFunctionDescriptor()
        base.library = library
        base.name = name
        let values = MTLFunctionConstantValues()
        var weather = weather, seasons = seasons, textured = texturedGround
        values.setConstantValue(&weather, type: .bool, index: 0)
        values.setConstantValue(&seasons, type: .bool, index: 1)
        values.setConstantValue(&textured, type: .bool, index: 2)
        let specialized = MTL4SpecializedFunctionDescriptor()
        specialized.functionDescriptor = base
        specialized.constantValues = values
        specialized.specializedName = name + (weather ? "Weather" : "") + (seasons ? "Seasons" : "")
            + (texturedGround ? "TexturedGround" : "") + "Specialized"
        return specialized
    }

    private static func buildScenePipelines(device: MTLDevice, library: MTLLibrary, sampleCount: Int) throws -> ScenePipelines {
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
            let f = MTL4LibraryFunctionDescriptor()
            f.library = library
            f.name = name
            return f
        }
        /// A surface function with the weather on surfaces (constant 0) and the seasons on foliage (constant 1) compiled
        /// in or out.
        func function(_ name: String, compiled: (weather: Bool, seasons: Bool)?, textured: Bool = false) -> MTL4FunctionDescriptor {
            guard let compiled else { return function(name) }
            return surfaceFunction(name, library: library, weather: compiled.weather, seasons: compiled.seasons,
                                   texturedGround: textured)
        }
        func pipeline(_ label: String, _ vertex: String, _ fragment: String, _ vertexDescriptor: MTLVertexDescriptor?,
                      coverage: Bool = false, compiled: (weather: Bool, seasons: Bool)? = nil,
                      textured: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTL4RenderPipelineDescriptor()
            d.label = label
            d.vertexFunctionDescriptor = function(vertex, compiled: compiled, textured: textured)
            d.fragmentFunctionDescriptor = function(fragment, compiled: compiled, textured: textured)
            d.vertexDescriptor = vertexDescriptor
            d.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
            d.rasterSampleCount = sampleCount
            if coverage && sampleCount > 1 { d.alphaToCoverageState = .enabled }
            return try compiler.makeRenderPipelineState(descriptor: d, compilerTaskOptions: nil)
        }
        // **Water is see-through**: blended over what is already drawn, so it is drawn last of the scene, after everything
        // opaque.
        let water = MTL4RenderPipelineDescriptor()
        water.label = "Water"
        water.vertexFunctionDescriptor = function("waterVertex")
        water.fragmentFunctionDescriptor = function("waterFragment")
        water.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
        water.colorAttachments[0].blendingState = .enabled
        water.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        water.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        water.colorAttachments[0].sourceAlphaBlendFactor = .one
        water.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        water.rasterSampleCount = sampleCount
        let stream = water.copy() as! MTL4RenderPipelineDescriptor
        stream.label = "Streams"
        stream.vertexFunctionDescriptor = function("streamVertex")
        stream.fragmentFunctionDescriptor = function("streamFragment")
        // Glass blends as water does, with the props' own shading (`propFragment` hands over its opacity).
        func seeThrough(_ compiled: (weather: Bool, seasons: Bool), label: String) -> MTL4RenderPipelineDescriptor {
            let d = water.copy() as! MTL4RenderPipelineDescriptor
            d.label = "See-through Props" + label
            d.vertexFunctionDescriptor = function("propInstancedVertex", compiled: compiled)
            d.fragmentFunctionDescriptor = function("propFragment", compiled: compiled)
            d.vertexDescriptor = Self.vertexDescriptor()
            return d
        }
        // A liquid blends the same way, in its own shading (``WorldFile/Liquid``).
        let liquid = seeThrough((true, true), label: "")
        liquid.label = "Liquids"
        liquid.fragmentFunctionDescriptor = function("liquidFragment")
        func surfaces(weather: Bool, seasons: Bool) throws -> SurfacePipelines {
            let compiled = (weather: weather, seasons: seasons)
            let label = (weather ? "" : ", no weather") + (seasons ? "" : ", no seasons")
            return SurfacePipelines(
                prop: try pipeline("Prop" + label, "propVertex", "propFragment", Self.vertexDescriptor(), coverage: true,
                                   compiled: compiled),
                ground: try pipeline("Ground" + label, "groundVertex", "propFragment", Self.groundVertexDescriptor(),
                                     compiled: compiled),
                texturedGround: try pipeline("Textured Ground" + label, "groundVertex", "propFragment",
                                             Self.groundVertexDescriptor(), compiled: compiled, textured: true),
                instanced: try pipeline("Scattered Props" + label, "propInstancedVertex", "propFragment",
                                        Self.vertexDescriptor(), coverage: true, compiled: compiled),
                seeThrough: try compiler.makeRenderPipelineState(descriptor: seeThrough(compiled, label: label),
                                                                 compilerTaskOptions: nil),
                effectMesh: try pipeline("Effect Meshes" + label, "effectMeshVertex", "propFragment", Self.vertexDescriptor(),
                                         coverage: true, compiled: compiled),
                impostor: try pipeline("Far Pictures" + label, "impostorVertex", "impostorFragment", nil, coverage: true,
                                       compiled: compiled))
        }
        // In ``SurfacePipelines/index(weather:seasons:)`` order.
        let sets = try [(false, false), (true, false), (false, true), (true, true)].map { try surfaces(weather: $0.0, seasons: $0.1) }
        return ScenePipelines(
            surfaceSets: sets,
            snowCap: try pipeline("Snow Caps", "snowCapVertex", "snowCapFragment", Self.vertexDescriptor()),
            liquid: try compiler.makeRenderPipelineState(descriptor: liquid, compilerTaskOptions: nil),
            grid: try pipeline("Grid", "gridVertex", "gridFragment", nil),
            water: try compiler.makeRenderPipelineState(descriptor: water, compilerTaskOptions: nil),
            stream: try compiler.makeRenderPipelineState(descriptor: stream, compilerTaskOptions: nil),
            fogSky: try FogSkyPass(device: device, sampleCount: sampleCount),
            sky: try SkyPass(device: device, sampleCount: sampleCount))
    }

    // MARK: Viewport graphics

    /// **The graphics settings asked for** (``GraphicsSettings``): anti-aliasing, shadows, render scale, frame rate,
    /// clouds, fog, snow depth, texture quality. Applied at the start of the next frame when they change; replaced
    /// pipelines and shadow maps are kept until no frame in flight can still be using them.
    public var graphicsSettings: GraphicsSettings
    /// The settings as last applied.
    private var graphics = GraphicsSettings()
    private var appliedGraphics = false
    private var retired: [(objects: [AnyObject], allocations: [any MTLAllocation], after: Int)] = []
    /// Told when settings are applied — the frame rate asked for, for whatever owns the display link.
    public var onFrameRateChange: ((GraphicsSettings) -> Void)?

    private func applyGraphics(_ next: GraphicsSettings) {
        graphics = next
        appliedGraphics = true
        let samplesBefore = engine.effectiveSampleCount
        engine.apply(next, automaticScaling: .native)
        let samples = engine.effectiveSampleCount
        let after = framesEncoded + FrameRenderer.maxFramesInFlight + 1
        if samples != samplesBefore {
            do {
                let rebuilt = try Self.buildScenePipelines(device: device, library: library, sampleCount: samples)
                retired.append((surfaceSets.flatMap(\.all) + [snowCapPipeline, liquidPipeline,
                                 gridPipeline, waterPipeline, streamPipeline, fogSkyPass, skyPass], skyPass.allocations, after))
                surfaceSets = rebuilt.surfaceSets
                snowCapPipeline = rebuilt.snowCap
                liquidPipeline = rebuilt.liquid
                gridPipeline = rebuilt.grid
                waterPipeline = rebuilt.water
                streamPipeline = rebuilt.stream
                fogSkyPass = rebuilt.fogSky
                skyPass = rebuilt.sky
                engine.residencySet.addAllocations(rebuilt.sky.allocations)
                let oldEffects = try effects.rebuild(sampleCount: samples)
                retired.append(([oldEffects], [], after))
                engine.residencySet.addAllocations(effects.allocations)
                let oldBoundary = boundaryRenderer!
                boundaryRenderer = try BoundaryRenderer(device: device, sampleCount: samples)
                retired.append(([oldBoundary], oldBoundary.allocations, after))
                engine.residencySet.addAllocations(boundaryRenderer.allocations)
                let oldWaymark = waymarkRenderer!
                waymarkRenderer = try WaymarkRenderer(device: device, sampleCount: samples)
                retired.append(([oldWaymark], oldWaymark.allocations, after))
                engine.residencySet.addAllocations(waymarkRenderer.allocations)
                let oldScan = scanRenderer!
                scanRenderer = try WaymarkScanRenderer(device: device, sampleCount: samples)
                retired.append(([oldScan], oldScan.allocations, after))
                engine.residencySet.addAllocations(scanRenderer.allocations)
                watchScanMasks()
                let oldWeather = weatherRenderer!
                weatherRenderer = try WeatherRenderer(device: device, sampleCount: samples)
                retired.append(([oldWeather], oldWeather.allocations, after))
                engine.residencySet.addAllocations(weatherRenderer.allocations)
                engine.commitResidency()
            } catch {
                engine.sampleCount = samplesBefore
                NSLog("WorldRenderer: anti-aliasing unchanged — \(error)")
            }
        }
        // **Off gives its memory back** (2026-10-28): the cascades stayed allocated with nothing drawing into them, and
        // the statistics showed shadows off saving GPU time and not a byte. A 16-texel map stands in rather than
        // none, so the shader's shadow slot always holds a depth array that is alive.
        let resolution = next.shadows.resolution ?? 16
        if resolution != shadowMap?.cascades.resolution {
            do {
                let fresh = try ShadowMap(device: device, cascades: Self.cascades(reaching: shadowReach, resolution: resolution))
                if let old = shadowMap { retired.append(([old], old.allocations, after)) }
                shadowMap = fresh
                engine.residencySet.addAllocations(fresh.allocations)
                engine.commitResidency()
            } catch {
                NSLog("WorldRenderer: shadow quality unchanged — \(error)")
            }
        }
        // The ground's layer textures at the new size too.
        if groundTexturesKey != nil { refreshGroundTextures() }
        // **Textures at another size: every prop is read again** (`TextureStore.quality` forgets what it loaded).
        if next.textureQuality != textures.quality {
            let before = textures.allocations
            textures.quality = next.textureQuality
            retire(Self.forgotten(before, now: textures.allocations))
            if !props.isEmpty {
                reload(Set(props.keys))
                onPropsDropped?()
            }
        }
        onFrameRateChange?(next)
    }

    /// What a background load compresses textures with: the cache, and the quality they are loaded at.
    nonisolated struct TextureCompression: Sendable {
        let cache: URL
        let quality: GraphicsSettings.TextureQuality
    }
    private var textureCompression: TextureCompression? {
        textures.compressionCache.map { TextureCompression(cache: $0, quality: textures.quality) }
    }

    /// Told when loaded props were dropped to be read again — at a new texture quality: load what the scene is missing.
    public var onPropsDropped: (() -> Void)?

    private func releaseRetired() {
        while let first = retired.first, first.after <= framesEncoded {
            if !first.allocations.isEmpty {
                engine.residencySet.removeAllocations(first.allocations)
                engine.commitResidency()
            }
            retired.removeFirst()
        }
    }

    /// The sun's shadows: four cascades, **the nearest three fixed and the farthest reaching as far as the scene can be
    /// seen from the view** (2026-10-26). It stopped at 280 m, sized for a 256 m ground, and a 400 m zone seen whole had
    /// its far side lit as if nothing stood on it. Never nearer than 280 m, so a close view keeps its sharp shadows.
    static func cascades(reaching far: Float, resolution: Int = 2048) -> ShadowCascades {
        let reach = max(far, 280)
        return ShadowCascades(splits: [12, 36, 100, reach], resolution: resolution, lightDepthRange: reach * 1.8)
    }

    /// How far the far cascade reaches for this view: out past the farthest corner of the ground or the props, from
    /// where the view is. **In steps of a tenth**, so panning does not set the far shadows crawling every frame.
    private var shadowReach: Float {
        let ground = terrainShape.map { SIMD2<Float>(repeating: $0.size / 2) } ?? .zero
        let half = simd_max(ground, simd_max(simd_abs(sceneExtent.minimum), simd_abs(sceneExtent.maximum)))
        let target = SIMD2(camera.target.x, camera.target.z)
        let far = camera.distance + simd_length(simd_abs(target) + half)
        guard far > 280 else { return 280 }
        let steps = (log(far / 280) / log(1.1)).rounded(.up)
        return min(280 * pow(1.1, steps), 6000)
    }
    /// **The world's reach across the ground**, from its middle — how far out the farthest shadow cascade must reach for a
    /// view to see the whole of it shadowed. Set by ``fitExtent()``.
    public var sceneExtent = (minimum: SIMD2<Float>.zero, maximum: SIMD2<Float>.zero)

    /// **Every placed prop and scattered copy that is loaded, in one box** — nil before any is.
    public func propBounds() -> BoundingBox? {
        var boxes = scene.placements.compactMap { placement in bounds(of: placement.prop)?.transformed(by: placement.transform) }
        for scatter in scene.scatters {
            for copy in scatter.copies where copy.prototype < scatter.prototypes.count {
                if let box = bounds(of: scatter.prototypes[copy.prototype]) {
                    boxes.append(box.transformed(by: copy.transform))
                }
            }
        }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first, Self.union)
    }

    /// **The shown ground's box** — its square, from its lowest point to its highest; nil with no ground.
    public func groundBounds() -> BoundingBox? {
        guard let shape = terrainShape, !terrainMirror.isEmpty else { return nil }
        let half = shape.size / 2
        let heights = stride(from: 1, to: terrainMirror.count, by: 12).map { terrainMirror[$0] }
        return BoundingBox(minimum: SIMD3(-half, heights.min() ?? 0, -half), maximum: SIMD3(half, heights.max() ?? 0, half))
    }

    /// **The whole world's box — props and ground — with ``sceneExtent`` fitted to it**: call once the props have loaded
    /// and when the world grows. Nil when there is nothing yet.
    @discardableResult
    public func fitExtent() -> BoundingBox? {
        let parts = [propBounds(), groundBounds()].compactMap { $0 }
        guard let first = parts.first else { return nil }
        let whole = parts.dropFirst().reduce(first, Self.union)
        sceneExtent = (SIMD2(whole.minimum.x, whole.minimum.z), SIMD2(whole.maximum.x, whole.maximum.z))
        return whole
    }

    private static func union(_ a: BoundingBox, _ b: BoundingBox) -> BoundingBox {
        BoundingBox(minimum: simd_min(a.minimum, b.minimum), maximum: simd_max(a.maximum, b.maximum))
    }

    private lazy var shadowMap: ShadowMap? = {
        let map: ShadowMap
        do {
            map = try ShadowMap(device: device, cascades: Self.cascades(reaching: 0))
        } catch {
            NSLog("WorldRenderer: no sun shadows — \(error)")
            return nil
        }
        engine.residencySet.addAllocations(map.allocations)
        engine.commitResidency()
        return map
    }()

    /// How long the last frame's preparation took on the CPU, milliseconds.
    public private(set) var preparationMilliseconds: Double = 0

    /// **Whether living effects are drawn** — particles, falling weather, lightning, fog's volume: off to measure what
    /// they cost.
    public var drawsEffects = true
    /// **Whether the sun casts shadows** at all, whatever the graphics settings say: off to measure what they cost.
    public var castsShadows = true
    /// **Scattered props left out of the frame**, by file — nil for none: to measure what a kind of scatter costs.
    public var hidesScattered: ((URL) -> Bool)?

    public func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {
        onFrame?()
        let started = CFAbsoluteTimeGetCurrent()
        defer { preparationMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
        self.frameSlot = frameSlot
        nextSlot = 0
        refusedObjects = 0
        prepared.removeAll(keepingCapacity: true)
        preparedSeeThroughUnder.removeAll(keepingCapacity: true)
        preparedLiquids.removeAll(keepingCapacity: true)
        preparedSeeThrough.removeAll(keepingCapacity: true)
        seeThroughCopies.removeAll(keepingCapacity: true)
        preparedGround = nil
        preparedGroundLayers = nil
        preparedCoarseGround = nil
        preparedImpostors.removeAll(keepingCapacity: true)
        instancedUniformCache.removeAll(keepingCapacity: true)
        if terrainDirty { rebuildTerrain() }
        addArrivedCopies()
        releaseRetired()
        let asked = graphicsSettings
        if asked != graphics || !appliedGraphics { applyGraphics(asked) }
        // Scattered copies gathered before the bake, so a far picture they ask for is baked in this frame, not the next.
        if scatteredCopies == nil { _ = gatherScatteredCopies() }
        encodeImpostorBakes(into: commandBuffer)

        // **The sky under the weather**: clouds always, lightning's flash only while the weather is shown.
        let flash = showsWeather ? frameWeather.flash(at: weatherTime, seenFrom: camera.eye) : 0
        let light = frameWeather.lighting(frameDaySky.lighting, flash: flash)
        frameLighting = light
        encodeClouds(into: commandBuffer, lighting: light)
        let viewProjection = self.viewProjection
        encodeScanMask(into: commandBuffer, viewProjection: viewProjection)
        // **What is overhead, round the eye**, for rain and snow to keep out from under — drawn while they fall, and
        // whenever snow lies, which settles only on what is open to the sky.
        let weather = frameWeather
        snowLying = weather.lyingSnow
        snowDepthShown = weather.snowDepth && graphics.snowDepth ? weather.lyingSnow * Weather.deepestSnow : 0
        frameWet = (weather.wetness, weather.puddles, weather.settings.snow ? 0 : weather.settings.precipitation)
        frameWind = weather.foliageWind(at: weatherTime)
        let daySky = frameDaySky
        frameFall = !drawsFallColors ? nil : scene.sky.clock.map { clock in
            (clock.foliage, FallColors.phase(yearPosition: daySky.yearPosition, southern: clock.southern))
        }
        refreshLitterField()
        let covering = weatherCover != nil
            && ((showsWeather && weather.settings.precipitation > 0) || snowLying > 0 || frameWet.surface > 0 || frameWet.puddles > 0
                || weather.settings.dust > 0)
        // **Kept to 8 m steps and drawn again only when it moves or every half second** (2026-11-15): drawn every
        // frame, a marsh map's ±96 m of props cost 1.8 ms of GPU a frame for a picture that changes only when the eye has
        // moved a few metres or the scene has been edited. The rain's ±18 m box stays inside it.
        var redrawCover = false
        let coverMatrix: simd_float4x4
        if covering {
            let centre = SIMD3((camera.eye.x / Self.coverStep).rounded() * Self.coverStep,
                               (camera.eye.y / 4).rounded() * 4,
                               (camera.eye.z / Self.coverStep).rounded() * Self.coverStep)
            coverMatrix = weatherCover.update(around: centre)
            coverAge += 1
            redrawCover = coverMatrix != coverDrawnMatrix || coverAge >= Self.coverRefresh
        } else {
            coverMatrix = matrix_identity_float4x4
            coverDrawnMatrix = nil
        }
        // The sun casts only while it is up; the moon's light is too faint to shadow anything worth seeing.
        let casting = light.elevation > 0.01 && shadowMap != nil && graphics.shadows != .off && castsShadows
        if casting, shadowMap!.cascades.splits.last != shadowReach {
            shadowMap!.cascades = Self.cascades(reaching: shadowReach, resolution: shadowMap!.cascades.resolution)
        }
        let shadowCascades = shadowMap?.cascades ?? Self.cascades(reaching: 0)
        let matrices = casting
            ? shadowMap!.updateMatrices(frameSlot: frameSlot, cameraPosition: camera.eye,
                                        cameraForward: simd_normalize(camera.target - camera.eye),
                                        sunDirection: light.direction)
            : Array(repeating: matrix_identity_float4x4, count: 4)
        // **Footprints round the eye**, handed to the shaders only while there are any.
        footprints.forget(beyond: FootprintGrid.halfExtent * 1.5, of: camera.eye)
        footprintsDrawn = footprintGrid != nil && !footprints.prints.isEmpty
            && footprintGrid.update(frameSlot: frameSlot, trail: footprints, around: camera.eye) > 0
        writeFrame(frameSlot: frameSlot, light: light, cascades: matrices, casting: casting, covering: covering)

        // The ground: the chunks in view, and in each cascade.
        if var chunks = groundChunks, let dirty = groundChunksDirty, !terrainMirror.isEmpty {
            chunks.updateHeights(terrainMirror, dirty)
            groundChunks = chunks
            groundChunksDirty = nil
        }
        if let chunks = groundChunks {
            if groundHoleChunksDirty {
                groundHoleChunks = chunks.chunksWithHoles(terrainHoles)
                groundHoleChunksDirty = false
            }
            // **Far chunks at a coarser level** (2026-11-01): a 400 m zone seen whole was 1.28 M triangles of ground,
            // about one a pixel, and a third of the frame.
            (groundRanges, groundCoarseRanges) = chunks.viewRanges(
                Frustum(viewProjection: viewProjection).planes, eye: camera.eye,
                pixelsPerRadian: Float(viewportHeight) / camera.fieldOfView, holes: groundHoleChunks)
            groundCascadeRanges = casting ? matrices.map { chunks.ranges(Frustum(viewProjection: $0).planes) } : []
            groundCoverRanges = redrawCover ? chunks.ranges(Frustum(viewProjection: coverMatrix).planes) : []
        }
        if terrainShape != nil {
            preparedGround = write(ObjectUniforms(model: matrix_identity_float4x4, normalMatrix: matrix_identity_float4x4,
                                                  baseColour: SIMD4(1, 1, 1, 1), emissive: .zero,
                                                  params: SIMD4(0.95, 0, 0, 1)))
            preparedGroundLayers = groundLayerUniforms().flatMap { write($0) }
            if !groundCoarseRanges.isEmpty {
                preparedCoarseGround = write(ObjectUniforms(model: matrix_identity_float4x4,
                                                            normalMatrix: matrix_identity_float4x4,
                                                            baseColour: SIMD4(1, 1, 1, 1), emissive: .zero,
                                                            params: SIMD4(0.95, 0, 0, 2)))
            }
        }
        // **Placed props and scattered copies alike: only what a pass can see, instanced, each at its level of detail**
        // (`WorldCopyField`). Each copy's box is tested against the view, and against each of the sun's cascades for
        // the shadows: a near cascade covers a few metres, and drawing a whole wood into it was three quarters of a
        // measured frame. **Each copy also gets a level of detail** (Ductane's `MeshDetail`), chosen once from
        // how far it stands from the camera and used by the shadows too: copies at different levels are different
        // batches.
        //
        // **Placed props went this way on 2026-10-28.** They had been drawn one by one, every one every frame, with a
        // set of uniforms per submesh — fine for a hand-laid scene of a few hundred, and 5–8 fps on an
        // imported map of 11,566: the same frame time looking at one fence as at the whole map.
        //
        // **How big each copy is on screen decides whether it is drawn and whether it casts** (2026-10-25). A meadow
        // is tens of thousands of grass clumps; drawn to the horizon and cast into every cascade they took a frame from
        // 25 ms to 122. A copy under ``smallestDrawn`` pixels is not drawn; one under ``smallestCaster`` casts no
        // shadow, and none casts into a cascade too coarse for its size. Big things — trees, buildings — still cast
        // across the whole scene; grass stops a few tens of metres out.
        //
        // **Chosen cell by cell, in an optimised module** (`WorldCopyField`, 2026-10-25): one by one here it was 60 ms
        // of a Debug frame at 48,000 copies — a twitch felt orbiting and walking.
        var cascades: [WorldCopyField.Cascade] = casting ? matrices.enumerated().map { cascade, matrix in
            // **Only into the cascades whose stretch of view its shadow can fall in.** Each cascade is sampled only
            // between its start and its split; grass at the camera's feet drawn into the far cascade was most of the
            // shadow pass, and a shadow nobody samples.
            WorldCopyField.Cascade(planes: Frustum(viewProjection: matrix).planes,
                                   start: cascade == 0 ? 0 : shadowCascades.blendStart(forCascade: cascade - 1),
                                   end: shadowCascades.splits[cascade], texelSize: shadowCascades.texelSize(forCascade: cascade))
        } : []
        // The cover is one more look for the copies to be chosen for, after the sun's cascades.
        let coverIndex: Int? = redrawCover ? cascades.count : nil
        if redrawCover {
            cascades.append(WorldCopyField.Cascade(planes: Frustum(viewProjection: coverMatrix).planes, start: 0,
                                                   end: weatherCover.halfExtent * 1.5, texelSize: weatherCover.texelSize,
                                                   isCover: true))
        }
        let settings = WorldCopyField.Settings(
            eye: camera.eye, pixelsPerRadian: Float(viewportHeight) / camera.fieldOfView,
            view: Frustum(viewProjection: viewProjection).planes, smallestDrawn: Self.smallestDrawn,
            smallestCaster: Self.smallestCaster, forcedLevel: forcedDetailLevel, farPictures: drawsFarPictures,
            cascades: cascades)
        let placed = prepare(placedCopies ?? gatherPlacedCopies(), settings: settings, view: placedTransforms,
                             shadows: placedShadowTransforms, hidden: [])
        let scattered = scatteredCopies ?? gatherScatteredCopies()
        // **The player's draw distance and grass** (`GraphicsSettings.drawDistance`, `plantDensity`) are the scattered
        // copies'. A copy is drawn to where it shrinks to ``smallestDrawn`` pixels — each kind's own distance, set by its
        // size — so dividing that by the draw distance brings every kind in by the same share, grass first in metres
        // because it is smallest. Ground cover (`WorldScene.isGroundCover`) is thinned to the plant density.
        let shown = graphicsSettings.clamped
        var scatteredSettings = settings
        scatteredSettings.smallestDrawn = Self.smallestDrawn / shown.drawDistance
        if shown.plantDensity < 1 {
            scatteredSettings.density = shown.plantDensity
            scatteredSettings.thinned = zip(scattered.props, scattered.urls).map { prop, url in
                scene.isGroundCover(url, size: prop.bounds.size, cutOut: prop.isCutOut)
            }
        }
        let copies = prepare(scattered, settings: scatteredSettings, view: scatterTransforms, shadows: shadowTransforms,
                             hidden: hidesScattered.map { hides in Set(scattered.index.compactMap { hides($0.key) ? $0.value : nil }) } ?? [])
        // What rolls in the wind, where it has rolled to this frame.
        let rolled = rolledCopies().map {
            prepare($0, settings: settings, view: rollingTransforms, shadows: rollingShadowTransforms, hidden: [])
        }
        sortSeeThrough()
        // The shadows, per cascade: solid submeshes and cut-out ones apart.
        func joined(_ a: [[ShadowPart]], _ b: [[ShadowPart]], _ c: [[ShadowPart]]?) -> [[ShadowPart]] {
            a.indices.map { a[$0] + (b.indices.contains($0) ? b[$0] : []) + ((c?.indices.contains($0) ?? false) ? c![$0] : []) }
        }
        let shadowCopies = joined(placed.solid, copies.solid, rolled?.solid)
        let cutCopies = joined(placed.cut, copies.cut, rolled?.cut)

        if redrawCover {
            encodeCover(into: commandBuffer, frameSlot: frameSlot, index: coverIndex, solid: shadowCopies, cut: cutCopies)
            if coverDrawn { coverDrawnMatrix = coverMatrix; coverAge = 0 }
        } else {
            // The picture drawn before still holds: the same place, nothing redrawn since the last refresh.
            coverDrawn = covering && coverDrawnMatrix != nil
        }

        drawn.shadows = 0
        drawn.shadowTriangles = 0
        guard casting, let shadowMap else {
            encodeFog(into: commandBuffer, light: light, matrices: matrices, casting: false)
            return
        }
        // Only the cascades the setting casts into: Near only leaves the farthest out.
        let castInto = graphics.shadows.castingCascades(of: shadowMap.cascades.count)
        for cascade in 0..<castInto {
            for part in (cascade < shadowCopies.count ? shadowCopies[cascade] : [])
                + (cascade < cutCopies.count ? cutCopies[cascade] : []) {
                drawn.shadows += 1
                drawn.shadowTriangles += part.indices.count / 3 * (part.copies?.count ?? 1)
            }
            if cascade < groundCascadeRanges.count {
                drawn.shadows += groundCascadeRanges[cascade].count
                drawn.shadowTriangles += groundCascadeRanges[cascade].reduce(0) { $0 + $1.count } / 3
            }
        }
        var shadowBatches: [ShadowBatch] = []
        if shadowCopies.contains(where: { !$0.isEmpty }) {
            shadowBatches.append(ShadowBatch(pipeline: shadowInstancedPipeline) { encoder, table, pass in
                guard case .cascade(let cascade) = pass.target, cascade < shadowCopies.count else { return }
                Self.draw(shadowCopies[cascade], into: encoder, table: table)
            })
        }
        if cutCopies.contains(where: { !$0.isEmpty }) {
            let fragments = shadowFragmentTable
            shadowBatches.append(ShadowBatch(pipeline: shadowMaskInstancedPipeline) { encoder, table, pass in
                guard case .cascade(let cascade) = pass.target, cascade < cutCopies.count else { return }
                Self.draw(cutCopies[cascade], into: encoder, table: table, cutOut: fragments)
            })
        }
        if let ground = preparedGround, let indices = terrainIndices, !terrainVertices.isEmpty {
            let vertices = terrainVertices[terrainVertexIndex].gpuAddress, cascades = groundCascadeRanges
            shadowBatches.append(ShadowBatch(pipeline: shadowGroundPipeline) { [unowned self] encoder, table, pass in
                guard case .cascade(let cascade) = pass.target, cascade < cascades.count else { return }
                table.setAddress(ground, index: ShadowBufferIndex.uniforms)
                table.setAddress(vertices, index: ShadowBufferIndex.vertices)
                self.drawGround(cascades[cascade], indices: indices, into: encoder)
            })
        }
        shadowMap.encode(into: commandBuffer, frameSlot: frameSlot, batches: shadowBatches,
                         castingCascades: graphics.shadows.castingCascades(of: shadowMap.cascades.count))
        encodeFog(into: commandBuffer, light: light, matrices: matrices, casting: true)
    }

    // MARK: Volumetric fog

    /// **The fog volume this frame** (Ductane's `VolumetricFog`, 2026-11-16) — every surface reads it through
    /// `fogged`, and `FogSkyPass` lays its sky picture over the sky. Nil at Low quality or with nothing to draw.
    private var frameFogVolume: MTLTexture?
    /// What the fog pass made this frame — the volume, the picture for over the sky and how to read them.
    private var frameFog: VolumetricFog.Drawn?
    private lazy var volumetricFog: VolumetricFog? = {
        let fog = try? VolumetricFog(device: engine.device)
        if let fog { engine.residencySet.addAllocations(fog.allocations); engine.commitResidency() }
        return fog
    }()
    /// **How fog is drawn, whatever the graphics settings say** — to measure what it costs; nil as they say.
    public var fogAsked: GraphicsSettings.FogQuality?
    /// Where ground fog pools (`WorldScene.fogFloor`), for the ground and water it was made from — made again a moment after
    /// they change, so a brush stroke does not remake it every tick.
    private var fogFloor: FogFloor?
    private var fogFloorTexture: MTLTexture?
    private var fogFloorKey: WaterKey?
    private var fogFloorMade = ContinuousClock.now - .seconds(10)

    private func refreshFogFloor() {
        let key = WaterKey(waters: scene.waters, lineage: terrainKey?.lineage, revision: terrainKey?.revision)
        guard key != fogFloorKey, ContinuousClock.now - fogFloorMade > .milliseconds(500) || fogFloorKey == nil else { return }
        fogFloorKey = key
        fogFloorMade = .now
        fogFloor = shownFogFloor()
        let old = fogFloorTexture
        fogFloorTexture = fogFloor?.texture(device: device)
        if let made = fogFloorTexture { engine.residencySet.addAllocation(made); engine.commitResidency() }
        if let old { retired.append(([old], [old], framesEncoded + FrameRenderer.maxFramesInFlight + 1)) }
    }

    /// **Where ground fog pools** (``FogFloor``): the shown ground smoothed over tens of metres, each body of water at its
    /// level over the points it covers — fog lies over the smoothed ground, deeper in a hollow and thicker over water. Nil
    /// with no ground: the fog's floor is then level ground.
    private func shownFogFloor() -> FogFloor? {
        guard let shape = terrainShape, !terrainMirror.isEmpty else { return nil }
        let n = shape.resolution + 1
        return FogFloor(heights: (0..<(n * n)).map { terrainMirror[$0 * 12 + 1] }, resolution: shape.resolution,
                        size: shape.size, waters: scene.waters)
    }

    /// **Marches the air in front of the eye** — the world's fog, ground fog, the sun through the shadows just drawn, the
    /// clouds' shadows, the lights nearest the view — into the fog volume, and tells the frame's uniforms how to read it.
    private func encodeFog(into commandBuffer: MTL4CommandBuffer, light: DaySky.Lighting, matrices: [simd_float4x4],
                           casting: Bool) {
        frameFogVolume = nil
        frameFog = nil
        var lookup = VolumetricFog.Lookup.none
        defer {
            let slot = frameBuffer.contents().advanced(by: frameSlot * Self.frameStride)
            let at = MemoryLayout<FrameUniforms>.offset(of: \.weather.fogVolume)!
            slot.advanced(by: at).storeBytes(of: lookup.parameters, as: SIMD4<Float>.self)
        }
        let quality = fogAsked ?? graphics.fog
        guard quality != .low, drawsEffects, let fog = volumetricFog else { return }
        refreshFogFloor()
        let weather = frameWeather
        let lit = WorldScene.Light.nearest(scene.lights(at: weatherTime), to: camera.target, radius: max(camera.distance, 60), limit: Self.lightLimit)
        let shadows = casting && shadowMap != nil
            ? VolumetricFog.Shadows(texture: shadowMap!.texture, viewProjections: matrices,
                                    splits: shadowMap!.cascades.splitVector, depthBias: shadowMap!.cascades.depthBiasVector)
            : nil
        var frame = VolumetricFog.Frame(
            viewProjection: viewProjection, eye: camera.eye, lighting: light,
            fogDensity: weather.fogDensity(over: scene.sky.fogDensity), fogStart: camera.distance,
            groundFog: weather.groundFogDensity(hour: frameDaySky.timeOfDay), groundFogHeight: weather.groundFog.height,
            groundFogColour: weather.groundFog.colour, floor: fogFloor, floorTexture: fogFloorTexture,
            wisps: weather.wisps(at: weatherTime), shadows: shadows,
            clouds: frameClouds?.layer, cloudMap: cloudPass?.coverageMap,
            lights: lit.map { VolumetricFog.Light(position: $0.position, reach: $0.reach, colour: $0.colour * $0.intensity) })
        frame.dust = weather.settings.dust * Weather.dustCloudDensity
        frame.dustHeight = Weather.dustCloudHeight
        frame.dustColour = weather.dustColour
        frame.dustDrift = weather.dustBillows(at: weatherTime)
        let size = engine.sceneSize
        guard let made = fog.encode(into: commandBuffer, frameSlot: frameSlot, frame: frame, quality: quality,
                                    width: max(size.width, 1), height: max(size.height, 1)) else { return }
        if fog.volumesChanged {
            fog.volumesChanged = false
            engine.residencySet.addAllocations(fog.allocations)
            engine.commitResidency()
        }
        frameFogVolume = made.volume
        frameFog = made
        lookup = made.lookup
    }

    /// **What is overhead, drawn from straight above** (Ductane's `WeatherCover`) with the shadow pipelines and the
    /// copies chosen for it, so rain and snow keep out from under roofs and splash on them. Nothing when it is not wanted.
    private func encodeCover(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, index: Int?,
                             solid: [[ShadowPart]], cut: [[ShadowPart]]) {
        coverDrawn = false
        guard let index, let cover = weatherCover else { return }
        var batches: [ShadowBatch] = []
        let solidParts = index < solid.count ? solid[index] : []
        let cutParts = index < cut.count ? cut[index] : []
        if !solidParts.isEmpty {
            batches.append(ShadowBatch(pipeline: shadowInstancedPipeline) { encoder, table, pass in
                guard pass.target == .cover else { return }
                Self.draw(solidParts, into: encoder, table: table)
            })
        }
        if !cutParts.isEmpty {
            let fragments = shadowFragmentTable
            batches.append(ShadowBatch(pipeline: shadowMaskInstancedPipeline) { encoder, table, pass in
                guard pass.target == .cover else { return }
                Self.draw(cutParts, into: encoder, table: table, cutOut: fragments)
                encoder.setCullMode(.none)   // `draw` leaves a cascade's front-face culling; the cover sees both sides
            })
        }
        if let ground = preparedGround, let indices = terrainIndices, !terrainVertices.isEmpty, !groundCoverRanges.isEmpty {
            let vertices = terrainVertices[terrainVertexIndex].gpuAddress, ranges = groundCoverRanges
            batches.append(ShadowBatch(pipeline: shadowGroundPipeline) { [unowned self] encoder, table, pass in
                guard pass.target == .cover else { return }
                table.setAddress(ground, index: ShadowBufferIndex.uniforms)
                table.setAddress(vertices, index: ShadowBufferIndex.vertices)
                self.drawGround(ranges, indices: indices, into: encoder)
            })
        }
        cover.encode(into: commandBuffer, frameSlot: frameSlot, batches: batches)
        coverDrawn = true
    }

    /// **The copies of one gathered set a frame draws** — placed props, or scattered ones: the draws in view added to
    /// ``prepared``, and per cascade the parts that cast, solid and cut out apart.
    private func prepare(_ gathered: ScatteredCopies, settings: WorldCopyField.Settings, view: InstanceBuffer,
                         shadows: [InstanceBuffer], hidden: Set<Int>) -> (solid: [[ShadowPart]], cut: [[ShadowPart]]) {
        let selection = gathered.field.select(settings)
        func batches(_ runs: WorldCopyField.Runs) -> InstanceBatches<CopyKey> {
            InstanceBatches(transforms: runs.transforms,
                            runs: runs.runs.map { (key: CopyKey(prop: $0.prop, level: $0.level), count: $0.count) })
        }
        let seen = batches(selection.visible)
        if let buffer = view.write(seen, frameSlot: frameSlot) {
            for batch in seen.batches where !hidden.contains(batch.key.prop) {
                let instances = (address: buffer.gpuAddress + UInt64(batch.byteOffset), count: batch.count)
                let foliage = foliageVector(for: gathered.urls[batch.key.prop])
                let sway = swayVector(for: gathered.urls[batch.key.prop], bounds: gathered.props[batch.key.prop].bounds)
                // Far copies as their picture, once it is baked; until then as the coarsest mesh, which the level past
                // every mesh level comes to.
                if batch.key.level == gathered.field.impostorLevel, let impostor = gathered.props[batch.key.prop].impostor,
                   impostor.isBaked {
                    let unit = simd_float4x4(translation: impostor.centre)
                        * simd_float4x4(diagonal: SIMD4(impostor.radius, impostor.radius, impostor.radius, 1))
                    guard let address = write(ObjectUniforms(model: unit, normalMatrix: matrix_identity_float4x4,
                                                             baseColour: SIMD4(1, 1, 1, 1), emissive: .zero,
                                                             params: SIMD4(impostor.roughness, 0, 0.5, 0),
                                                             foliage: foliage)) else { break }
                    preparedImpostors.append(ImpostorDraw(impostor: impostor, uniforms: address, instances: instances))
                    continue
                }
                // **A prop with a turning part is drawn whole at full detail** (a windmill is one of a few): what stays,
                // and what turns, turned.
                let turning = turningDraw(for: gathered.urls[batch.key.prop], prop: gathered.props[batch.key.prop])
                let (shownMeshes, tier) = turning == nil ? gathered.props[batch.key.prop].meshes(at: batch.key.level)
                    : (gathered.props[batch.key.prop].meshes, 0)
                let turn = turning?.part.transform(angle: turnAngle)
                var seeThrough = false
                let bare = Self.isBare(foliage)
                for (m, shown) in shownMeshes.enumerated() {
                    for submesh in shown.loaded.mesh.submeshes.indices {
                        // See-through submeshes are drawn copy by copy, in order (``sortSeeThrough()``).
                        if shown.seeThrough[submesh] { seeThrough = true; continue }
                        if bare, Self.isLeafMaterial(shown.material(submesh).name) { continue }
                        let stays = turning.map { $0.still[m][submesh] } ?? shown.indices(submesh: submesh, level: tier)
                        let sway = swayVector(for: gathered.urls[batch.key.prop], bounds: gathered.props[batch.key.prop].bounds,
                                              shown: shown, submesh: submesh)
                        if let stays {
                            guard let address = instancedUniforms(for: shown, submesh: submesh, foliage: foliage, sway: sway)
                            else { break }
                            var draw = PreparedDraw(mesh: shown.loaded.mesh, indices: stays,
                                                    uniforms: address, baseMap: shown.baseMaps[submesh],
                                                    glowMap: shown.glowMaps[submesh], instances: instances)
                            draw.grime = shown.grime(submesh)
                            prepared.append(draw)
                        }
                        if let goes = turning?.turning[m][submesh],
                           let address = instancedUniforms(for: shown, submesh: submesh, foliage: foliage, sway: sway, turn: turn) {
                            var draw = PreparedDraw(mesh: shown.loaded.mesh, indices: goes, uniforms: address,
                                                    baseMap: shown.baseMaps[submesh], glowMap: shown.glowMaps[submesh],
                                                    instances: instances)
                            draw.grime = shown.grime(submesh)
                            prepared.append(draw)
                        }
                    }
                }
                // **Snow built up on it** while snow lies, on the copies near enough to be drawn in full — not on grass,
                // reeds and bushes, a thicket of blades the white layer covers as well, at a fraction of the cost.
                if capsShown, batch.key.level == 0, sway.x != 2, let cap = snowCap(for: gathered.urls[batch.key.prop],
                                                                      meshes: gathered.props[batch.key.prop].meshes),
                   let address = write(ObjectUniforms(model: matrix_identity_float4x4, normalMatrix: matrix_identity_float4x4,
                                                      baseColour: SIMD4(0.82, 0.86, 0.92, 1), emissive: .zero,
                                                      params: SIMD4(0.85, snowLying * Self.snowCapDepth, 0, 0),
                                                      sway: SIMD4(sway.x, sway.y, sway.z, 1), wind: frameWind)) {
                    var draw = PreparedDraw(mesh: shownMeshes[0].loaded.mesh, indices: cap.indices, uniforms: address,
                                            baseMap: textures.white, glowMap: textures.white, instances: instances)
                    draw.snowCap = true
                    prepared.append(draw)
                }
                if seeThrough {
                    let centre = gathered.props[batch.key.prop].bounds.center
                    for transform in seen.transforms[batch.start..<(batch.start + batch.count)] {
                        let at = transform * SIMD4(centre, 1)
                        seeThroughCopies.append(SeeThroughCopy(meshes: shownMeshes, tier: tier, transform: transform,
                                                               centre: SIMD3(at.x, at.y, at.z)))
                    }
                }
            }
        }
        var solidParts: [[ShadowPart]] = [], cutParts: [[ShadowPart]] = []
        for (cascade, runs) in selection.cascades.enumerated() {
            let casting = batches(runs)
            var solid: [ShadowPart] = [], cut: [ShadowPart] = []
            if let buffer = shadows[cascade].write(casting, frameSlot: frameSlot) {
                for batch in casting.batches where !hidden.contains(batch.key.prop) {
                    let copies = (address: buffer.gpuAddress + UInt64(batch.byteOffset), count: batch.count)
                    let turning = turningDraw(for: gathered.urls[batch.key.prop], prop: gathered.props[batch.key.prop])
                    let (shownMeshes, tier) = turning == nil ? gathered.props[batch.key.prop].meshes(at: batch.key.level)
                        : (gathered.props[batch.key.prop].meshes, 0)
                    let turn = turning?.part.transform(angle: turnAngle)
                    let foliage = foliageVector(for: gathered.urls[batch.key.prop])
                    let sway = swayVector(for: gathered.urls[batch.key.prop], bounds: gathered.props[batch.key.prop].bounds)
                    // A tree that is thinning casts only the leaves it has: its solid canopy is cut by the mask too.
                    let thinning = Self.isThinning(foliage), bare = Self.isBare(foliage)
                    for (m, shown) in shownMeshes.enumerated() {
                        // Glass casts no shadow: light passes through it; a bare tree's leaves are not there.
                        for submesh in shown.loaded.mesh.submeshes.indices where !shown.seeThrough[submesh] {
                            if bare, Self.isLeafMaterial(shown.material(submesh).name) { continue }
                            let sway = swayVector(for: gathered.urls[batch.key.prop],
                                                  bounds: gathered.props[batch.key.prop].bounds, shown: shown, submesh: submesh)
                            var pieces: [(IndexRange, simd_float4x4?)] = []
                            if let stays = turning.map({ $0.still[m][submesh] }) ?? shown.indices(submesh: submesh, level: tier) {
                                pieces.append((stays, nil))
                            }
                            if let goes = turning?.turning[m][submesh] { pieces.append((goes, turn)) }
                            for (indices, turned) in pieces {
                                guard let address = instancedUniforms(for: shown, submesh: submesh, foliage: foliage,
                                                                      sway: sway, turn: turned) else { break }
                                let part = ShadowPart(mesh: shown.loaded.mesh, indices: indices,
                                                      uniforms: address, baseMap: shown.baseMaps[submesh], copies: copies)
                                if shown.cutoffs[submesh] > 0 || thinning { cut.append(part) } else { solid.append(part) }
                            }
                        }
                    }
                }
            }
            solidParts.append(solid)
            cutParts.append(cut)
        }
        return (solidParts, cutParts)
    }

    /// **The see-through copies in view, farthest from the eye first, one draw each** (Ductane's
    /// `InstanceBatches(farthestFirst:)`) — into ``preparedSeeThroughUnder`` when under a body of water, else
    /// ``preparedSeeThrough``.
    private func sortSeeThrough() {
        liquidsInView = false
        guard !seeThroughCopies.isEmpty else { return }
        refreshWaterSurface()
        let sorted = InstanceBatches(farthestFirst: seeThroughCopies.indices.map {
            (key: $0, transform: seeThroughCopies[$0].transform, centre: seeThroughCopies[$0].centre)
        }, from: camera.eye)
        guard let buffer = seeThroughTransforms.write(sorted, frameSlot: frameSlot) else { return }
        for batch in sorted.batches {
            let copy = seeThroughCopies[batch.key]
            let instances = (address: buffer.gpuAddress + UInt64(batch.byteOffset), count: 1)
            let under = isUnderWater(copy.centre)
            for shown in copy.meshes {
                for submesh in shown.loaded.mesh.submeshes.indices where shown.seeThrough[submesh] {
                    guard let address = instancedUniforms(for: shown, submesh: submesh) else { break }
                    var draw = PreparedDraw(mesh: shown.loaded.mesh, indices: shown.indices(submesh: submesh, level: copy.tier),
                                            uniforms: address, baseMap: shown.baseMaps[submesh],
                                            glowMap: shown.glowMaps[submesh], instances: instances)
                    draw.grime = shown.grime(submesh)
                    if let liquid = shown.liquid(submesh) {
                        draw.liquid = (liquid, liquidUniforms(liquid))
                        liquidsInView = true
                    }
                    if under { preparedSeeThroughUnder.append(draw) }
                    else if draw.liquid != nil { preparedLiquids.append(draw) } else { preparedSeeThrough.append(draw) }
                }
            }
        }
    }

    /// **Whether a liquid is in view this frame** — then the scene is drawn in two passes, the second reading the
    /// first's depth (``wantsOpaqueTextures``); otherwise in one, as before liquids, at no cost.
    private var liquidsInView = false
    public var wantsOpaqueTextures: Bool { liquidsInView || (drawsEffects && effects.softens) || waterReflects }
    /// Only the solid depth is read — by the liquids and the soft particles — so the colour is not copied.
    public var wantsOpaqueColour: Bool { waterReflects }

    /// **Whether the water mirrors the scene this frame** (``GraphicsSettings/reflections``): reflections on and water in
    /// the scene. Then the solid pass's colour is kept as well as its depth, and the water and streams march across it
    /// (`reflectedScene` in `WorldShaders.metal`); off, they reflect the sky alone, at no cost. About 2–4 ms with a pond
    /// filling a large view.
    public var waterReflects: Bool {
        graphicsSettings.reflections && (!scene.waters.isEmpty || !scene.streams.isEmpty)
    }
    /// The solid pass's colour and depth while the second pass draws, for the water to reflect.
    private var solidForReflections: OpaqueTextures?

    /// A frame's liquid uniforms, one slot per look per frame in flight.
    private lazy var liquidBuffer: MTLBuffer = {
        let buffer = device.makeBuffer(length: Self.liquidCapacity * FrameRenderer.maxFramesInFlight
                                       * MemoryLayout<LiquidUniforms>.stride, options: .storageModeShared)!
        buffer.label = "Liquid Uniforms"
        engine.residencySet.addAllocation(buffer)
        engine.commitResidency()
        return buffer
    }()

    /// Writes a look's uniforms for this frame — its numbers, the camera's near plane, the clock — and returns where.
    private func liquidUniforms(_ liquid: LiquidLook) -> UInt64 {
        // Reversed-Z with no far plane: depth = near ÷ distance, the near plane in the projection's last column.
        let near = camera.projectionMatrix(aspectRatio: aspectRatio).columns.3.z
        var uniforms = LiquidUniforms(liquid.look, near: near, time: streamTime)
        let offset = ((frameSlot % FrameRenderer.maxFramesInFlight) * Self.liquidCapacity + liquid.index)
            * MemoryLayout<LiquidUniforms>.stride
        liquidBuffer.contents().advanced(by: offset).copyMemory(from: &uniforms, byteCount: MemoryLayout<LiquidUniforms>.stride)
        return liquidBuffer.gpuAddress + UInt64(offset)
    }

    // MARK: Placed props, gathered as copies

    /// Every placement whose prop is loaded, as a copy in its own ``ScatteredCopies`` — its own props and cells, apart
    /// from the scattered ones, so a drag on either rebuilds only its own. One group: ``ScatteredCopies/slots``[0] is
    /// each placement's copy.
    private var placedCopies: ScatteredCopies?
    private lazy var placedTransforms = InstanceBuffer(renderer: engine)
    /// One more than the cascades: the last is the weather's cover's.
    private lazy var placedShadowTransforms = (0...Self.cascades(reaching: 0).count).map { _ in InstanceBuffer(renderer: engine) }

    private static func copy(_ placement: WorldScene.Placement, of prop: Int, bounds: BoundingBox) -> WorldCopyField.Copy {
        let transform = placement.transform
        let box = bounds.transformed(by: transform)
        return .init(transform: transform, minimum: box.minimum, maximum: box.maximum, scale: placement.scale, prop: prop)
    }

    private func gatherPlacedCopies() -> ScatteredCopies {
        arrivedForPlaced = []
        litterStale = true
        var gathered = ScatteredCopies()
        var slots = [Int](repeating: -1, count: scene.placements.count)
        for (i, placement) in scene.placements.enumerated() {
            // What rolls in the wind is drawn apart, where it has rolled to (``rolling``).
            if swayKind(of: placement.prop) == .rolls { continue }
            guard let prop = placedIndex(of: placement, in: &gathered) else { continue }
            slots[i] = gathered.copies.count
            gathered.copies.append(Self.copy(placement, of: prop, bounds: gathered.props[prop].bounds))
        }
        gathered.slots = [slots]
        gathered.layOut()
        placedCopies = gathered
        placedGeneration += 1
        return gathered
    }

    // MARK: Placements in other materials

    /// A prop and the materials a placement wears on it — one batch of copies for each.
    private struct LookKey: Hashable { let prop: URL; let materials: [String: WorldScene.Worn] }

    /// A placement's prop as it is drawn — its own, or dressed in what it wears — and its place in `gathered`.
    private func placedIndex(of placement: WorldScene.Placement, in gathered: inout ScatteredCopies) -> Int? {
        guard !placement.materials.isEmpty else { return gathered.propIndex(of: placement.prop, in: props) }
        let key = LookKey(prop: placement.prop, materials: placement.materials)
        if let known = gathered.looks[key] { return known }
        guard let plain = props[placement.prop] else { return nil }
        let prop = dressed(plain, wearing: placement.materials) ?? plain
        gathered.props.append(prop)
        gathered.urls.append(placement.prop)
        gathered.errors.append(prop.detailErrors)
        gathered.triangles.append(prop.levelTriangles)
        gathered.impostorPixels.append(0)
        gathered.looks[key] = gathered.props.count - 1
        return gathered.props.count - 1
    }

    /// What a chosen material is drawn with, taken from a submesh of the file that defines it.
    private struct Worn {
        let baseMap: MTLTexture
        let glowMap: MTLTexture
        let cutoff: Float
        let seeThrough: Bool
        let material: Ductane.Material
        /// The grime the material carries in its own file.
        var grime: GrungeLook? = nil
    }

    /// A material's name as a prop file names it: the last part of its prim path.
    nonisolated static func materialName(_ material: Ductane.Material) -> String {
        material.name.split(separator: "/").last.map(String.init) ?? material.name
    }

    /// **A prop dressed in the materials a placement wears** (2026-10-31, `WorldScene.Placement.materials`): each submesh whose
    /// material is replaced, drawn in the chosen one — its maps, its cut-out, whether it is see-through, its numbers —
    /// from a submesh of the file that defines it (a prop of the pack, or its library's swatch). The geometry is the
    /// prop's own, shared. Nil when nothing changes, or what it wears is not loaded yet: drawn in its own until then.
    private func dressed(_ prop: PropMeshes, wearing materials: [String: WorldScene.Worn]) -> PropMeshes? {
        var worn: [String: Worn] = [:]
        for (replaced, choice) in materials {
            guard let source = props[choice.file] else { continue }
            search: for shown in source.meshes {
                for submesh in shown.loaded.mesh.submeshes.indices where Self.materialName(shown.material(submesh)) == choice.name {
                    worn[replaced] = Worn(baseMap: shown.baseMaps[submesh], glowMap: shown.glowMaps[submesh],
                                          cutoff: shown.cutoffs[submesh], seeThrough: shown.seeThrough[submesh],
                                          material: shown.material(submesh), grime: shown.grime(submesh))
                    break search
                }
            }
        }
        guard !worn.isEmpty else { return nil }
        let look = lookNumbers[materials] ?? {
            lookNumbers[materials] = lookNumbers.count + 1
            return lookNumbers.count
        }()
        func dress(_ shown: ShownMesh) -> ShownMesh {
            let count = shown.loaded.mesh.submeshes.count
            let each = (0..<count).map { worn[Self.materialName(shown.material($0))] }
            guard each.contains(where: { $0 != nil }) else { return shown }
            return ShownMesh(loaded: shown.loaded,
                             baseMaps: (0..<count).map { each[$0]?.baseMap ?? shown.baseMaps[$0] },
                             glowMaps: (0..<count).map { each[$0]?.glowMap ?? shown.glowMaps[$0] },
                             cutoffs: (0..<count).map { each[$0]?.cutoff ?? shown.cutoffs[$0] },
                             seeThrough: (0..<count).map { each[$0]?.seeThrough ?? shown.seeThrough[$0] },
                             materials: (0..<count).map { each[$0]?.material ?? shown.material($0) },
                             look: look,
                             liquids: shown.liquids.isEmpty ? [] : (0..<count).map { each[$0] == nil ? shown.liquid($0) : nil },
                             grunge: (0..<count).map { each[$0].map(\.grime) ?? shown.grime($0) },
                             detail: shown.detail, detailBuffer: shown.detailBuffer)
        }
        var out = PropMeshes(meshes: prop.meshes.map(dress), bounds: prop.bounds, detailErrors: prop.detailErrors)
        out.levels = prop.levels.map { $0.map(dress) }
        out.levelTriangles = prop.levelTriangles
        return out
    }

    /// One number for each set of materials placements wear, kept while the window is open.
    private var lookNumbers: [[String: WorldScene.Worn]: Int] = [:]

    /// Adds the placements of props just loaded to the gathered ones.
    private func addPlacedCopies(of urls: Set<URL>) {
        guard var gathered = placedCopies, gathered.slots.count == 1, gathered.slots[0].count == scene.placements.count
        else { placedCopies = nil; return }
        // A file a placement wears a material from, arriving, changes how copies already gathered look: all again.
        if scene.placements.contains(where: { $0.materials.values.contains { urls.contains($0.file) } }) {
            placedCopies = nil
            return
        }
        for (i, placement) in scene.placements.enumerated() where urls.contains(placement.prop) {
            guard let prop = placedIndex(of: placement, in: &gathered) else { continue }
            gathered.slots[0][i] = gathered.copies.count
            gathered.copies.append(Self.copy(placement, of: prop, bounds: gathered.props[prop].bounds))
        }
        gathered.layOut()
        placedCopies = gathered
    }

    /// Updates the placements a drag changed, in place, when the placements are otherwise as they were. False when they
    /// are not — one added, deleted, or another prop — and every placement is gathered again.
    private func updatePlacedCopies(from old: [WorldScene.Placement]) -> Bool {
        guard var gathered = placedCopies, old.count == scene.placements.count, gathered.slots.count == 1,
              gathered.slots[0].count == old.count else { return false }
        var changed = false
        for (i, (before, now)) in zip(old, scene.placements).enumerated() where before != now {
            guard before.id == now.id, before.prop == now.prop, before.materials == now.materials else { return false }
            let slot = gathered.slots[0][i]
            guard slot >= 0 else { continue }
            let prop = gathered.copies[slot].prop
            gathered.copies[slot] = Self.copy(now, of: prop, bounds: gathered.props[prop].bounds)
            changed = true
        }
        if changed { gathered.layOut(); placedGeneration += 1 }
        placedCopies = gathered
        return true
    }

    /// One submesh to cast a shadow: placed once, or as scattered copies.
    private struct ShadowPart {
        let mesh: MTKMesh
        let indices: IndexRange
        let uniforms: UInt64
        let baseMap: MTLTexture
        let copies: (address: UInt64, count: Int)?
    }

    /// Draws shadow casters into a cascade. **A cut-out part also binds its map on the fragment stage** — the shadow
    /// pass binds only the vertex stage — **and is drawn from both sides**: the pass culls front faces against acne,
    /// and a leaf card is a single polygon, so half the leaves facing the sun would cast nothing.
    private static func draw(_ parts: [ShadowPart], into encoder: MTL4RenderCommandEncoder, table: MTL4ArgumentTable,
                             cutOut fragments: MTL4ArgumentTable? = nil) {
        if let fragments {
            encoder.setArgumentTable(fragments, stages: .fragment)
            encoder.setCullMode(.none)
        }
        for part in parts {
            table.setAddress(part.uniforms, index: ShadowBufferIndex.uniforms)
            if let copies = part.copies { table.setAddress(copies.address, index: ShadowBufferIndex.instances) }
            part.indices.bindVertices(of: part.mesh, to: table)
            if let fragments {
                fragments.setAddress(part.uniforms, index: 1)
                fragments.setTexture(part.baseMap.gpuResourceID, index: 0)
            }
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: part.indices.count,
                                          indexType: part.indices.type, indexBuffer: part.indices.address,
                                          indexBufferLength: part.indices.length, instanceCount: part.copies?.count ?? 1)
        }
        if fragments != nil { encoder.setCullMode(.front) }
    }

    /// One set of uniforms per scattered prop's mesh and submesh, per frame — shared by the view and every
    /// cascade, written the first time it is asked for.
    private func instancedUniforms(for shown: ShownMesh, submesh: Int, foliage: SIMD4<Float> = .zero,
                                   sway: SIMD4<Float> = .zero, turn: simd_float4x4? = nil) -> UInt64? {
        let key = InstancedKey(mesh: ObjectIdentifier(shown.loaded.mesh), submesh: submesh, look: shown.look, foliage: foliage.x,
                               sway: sway.x, turns: turn != nil)
        if let address = instancedUniformCache[key] { return address }
        let material = shown.material(submesh)
        // The mesh's own place in its prop; each copy's transform goes on top in the shader.
        // emissive.w: 1 for a submesh that is a tree's leaves alone, which shrink away rather than drop pixel by pixel.
        let leaf: Float = (foliage.x == 1 || sway.x == 1) && Self.isLeafMaterial(material.name) ? 1 : 0
        // A turning part goes round its hub in the prop's space, after its node has put it there.
        let address = write(ObjectUniforms(model: (turn ?? matrix_identity_float4x4) * shown.loaded.nodeTransform,
                                           normalMatrix: matrix_identity_float4x4,
                                           baseColour: material.baseColor, emissive: SIMD4(material.emissive * 4, leaf),
                                           params: SIMD4(material.roughness, material.metallic, shown.cutoffs[submesh], 0),
                                           foliage: foliage, sway: sway, wind: frameWind))
        instancedUniformCache[key] = address
        return address
    }

    /// Pixels across, on screen, below which a scattered copy is not drawn: a speck nobody can see is still a draw.
    static let smallestDrawn: Float = 3
    /// Pixels across below which a copy casts no shadow — its shadow would be a smudge of a few texels.
    static let smallestCaster: Float = 80

    private struct InstancedKey: Hashable {
        let mesh: ObjectIdentifier; let submesh: Int; let look: Int; let foliage: Float; let sway: Float; let turns: Bool
    }
    /// Scattered copies are batched by prop and level of detail.
    private nonisolated struct CopyKey: Hashable, Sendable { let prop: Int; let level: Int }

    /// Every scattered copy whose prop is loaded, with what does not change frame to frame worked out once —
    /// its transform and box — and laid out in cells (``WorldCopyField``). Rebuilt when the scattered props or the
    /// loaded props change; with thousands of copies, deriving these each frame was most of the frame.
    private struct ScatteredCopies {
        var props: [PropMeshes] = []
        /// Each prop's file, beside ``props`` — what the season does to it (``foliageVector(for:)``).
        var urls: [URL] = []
        /// Each prop's `detailErrors`.
        var errors: [[Float]] = []
        var copies: [WorldCopyField.Copy] = []
        /// Each gathered prop's place in ``props``.
        var index: [URL: Int] = [:]
        /// Each prop dressed in other materials (``dressed(_:wearing:)``), by prop and materials, and its place in ``props``.
        var looks: [LookKey: Int] = [:]
        /// ``copies`` in cells, for choosing what to draw.
        var field = WorldCopyField(copies: [], errors: [])
        /// Per scatter group, per copy, where it is in ``copies`` — -1 for a copy whose prop is not loaded.
        var slots: [[Int]] = []

        /// Each prop's `levelTriangles`.
        var triangles: [[Int]] = []
        /// Each prop's far picture's ``Impostor/drawnUnder``, 0 where it has none — and for every placed prop.
        var impostorPixels: [Float] = []

        mutating func layOut() {
            field = WorldCopyField(copies: copies, errors: errors, triangles: triangles, impostorPixels: impostorPixels)
        }

        /// A loaded prop's place in ``props``, added the first time it is asked for; `nil` while it is not loaded.
        mutating func propIndex(of url: URL, in loaded: [URL: PropMeshes]) -> Int? {
            if let known = index[url] { return known }
            guard let prop = loaded[url] else { return nil }
            props.append(prop)
            urls.append(url)
            errors.append(prop.detailErrors)
            triangles.append(prop.levelTriangles)
            impostorPixels.append(0)   // placed: never a far picture
            index[url] = props.count - 1
            return props.count - 1
        }
    }

    private var scatteredCopies: ScatteredCopies?

    /// A scattered prototype's place in `gathered` — its prop, or its prop in its look (`WorldScene.Scatter.looks`) — added the
    /// first time it is asked for; nil while its prop is not loaded.
    private func scatteredIndex(of url: URL, wearing look: [String: WorldScene.Worn],
                                in gathered: inout ScatteredCopies) -> Int? {
        let key = LookKey(prop: url, materials: look)
        if look.isEmpty, let known = gathered.index[url] { return known }
        if !look.isEmpty, let known = gathered.looks[key] { return known }
        guard let prop = scatteredProp(url, wearing: look) else { return nil }
        gathered.props.append(prop)
        gathered.urls.append(url)
        gathered.errors.append(prop.detailErrors)
        gathered.triangles.append(prop.levelTriangles)
        gathered.impostorPixels.append(prop.impostor?.drawnUnder ?? 0)
        if look.isEmpty { gathered.index[url] = gathered.props.count - 1 } else { gathered.looks[key] = gathered.props.count - 1 }
        return gathered.props.count - 1
    }

    /// Adds the copies of props just loaded to the gathered ones.
    private func addScatteredCopies(of urls: Set<URL>) {
        guard var gathered = scatteredCopies else { return }
        // A file a prototype wears a material from, arriving, changes how copies already gathered look: all again.
        if scene.scatters.contains(where: { $0.wornFiles.contains(where: urls.contains) }) {
            scatteredCopies = nil
            return
        }
        for (g, scatter) in scene.scatters.enumerated() {
            for (k, url) in scatter.prototypes.enumerated() where urls.contains(url) {
                guard let index = scatteredIndex(of: url, wearing: scatter.look(of: k), in: &gathered) else { continue }
                let bounds = gathered.props[index].bounds
                for (i, copy) in scatter.copies.enumerated() where copy.prototype == k {
                    if gathered.slots.indices.contains(g), gathered.slots[g].indices.contains(i) {
                        gathered.slots[g][i] = gathered.copies.count
                    }
                    gathered.copies.append(Self.copy(copy, of: index, bounds: bounds))
                }
            }
        }
        gathered.layOut()
        scatteredCopies = gathered
    }

    /// Hands over scattered copies that moved in place — a sculpting stroke carrying them with the ground — naming which,
    /// so only those are placed again. Finding them by comparing all 48,000 of a wooded zone's was 11 ms of a Debug frame.
    public func moveScatteredCopies(_ moves: [(group: Int, index: Int)], in scatters: [WorldScene.Scatter]) {
        knownMoves = moves
        scene.scatters = scatters
    }
    private var knownMoves: [(group: Int, index: Int)]?

    /// Places `moves` again from the scene's copies. False when the gathered copies do not match the scene's groups.
    private func placeAgain(_ moves: [(group: Int, index: Int)]) -> Bool {
        guard var gathered = scatteredCopies, gathered.slots.count == scene.scatters.count else { return false }
        for (g, i) in moves {
            guard gathered.slots[g].count == scene.scatters[g].copies.count else { return false }
            let slot = gathered.slots[g][i]
            guard slot >= 0 else { continue }
            let prop = gathered.copies[slot].prop
            gathered.copies[slot] = Self.copy(scene.scatters[g].copies[i], of: prop, bounds: gathered.props[prop].bounds)
        }
        if !moves.isEmpty { gathered.layOut() }
        scatteredCopies = gathered
        return true
    }

    /// Updates the copies a drag changed, in place, when the groups are otherwise as they were. False when they are not —
    /// a stroke, an erase, an undo — and every copy has to be gathered again.
    private func updateScatteredCopies(from old: [WorldScene.Scatter]) -> Bool {
        guard var gathered = scatteredCopies, old.count == scene.scatters.count, gathered.slots.count == old.count
        else { return false }
        var changed = false
        for (g, (before, now)) in zip(old, scene.scatters).enumerated() {
            guard before.id == now.id, before.prototypes == now.prototypes, before.looks == now.looks,
                  before.copies.count == now.copies.count, gathered.slots[g].count == now.copies.count
            else { return false }
            for i in now.copies.indices where before.copies[i] != now.copies[i] {
                let copy = now.copies[i]
                guard copy.prototype == before.copies[i].prototype else { return false }
                let slot = gathered.slots[g][i]
                guard slot >= 0 else { continue }
                let prop = gathered.copies[slot].prop
                gathered.copies[slot] = Self.copy(copy, of: prop, bounds: gathered.props[prop].bounds)
                changed = true
            }
        }
        if changed { gathered.layOut() }
        scatteredCopies = gathered
        return true
    }

    private static func copy(_ copy: WorldScene.Copy, of prop: Int, bounds: BoundingBox) -> WorldCopyField.Copy {
        let transform = copy.transform
        let box = bounds.transformed(by: transform)
        return .init(transform: transform, minimum: box.minimum, maximum: box.maximum, scale: copy.scale, prop: prop)
    }

    // MARK: Rolling in the wind

    /// **The copies of props that roll in the wind** (``Sway/rolls`` — a tumbleweed), gathered apart from what stands, with
    /// each one's transform as placed; again whenever the scene's copies or choices change, or props arrive.
    private var rolling: (copies: ScatteredCopies, bases: [simd_float4x4])?
    private var rollingStale = true
    private var rollingLoadedCount = -1
    /// How far everything that rolls has gone, metres — stepped by the wind's speed, never worked out from a clock.
    private var rollDistance: Float = 0
    /// The way the wind last blew, flat; and how fast what rolls is going now.
    private var rollHeading = SIMD2<Float>(0, -1)
    private var rollSpeed: Float = 0
    /// Counts gatherings of the placed copies, so what rolling copies snag on is found again when they change.
    private var placedGeneration = 0
    /// Per rolling copy, where along its way it meets something solid — found for one heading and one set of placed copies.
    private var rollingSnags: (heading: SIMD2<Float>, generation: Int, count: Int, intervals: [[(enter: Float, exit: Float)]])?
    private lazy var rollingTransforms = InstanceBuffer(renderer: engine)
    private lazy var rollingShadowTransforms = (0...Self.cascades(reaching: 0).count).map { _ in InstanceBuffer(renderer: engine) }

    /// **How fast a tumbleweed rolls in a wind**, metres a second: still below a fresh breeze, about 6 m/s in a 20 m/s gale.
    nonisolated static func rollSpeed(windSpeed: Float) -> Float { max(windSpeed - 5, 0) * 0.4 }
    /// **How far one rolls before coming round again upwind of where it was placed**, shrinking away over its last metres
    /// and growing back at the start — so a field of them keeps rolling past a place for as long as the wind blows.
    nonisolated static let rollLoop: Float = 90

    private func gatherRollingCopies() -> (copies: ScatteredCopies, bases: [simd_float4x4]) {
        var gathered = ScatteredCopies()
        for placement in scene.placements where swayKind(of: placement.prop) == .rolls {
            guard let prop = placedIndex(of: placement, in: &gathered) else { continue }
            gathered.copies.append(Self.copy(placement, of: prop, bounds: gathered.props[prop].bounds))
        }
        for scatter in scene.scatters {
            let rolls = scatter.prototypes.map { swayKind(of: $0) == .rolls }
            guard rolls.contains(true) else { continue }
            let prototypes = scatter.prototypes.enumerated().map { k, url in
                rolls[k] ? scatteredIndex(of: url, wearing: scatter.look(of: k), in: &gathered) : nil
            }
            for copy in scatter.copies where copy.prototype < prototypes.count && rolls[copy.prototype] {
                guard let prop = prototypes[copy.prototype] else { continue }
                gathered.copies.append(Self.copy(copy, of: prop, bounds: gathered.props[prop].bounds))
            }
        }
        gathered.layOut()
        return (gathered, gathered.copies.map(\.transform))
    }

    /// **Every rolling copy where the wind has taken it this frame**, or nil when nothing rolls. Each rolls its own pace
    /// and hops its own length, from where it stands, spinning as it goes over the ground; it stops against anything solid
    /// placed in its way — rocking there — and settles where it is when the wind drops.
    private func rolledCopies() -> ScatteredCopies? {
        if rolling == nil || rollingStale || rollingLoadedCount != props.count {
            rolling = gatherRollingCopies()
            rollingStale = false
            rollingLoadedCount = props.count
            rollingSnags = nil
        }
        guard var (gathered, bases) = rolling, !bases.isEmpty else { return nil }
        let heading = rollHeading, loop = Self.rollLoop
        let way = SIMD3(heading.x, 0, heading.y)
        let axis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), way))
        // What each copy meets on its way: placed things a hand's height or more, for this heading.
        let generation = placedGeneration
        if rollingSnags == nil || rollingSnags!.generation != generation || rollingSnags!.count != bases.count
            || simd_dot(rollingSnags!.heading, heading) < 0.9986 {
            let solids = (placedCopies?.copies ?? []).filter { $0.maximum.y - $0.minimum.y >= 0.4 }
            let intervals: [[(enter: Float, exit: Float)]] = gathered.copies.indices.map { i in
                let box = gathered.props[gathered.copies[i].prop].bounds
                let base = bases[i]
                let centre = base * SIMD4(box.center, 1)
                let r = simd_reduce_max(box.size) / 2 * WorldScene.largestScale(of: base) * 0.8
                let home = SIMD2(centre.x, centre.z)
                return solids.compactMap { solid -> (enter: Float, exit: Float)? in
                    // The way through the solid's footprint, grown by the rolling copy's size: slabs in x and z.
                    var enter = -Float.greatestFiniteMagnitude, exit = Float.greatestFiniteMagnitude
                    for k in 0..<2 {
                        let lo = (k == 0 ? solid.minimum.x : solid.minimum.z) - r, hi = (k == 0 ? solid.maximum.x : solid.maximum.z) + r
                        let o = k == 0 ? home.x : home.y, d = k == 0 ? heading.x : heading.y
                        if abs(d) < 1e-5 {
                            if o < lo || o > hi { return nil }
                        } else {
                            let a = (lo - o) / d, b = (hi - o) / d
                            enter = max(enter, min(a, b)); exit = min(exit, max(a, b))
                        }
                    }
                    return enter < exit ? (enter, exit) : nil
                }.sorted { $0.enter < $1.enter }
            }
            rollingSnags = (heading, generation, bases.count, intervals)
        }
        let snags = rollingSnags!.intervals
        let going = rollSpeed
        for i in gathered.copies.indices {
            let base = bases[i]
            let box = gathered.props[gathered.copies[i].prop].bounds
            let centre4 = base * SIMD4(box.center, 1)
            let centre0 = SIMD3(centre4.x, centre4.y, centre4.z)
            let r = max(simd_reduce_max(box.size) / 2 * WorldScene.largestScale(of: base), 0.05)
            // Its own pace, start and hop, from where it was put.
            // From the bits of where it stands — never a float turned into an integer, which traps on one too large.
            var h = centre0.x.bitPattern &* 2654435761 ^ centre0.z.bitPattern &* 2246822519
            func next() -> Float { h ^= h >> 15; h = h &* 0x2C1B3C6D; h ^= h >> 12; return Float(h & 0xFFFF) / 65535 }
            let pace = 0.75 + 0.5 * next(), phase = 0.15 + 0.7 * next(), hop = 1.6 + 1.6 * next(), wobble = next() * 6.28
            let s = rollDistance * pace + phase * loop
            let lap = (s / loop).rounded(.down)
            let along = s - lap * loop
            var travel = along - phase * loop
            // Stopped by the first thing it meets since this lap began — at its home on the first, upwind after.
            let start: Float = lap < 1 ? 0 : -phase * loop
            var pinned = false
            if let first = snags[i].first(where: { $0.exit > start && $0.enter >= start - 0.01 }), travel > first.enter {
                travel = first.enter
                pinned = true
            }
            let fade = rollDistance > 0 ? Self.smooth(0, 3, along) * Self.smooth(loop, loop - 3, along) : 1
            let place = SIMD2(centre0.x, centre0.z) + heading * travel
            let groundAtHome = groundHeight(x: centre0.x, z: centre0.z, holes: false) ?? (centre0.y - r)
            let ground = groundHeight(x: place.x, z: place.y, holes: false) ?? groundAtHome
            let bounce = pinned ? 0 : r * 0.5 * abs(sin(.pi * travel / hop)) * min(going / 3, 1)
            let centre = SIMD3(place.x, ground + (centre0.y - groundAtHome) + bounce, place.y)
            var angle = travel / r
            if pinned { angle += sin(rollDistance * 2.5 + wobble) * 0.12 * min(going / 3, 1) }
            let transform = simd_float4x4(translation: centre) * simd_float4x4(simd_quatf(angle: angle, axis: axis))
                * simd_float4x4(diagonal: SIMD4(fade, fade, fade, 1)) * simd_float4x4(translation: -centre0) * base
            let moved = box.transformed(by: transform)
            gathered.copies[i] = WorldCopyField.Copy(transform: transform, minimum: moved.minimum, maximum: moved.maximum,
                                                     scale: gathered.copies[i].scale * fade, prop: gathered.copies[i].prop)
        }
        gathered.layOut()
        return gathered
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func gatherScatteredCopies() -> ScatteredCopies {
        arrivedForScattered = []
        litterStale = true
        var gathered = ScatteredCopies()
        for scatter in scene.scatters {
            let prototypes = scatter.prototypes.enumerated().map { k, url in
                scatteredIndex(of: url, wearing: scatter.look(of: k), in: &gathered)
            }
            var slots = [Int](repeating: -1, count: scatter.copies.count)
            let rolls = scatter.prototypes.map { swayKind(of: $0) == .rolls }
            for (i, copy) in scatter.copies.enumerated() where copy.prototype < prototypes.count {
                if rolls[copy.prototype] { continue }
                guard let prop = prototypes[copy.prototype] else { continue }
                slots[i] = gathered.copies.count
                gathered.copies.append(Self.copy(copy, of: prop, bounds: gathered.props[prop].bounds))
            }
            gathered.slots.append(slots)
        }
        gathered.layOut()
        scatteredCopies = gathered
        return gathered
    }

    /// The level of detail for something of `prop`'s at `box` in the scene, `scale` times its own size: the
    /// coarsest whose error is under half a pixel from the camera (`MeshDetail.coarsestTier`). 0 is the full mesh.
    private func detailLevel(of prop: PropMeshes, at box: BoundingBox, scale: Float) -> Int {
        let radius = simd_length(box.maximum - box.minimum) / 2
        let distance = simd_distance(camera.eye, box.center) - radius
        // A prop with its own levels is levelled by its size on screen (`WorldCopyField.ownLevel`).
        if !prop.levels.isEmpty {
            if let forcedDetailLevel { return min(forcedDetailLevel, prop.levels.count) }
            let pixels = 2 * radius * Float(viewportHeight) / camera.fieldOfView / max(distance, 0.5)
            return WorldCopyField.ownLevel(triangles: prop.levelTriangles, pixels: pixels)
        }
        guard !prop.detailErrors.isEmpty, forcedDetailLevel == nil else {
            return min(forcedDetailLevel ?? 0, prop.detailErrors.count)
        }
        return MeshDetail.coarsestTier(errors: prop.detailErrors, distance: distance, scale: scale,
                               pixelsPerRadian: Float(viewportHeight) / camera.fieldOfView)
    }

    /// Draws every prop at this level, or its coarsest — to see what a level looks like.
    public var forcedDetailLevel: Int?
    /// Whether far copies are drawn as far pictures — off to compare with the meshes.
    public var drawsFarPictures = true
    /// **How clouds are drawn**: as graphics quality says, a quality of its own, or none — to
    /// measure what they cost.
    public enum CloudsAsked: Equatable, Sendable {
        case settings, none, quality(GraphicsSettings.CloudQuality)
        var quality: GraphicsSettings.CloudQuality? { if case .quality(let q) = self { q } else { nil } }
    }
    public var cloudsAsked = CloudsAsked.settings
    /// Whether foliage follows the season — off to measure what it costs.
    public var drawsFallColors = true
    private var instancedUniformCache: [InstancedKey: UInt64] = [:]
    /// The scattered copies each sun cascade can see, a buffer per cascade per frame in flight.
    private lazy var shadowTransforms = (0...Self.cascades(reaching: 0).count).map { _ in InstanceBuffer(renderer: engine) }

    private func writeFrame(frameSlot: Int, light: DaySky.Lighting, cascades: [simd_float4x4], casting: Bool,
                            covering: Bool) {
        let viewProjection = self.viewProjection
        // **A little of the eye's adjustment to the dark**: night is shown darker, not black — a scene has
        // to be judgeable at any hour — so exposure opens up as the light falls, by at most three stops. By the hour's
        // light, not the weather's (``Weather/exposureStops(under:clear:)``).
        engine.toneMapping.exposureStops = Weather.exposureStops(under: light, clear: frameDaySky.lighting)
        // The grid follows the camera's target, sized to how far out the camera is.
        let reach = max(camera.distance * 12, 60)
        let c = shadowMap?.cascades ?? Self.cascades(reaching: 0)
        var frame = FrameUniforms(
            viewProjection: viewProjection,
            inverseViewProjection: viewProjection.inverse,
            // w: 1 while the grid is shown (``showsGrid``) — the ground's lines read it (`propFragment`).
            cameraPosition: SIMD4(camera.eye, showsGrid ? 1 : 0),
            // w: the near plane while the water reflects the scene, read by `reflectedScene`; 0, the sky alone.
            sunDirection: SIMD4(light.direction, waterReflects ? camera.projectionMatrix(aspectRatio: aspectRatio).columns.3.z : 0),
            sunColour: SIMD4(light.colour, 0),
            skyColour: SIMD4(light.skyLight, 0),
            horizonColour: SIMD4(light.horizon, 0),
            groundColour: SIMD4(light.ground, 0),
            grid: SIMD4(reach, camera.target.x.rounded(), camera.target.z.rounded(), reach),
            cascadeViewProjection: (cascades[0], cascades[1], cascades[2], cascades[3]),
            cascadeSplits: c.splitVector,
            cascadeBlendStart: c.blendStartVector,
            cascadeDepthBias: c.depthBiasVector,
            // w: 1 when the scene is multisampled, so a cut-out edge becomes coverage (`propFragment`).
            shadowParams: SIMD4(1 / Float(c.resolution), casting ? 1 : 0, 0, engine.effectiveSampleCount > 1 ? 1 : 0),
            // The fog starts where the view looks (`fogged` in WorldShaders.metal): a walk's orbit is a metre long.
            fogParams: SIMD4(frameWeather.fogDensity(over: scene.sky.fogDensity), camera.distance, scene.groundGrain, 0),
            weather: WeatherSurface(
                weather: frameWeather, snowDepth: graphics.snowDepth, cover: weatherCover, coverDrawn: covering,
                footprints: footprintGrid, printsDrawn: footprintsDrawn, time: weatherTime, clouds: frameClouds?.layer,
                fall: frameFall.map { (colors: $0.fall, phase: $0.phase) }, litterBound: litterFieldBuffer != nil))
        // The surfaces drawn with the weather compiled in only when it lays something on them (``surfaces``).
        drawsWeatherOnGround = frame.weather.laysOnSurfaces
        drawsWeatherOnProps = frame.weather.laysOnProps
        drawsSeasonsOnFoliage = frameFall.map { FallColors.changesAnything(phase: $0.phase) } ?? false
        let slot = frameBuffer.contents().advanced(by: frameSlot * Self.frameStride)
        slot.copyMemory(from: &frame, byteCount: MemoryLayout<FrameUniforms>.stride)
        // The lights nearest the view — the orbit's target when looking down, the walker's eye when walking.
        let lit = WorldScene.Light.nearest(scene.lights(at: weatherTime), to: camera.target, radius: max(camera.distance, 60), limit: Self.lightLimit)
        let lights = slot.advanced(by: MemoryLayout<FrameUniforms>.stride).bindMemory(to: SIMD4<Float>.self,
                                                                                    capacity: 2 + Self.lightLimit * 2)
        lights[0] = SIMD4(Float(lit.count), 0, 0, 0)
        // The ground's shape, for the shader to read heights out of its vertices (bound at 4): what is under it.
        if let shape = terrainShape, !terrainVertices.isEmpty {
            lights[1] = SIMD4(shape.size / 2, shape.size / Float(shape.resolution), Float(shape.resolution + 1), 0)
        } else {
            lights[1] = .zero
        }
        for (i, light) in lit.enumerated() {
            lights[2 + i] = SIMD4(light.position, light.reach)
            lights[2 + Self.lightLimit + i] = SIMD4(light.colour * light.intensity, 0)
        }
    }

    /// Writes one object's uniforms into this frame's next slot; its address, or `nil` when the frame is full.
    /// The ground's layers into a frame's next uniform slot (``GroundLayerUniforms`` is one slot's size).
    private func write(_ layers: GroundLayerUniforms) -> UInt64? {
        guard nextSlot < Self.maxObjects, layers.values.count == 16 else { refuseObject(); return nil }
        let offset = (frameSlot * Self.maxObjects + nextSlot) * Self.objectStride
        layers.values.withUnsafeBytes { objectBuffer.contents().advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        nextSlot += 1
        return objectBuffer.gpuAddress + UInt64(offset)
    }

    private func write(_ uniforms: ObjectUniforms) -> UInt64? {
        guard nextSlot < Self.maxObjects else { refuseObject(); return nil }
        var uniforms = uniforms
        let offset = (frameSlot * Self.maxObjects + nextSlot) * Self.objectStride
        objectBuffer.contents().advanced(by: offset)
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<ObjectUniforms>.stride)
        nextSlot += 1
        return objectBuffer.gpuAddress + UInt64(offset)
    }

    /// Every body of water, drawn over the finished opaque scene in one draw: each the rectangles it fills at its own
    /// level (``WorldFile/Water``). Laid out again only when the water changes.
    private func refreshWaterSurface() {
        let key = WaterKey(waters: scene.waters, lineage: terrainKey?.lineage, revision: terrainKey?.revision)
        guard key != waterKey else { return }
        waterKey = key
        waterCorners = []
        var rectangles: [(level: Float, rectangle: SIMD4<Float>)] = []
        defer { waterGrid = WorldWaterGrid(rectangles) }
        for water in scene.waters {
            // Each corner carries its body's own look, so every body is still one draw.
            let colour = water.colour.count == 3 ? SIMD3(water.colour[0], water.colour[1], water.colour[2]) : WorldScene.waterColour
            let look = SIMD4(colour, water.opacity)
            for r in water.rectangles.compactMap({ $0.count == 4 ? SIMD4($0[0], $0[1], $0[2], $0[3]) : nil }) {
                let y = water.level
                waterCorners += [SIMD4(r.x, y, r.y, 1), SIMD4(r.z, y, r.y, 1), SIMD4(r.z, y, r.w, 1),
                                 SIMD4(r.x, y, r.y, 1), SIMD4(r.z, y, r.w, 1), SIMD4(r.x, y, r.w, 1)]
                    .map { WaterCorner(position: $0, look: look) }
                rectangles.append((y, r))
            }
        }
        if waterCorners.count > Self.waterCapacity {
            NSLog("WorldRenderer: \(waterCorners.count / 6) rectangles of water, drawing the first \(Self.waterCapacity / 6)")
        }
    }

    /// Whether `point` is under a body of water — below its level, over its surface (``WorldWaterGrid``).
    private func isUnderWater(_ point: SIMD3<Float>) -> Bool { waterGrid.covers(point) }

    private func encodeWater(into encoder: MTL4RenderCommandEncoder) {
        refreshWaterSurface()
        guard !waterCorners.isEmpty else { return }
        if waterBuffers.isEmpty {
            waterBuffers = (0..<FrameRenderer.maxFramesInFlight).compactMap { _ in
                device.makeBuffer(length: Self.waterCapacity * MemoryLayout<WaterCorner>.stride, options: .storageModeShared)
            }
            engine.residencySet.addAllocations(waterBuffers)
            engine.commitResidency()
        }
        guard !waterBuffers.isEmpty else { return }
        let buffer = waterBuffers[frameSlot % waterBuffers.count]
        let count = min(waterCorners.count, Self.waterCapacity)
        waterCorners.withUnsafeBytes {
            buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: count * MemoryLayout<WaterCorner>.stride)
        }
        argumentTable.setAddress(buffer.gpuAddress, index: 0)
        bindSolidForReflections()
        encoder.setRenderPipelineState(waterPipeline)
        encoder.setDepthStencilState(waterDepthState)
        defer {
            encoder.setRenderPipelineState(propPipeline)
            encoder.setDepthStencilState(depthState)
        }
        guard bind(ObjectUniforms(
            model: matrix_identity_float4x4, normalMatrix: matrix_identity_float4x4,
            baseColour: .zero, emissive: .zero, params: .zero)) else { return }
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: count)
    }

    /// The solid pass's colour and depth where the water shaders read them (3 and 6), while it reflects the scene.
    /// **Always something there**: the shaders declare both, and Metal's validation refuses a draw whose texture was never
    /// set, even one the shader does not sample — with reflections off a pixel each stands in, never read.
    private func bindSolidForReflections() {
        if let solid = solidForReflections {
            argumentTable.setTexture(solid.colour.gpuResourceID, index: 3)
            argumentTable.setTexture(solid.depth.gpuResourceID, index: 6)
        } else if let (colour, depth) = reflectionStandIns {
            argumentTable.setTexture(colour.gpuResourceID, index: 3)
            argumentTable.setTexture(depth.gpuResourceID, index: 6)
        }
    }

    /// One pixel of colour and one of depth, for the water to be bound to while it reflects only the sky.
    private lazy var reflectionStandIns: (MTLTexture, MTLTexture)? = {
        let colour = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        colour.usage = .shaderRead
        colour.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        depth.usage = .shaderRead
        depth.storageMode = .private
        guard let c = device.makeTexture(descriptor: colour), let d = device.makeTexture(descriptor: depth) else { return nil }
        engine.residencySet.addAllocations([c, d])
        engine.commitResidency()
        return (c, d)
    }()

    /// **Every stream's surface**, a ribbon down its course, flowing (``WorldFile/Stream``): drawn like water,
    /// over the finished opaque scene, each corner carrying how far along it is, the way it runs, how white and how fast.
    private func encodeStreams(into encoder: MTL4RenderCommandEncoder) {
        if streamKey != scene.streams {
            streamKey = scene.streams
            streamVertices = scene.streams.flatMap { stream -> [StreamVertex] in
                let length = stream.length, c = stream.corners, k = WorldFile.Stream.floatsPerCorner
                return stride(from: 0, to: c.count - k + 1, by: k).map { i in
                    StreamVertex(position: SIMD4(c[i], c[i + 1], c[i + 2], c[i + 3]),
                                 flow: SIMD4(c[i + 4], c[i + 5], c[i + 6], c[i + 7]),
                                 extra: SIMD4(c[i + 8], length, 0, 0))
                }
            }
            if streamVertices.count > Self.streamCapacity {
                NSLog("WorldRenderer: \(streamVertices.count / 6) steps of stream, drawing the first \(Self.streamCapacity / 6)")
            }
        }
        guard !streamVertices.isEmpty else { return }
        if streamBuffers.isEmpty {
            streamBuffers = (0..<FrameRenderer.maxFramesInFlight).compactMap { _ in
                device.makeBuffer(length: Self.streamCapacity * MemoryLayout<StreamVertex>.stride, options: .storageModeShared)
            }
            engine.residencySet.addAllocations(streamBuffers)
            engine.commitResidency()
        }
        guard !streamBuffers.isEmpty else { return }
        let buffer = streamBuffers[frameSlot % streamBuffers.count]
        let count = min(streamVertices.count, Self.streamCapacity)
        streamVertices.withUnsafeBytes {
            buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: count * MemoryLayout<StreamVertex>.stride)
        }
        argumentTable.setAddress(buffer.gpuAddress, index: 0)
        bindSolidForReflections()
        encoder.setRenderPipelineState(streamPipeline)
        encoder.setDepthStencilState(waterDepthState)
        defer {
            encoder.setRenderPipelineState(propPipeline)
            encoder.setDepthStencilState(depthState)
        }
        guard bind(ObjectUniforms(
            model: matrix_identity_float4x4, normalMatrix: matrix_identity_float4x4,
            baseColour: SIMD4(WorldScene.waterColour, WorldScene.waterOpacity), emissive: .zero,
            params: SIMD4(streamTime, 0, 0, 0))) else { return }
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: count)
    }

    /// One corner of a stream's surface, as `streamVertex` reads it.
    private struct StreamVertex {
        /// xyz; w: metres along the course.
        var position: SIMD4<Float>
        /// The way it runs (x, z), how white, how fast.
        var flow: SIMD4<Float>
        /// x: which bank, −1 or 1; y: the stream's length.
        var extra: SIMD4<Float>
    }
    private var streamKey: [WorldFile.Stream]?
    private var streamVertices: [StreamVertex] = []
    private var streamBuffers: [MTLBuffer] = []
    /// Corners a frame can draw: ten thousand metres of stream.
    private static let streamCapacity = 65_536
    /// Seconds the streams have run, stepped with the scene — so a frame drawn off screen shows the same water every time.
    private var streamTime: Float = 0

    private struct WaterKey: Equatable { let waters: [WorldFile.Water]; let lineage: UUID?; let revision: Int? }
    private var waterKey: WaterKey?
    /// A corner of a body of water's surface and that body's look — its colour and opacity. Must match `WaterCorner` in
    /// the shaders.
    private struct WaterCorner { var position: SIMD4<Float>; var look: SIMD4<Float> }
    private var waterCorners: [WaterCorner] = []
    /// Each body's surface as rectangles `(x0, z0, x1, z1)` at its level — what ``isUnderWater(_:)`` asks.
    private var waterGrid = WorldWaterGrid([])
    /// One per frame in flight, so a level being dragged never rewrites corners a frame is still drawing.
    private var waterBuffers: [MTLBuffer] = []
    /// Corners a frame can draw: 43,690 rectangles — a sea round a dozen islands at half a metre.
    private static let waterCapacity = 262_144

    /// The scattered copies' transforms, a buffer per frame in flight — the engine's.
    private lazy var scatterTransforms = InstanceBuffer(renderer: engine)


    /// Nothing over the finished frame: what a game or an editor draws there is its own.
    public func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}

    // MARK: A prop's shape, for an outline

    /// **A prop's shape on screen**, for an editor to outline a selection by — Unity's, Unreal's and Blender's way: 1
    /// wherever it covers, its cut-outs cut exactly as the scene cuts them, so a tree's outline follows its leaves and not
    /// its cards; at the level of detail the scene draws it at; into an `r8Unorm` texture the view's size, returned. A band
    /// round its edge, drawn over the finished frame, is the outline.
    ///
    /// Call after ``encodePrePasses(into:frameSlot:interpolation:)``, in the same frame. Nil when the prop is not loaded.
    public func encodeSilhouette(of prop: URL, wearing materials: [String: WorldScene.Worn] = [:], transform: simd_float4x4,
                                 scale: Float, into commandBuffer: MTL4CommandBuffer) -> MTLTexture? {
        guard let plain = props[prop] else { return nil }
        let prop = dressed(plain, wearing: materials) ?? plain
        let level = detailLevel(of: prop, at: prop.bounds.transformed(by: transform), scale: scale)
        let (shownMeshes, tier) = prop.meshes(at: level)
        var parts: [ShadowPart] = []
        for shown in shownMeshes {
            let model = transform * shown.loaded.nodeTransform
            for submesh in shown.loaded.mesh.submeshes.indices {
                let material = shown.material(submesh)
                guard let address = write(ObjectUniforms(
                    model: model, normalMatrix: matrix_identity_float4x4, baseColour: material.baseColor,
                    emissive: .zero, params: SIMD4(0, 0, shown.cutoffs[submesh], 0))) else { return nil }
                parts.append(ShadowPart(mesh: shown.loaded.mesh, indices: shown.indices(submesh: submesh, level: tier),
                                        uniforms: address, baseMap: shown.baseMaps[submesh], copies: nil))
            }
        }
        guard !parts.isEmpty else { return nil }
        if silhouette?.width != viewportWidth || silhouette?.height != viewportHeight {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: viewportWidth,
                                                             height: viewportHeight, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            if let old = silhouette {
                retired.append(([old], [old], framesEncoded + FrameRenderer.maxFramesInFlight + 1))
            }
            silhouette = device.makeTexture(descriptor: d)
            if let fresh = silhouette {
                engine.residencySet.addAllocations([fresh])
                engine.commitResidency()
            }
        }
        guard let mask = silhouette else { return nil }
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Silhouette"
        encoder.setRenderPipelineState(silhouettePipeline)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameSlot * Self.frameStride), index: 2)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        for part in parts {
            part.indices.bindVertices(of: part.mesh, to: argumentTable)
            argumentTable.setAddress(part.uniforms, index: 1)
            argumentTable.setTexture(part.baseMap.gpuResourceID, index: 0)
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: part.indices.count,
                                          indexType: part.indices.type, indexBuffer: part.indices.address,
                                          indexBufferLength: part.indices.length)
        }
        encoder.endEncoding()
        return mask
    }

    /// Writes one object's uniforms into this frame's next slot and binds them. False when the frame is full.
    private func bind(_ uniforms: ObjectUniforms) -> Bool {
        guard nextSlot < Self.maxObjects else { refuseObject(); return false }
        var uniforms = uniforms
        let offset = (frameSlot * Self.maxObjects + nextSlot) * Self.objectStride
        objectBuffer.contents().advanced(by: offset)
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<ObjectUniforms>.stride)
        argumentTable.setAddress(objectBuffer.gpuAddress + UInt64(offset), index: 1)
        nextSlot += 1
        return true
    }

    // MARK: A frame into a file

    /// Renders one frame offscreen and returns it as PNG data — how a session checks the viewport
    /// without a person looking. Same passes as the screen: Ductane's `pngFrame`.
    public func pngFrame(width: Int, height: Int) -> Data? {
        viewportSizeChanged(width: width, height: height)
        return engine.pngFrame(width: width, height: height)
    }
}

/// Why a ``WorldRenderer`` could not be made.
public nonisolated enum WorldRendererError: Error, CustomStringConvertible, Sendable {
    case couldNotCreate(String)
    public var description: String {
        switch self {
        case .couldNotCreate(let what): "could not create the world renderer's \(what)"
        }
    }
}

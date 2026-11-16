//
//  VolumetricFog.swift
//  Ductane
//

import Metal
import simd

/// **Volumetric fog and sun shafts** (2026-11-16): the air in front of the eye as a grid of cells — a column every
/// ``GraphicsSettings/FogQuality`` pixels, sliced deeper the farther they are, out to ``far`` — lit by the sun through the
/// shadow map, so it throws shafts through gaps in trees, clouds and doorways and shadows fall through the haze; by the
/// clouds' shadows; and by the world's lights, which glow in it. Ground fog (``GroundFog``) lies in it, pooling over its
/// ``FogFloor``. Ultra Dynamic Sky and Enviro draw volumetric fog the same way.
///
/// **Before the scene pass**, after the shadows: ``encode(into:frameSlot:frame:quality:width:height:)`` records a compute
/// pass and returns the volume. A renderer binds it to every shader that draws a surface and lays it over what they draw
/// with ``Lookup``, and lays ``Drawn/sky`` over the sky: what the cells in front send toward the eye added, what shows
/// through the ground fog kept — the world's own exponential-squared fog stays the surfaces' as before, and the volume
/// adds the shafts and the ground fog.
/// At ``GraphicsSettings/FogQuality/low`` there is no volume, and the world's distance fog is what there is.
public final class VolumetricFog {
    /// A light that glows in the fog: where, how far it reaches, its colour times its intensity.
    public nonisolated struct Light: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var reach: Float
        public var colour: SIMD3<Float>
        public init(position: SIMD3<Float>, reach: Float, colour: SIMD3<Float>) {
            self.position = position
            self.reach = reach
            self.colour = colour
        }
    }

    /// The sun's shadows, as the renderer's ``ShadowMap`` drew them.
    public struct Shadows {
        public var texture: MTLTexture
        public var viewProjections: [simd_float4x4]
        public var splits: SIMD4<Float>
        public var depthBias: SIMD4<Float>
        public init(texture: MTLTexture, viewProjections: [simd_float4x4], splits: SIMD4<Float>, depthBias: SIMD4<Float>) {
            self.texture = texture
            self.viewProjections = viewProjections
            self.splits = splits
            self.depthBias = depthBias
        }
    }

    /// Everything a frame's fog is made from.
    public struct Frame {
        public var viewProjection: simd_float4x4
        public var eye: SIMD3<Float>
        public var lighting: DaySky.Lighting
        /// The world's exponential-squared fog (``Weather/fogDensity(over:)``) and how far from the eye it starts.
        public var fogDensity: Float
        public var fogStart: Float
        /// Ground fog's density at its floor now (``Weather/groundFogDensity(hour:)``), how high it lies and its colour.
        public var groundFog: Float
        public var groundFogHeight: Float
        public var groundFogColour: SIMD3<Float>
        /// Where it pools, and that map as a texture; with none, its floor is ``groundLevel`` everywhere.
        public var floor: FogFloor?
        public var floorTexture: MTLTexture?
        public var groundLevel: Float
        /// How far the wind has carried the fog's wisps, metres.
        public var drift: SIMD2<Float>
        public var shadows: Shadows?
        /// The clouds, for their shadows, and the coverage map they are read from (``CloudPass/coverageMap``).
        public var clouds: CloudLayer?
        public var cloudMap: MTLTexture?
        public var lights: [Light]

        public init(viewProjection: simd_float4x4, eye: SIMD3<Float>, lighting: DaySky.Lighting, fogDensity: Float,
                    fogStart: Float = 0, groundFog: Float = 0, groundFogHeight: Float = 6,
                    groundFogColour: SIMD3<Float> = GroundFog.mist, floor: FogFloor? = nil, floorTexture: MTLTexture? = nil,
                    groundLevel: Float = 0, drift: SIMD2<Float> = .zero, shadows: Shadows? = nil, clouds: CloudLayer? = nil,
                    cloudMap: MTLTexture? = nil, lights: [Light] = []) {
            self.viewProjection = viewProjection
            self.eye = eye
            self.lighting = lighting
            self.fogDensity = fogDensity
            self.fogStart = fogStart
            self.groundFog = groundFog
            self.groundFogHeight = groundFogHeight
            self.groundFogColour = groundFogColour
            self.floor = floor
            self.floorTexture = floorTexture
            self.groundLevel = groundLevel
            self.drift = drift
            self.shadows = shadows
            self.clouds = clouds
            self.cloudMap = cloudMap
            self.lights = lights
        }

        /// Whether there is anything for the volume to draw: ground fog, the world's fog for the sun to throw shafts
        /// through, or lights to glow in the haze.
        public var isEmpty: Bool { groundFog <= 0 && fogDensity <= 0 && lights.isEmpty }
    }

    /// **What a shader needs to read the volume** — `duFogApply` in `FogShaders.metal`, which a renderer copies: x 1 when
    /// there is a volume, y the first slice's near edge, z log(far / near), w the slices; and the distance a pixel of sky
    /// reads it at (``skyDistance(fogDensity:fogStart:)``).
    public nonisolated struct Lookup: Sendable, Equatable {
        public var parameters: SIMD4<Float>
        public var skyDistance: Float
        public static let none = Lookup(parameters: .zero, skyDistance: 0)
    }

    /// Mirrors `DUFogUniforms` in `FogShaders.metal`.
    struct Uniforms {
        var inverseViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var grid: SIMD4<Float>
        var depth: SIMD4<Float>
        var sun: SIMD4<Float>
        var sunColour: SIMD4<Float>
        var ambient: SIMD4<Float>
        var horizon: SIMD4<Float>
        var groundFog: SIMD4<Float>
        var groundColour: SIMD4<Float>
        var floorPlace: SIMD4<Float>
        var drift: SIMD4<Float>
        var cascades: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4)
        var cascadeSplits: SIMD4<Float>
        var cascadeDepthBias: SIMD4<Float>
        var clouds: SIMD4<Float>
        var cloudDrift: SIMD4<Float>
        var lightCount: SIMD4<Float>
        var lightPosition: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                            SIMD4<Float>, SIMD4<Float>)
        var lightColour: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                          SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                          SIMD4<Float>, SIMD4<Float>)
    }
    static let stride = (MemoryLayout<Uniforms>.stride + 255) & ~255
    public nonisolated static let maxLights = 16

    /// The first slice's near edge and the last's far edge, metres from the eye.
    public nonisolated static let near: Float = 0.5
    public nonisolated static let far: Float = 800
    /// How much forward the fog scatters the sun: toward a low sun it is brightest.
    public nonisolated static let forwardScattering: Float = 0.6
    /// The share of the world's fog's light that is the sun's: what its shadows take out of it.
    public nonisolated static let sunShare: Float = 0.6
    /// The thin haze the lights glow in even in clear air, per metre.
    public nonisolated static let haze: Float = 0.004

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let table: MTL4ArgumentTable
    private let uniforms: MTLBuffer
    /// Stands in for a missing shadow map, floor or cloud map.
    private let blankDepth: MTLTexture
    private let blank: MTLTexture
    private var volumes: [MTLTexture?] = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)
    /// **The sky's own picture**, a cell a column: the light in front of the sky at ``skyDistance(fogDensity:fogStart:)``,
    /// without the shafts' darkening of the world's fog — which the sky, never fogged by it, has nothing to lose.
    private var skyPictures: [MTLTexture?] = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)

    /// Everything the GPU must be able to reach: add it to the renderer's residency set — again after a volume is made
    /// anew (``volumesChanged``).
    public var allocations: [any MTLAllocation] {
        [uniforms, blankDepth, blank] + volumes.compactMap { $0 } + skyPictures.compactMap { $0 }
    }
    public var volumesChanged = false

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "FogShaders")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let function = MTL4LibraryFunctionDescriptor()
        function.library = library
        function.name = "duFogVolume"
        let descriptor = MTL4ComputePipelineDescriptor()
        descriptor.label = "Volumetric Fog"
        descriptor.computeFunctionDescriptor = function
        pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 5
        table = try device.makeArgumentTable(descriptor: tableDescriptor)
        guard let buffer = device.makeBuffer(length: Self.stride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw FrameRendererError.couldNotCreate("fog uniforms")
        }
        buffer.label = "Volumetric Fog"
        uniforms = buffer
        let depthDescriptor = MTLTextureDescriptor()
        depthDescriptor.textureType = .type2DArray
        depthDescriptor.pixelFormat = .depth32Float
        depthDescriptor.width = 1
        depthDescriptor.height = 1
        depthDescriptor.arrayLength = 4
        depthDescriptor.usage = .shaderRead
        depthDescriptor.storageMode = .private
        let blankDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: 1, height: 1,
                                                                       mipmapped: false)
        blankDescriptor.usage = .shaderRead
        blankDescriptor.storageMode = .shared
        guard let depth = device.makeTexture(descriptor: depthDescriptor),
              let blank = device.makeTexture(descriptor: blankDescriptor) else {
            throw FrameRendererError.couldNotCreate("fog blanks")
        }
        let zero = [Float16](repeating: 0, count: 2)
        zero.withUnsafeBytes { blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                             bytesPerRow: 4) }
        blankDepth = depth
        self.blank = blank
    }

    /// **Pixels a column covers and slices**, by quality — nil at Low.
    public nonisolated static func grid(_ quality: GraphicsSettings.FogQuality) -> (pixels: Int, slices: Int)? {
        switch quality {
        case .low: nil
        case .medium: (24, 48)
        case .high: (16, 64)
        }
    }

    /// **The distance a pixel of sky reads the volume at**: where the world's fog has hidden two thirds of what is
    /// behind it, or ``far`` — the sky is not fogged by the world's fog, as before, but shows the shafts and ground fog
    /// in front of it.
    public nonisolated static func skyDistance(fogDensity: Float, fogStart: Float) -> Float {
        guard fogDensity > 0 else { return far }
        return min(far, fogStart + 1.05 / fogDensity)
    }

    /// What a frame's fog pass made: the volume surfaces read, the sky's own picture, and how to read them.
    public struct Drawn {
        /// Surfaces read it (`duFogApply`).
        public var volume: MTLTexture
        /// A cell a column, read over the sky where nothing solid was drawn: what the air sends added, the sky kept by its
        /// alpha — at the screen's place, with no depth to look up.
        public var sky: MTLTexture
        public var lookup: Lookup
    }

    /// **Records the fog** for a frame drawn `width` × `height`, and returns the volume, the sky's picture and what a
    /// shader needs to read them — nil at Low, or when there is nothing to draw.
    public func encode(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, frame: Frame,
                       quality: GraphicsSettings.FogQuality, width: Int, height: Int) -> Drawn? {
        guard let grid = Self.grid(quality), !frame.isEmpty else { return nil }
        let columns = max((width + grid.pixels - 1) / grid.pixels, 1)
        let rows = max((height + grid.pixels - 1) / grid.pixels, 1)
        let slot = frameSlot % volumes.count
        if let v = volumes[slot], v.width == columns, v.height == rows, v.depth == grid.slices {} else {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba16Float
            descriptor.width = columns
            descriptor.height = rows
            descriptor.depth = grid.slices
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            volumes[slot] = device.makeTexture(descriptor: descriptor)
            volumes[slot]?.label = "Volumetric Fog"
            volumesChanged = true
        }
        if let p = skyPictures[slot], p.width == columns, p.height == rows {} else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: columns,
                                                                      height: rows, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            skyPictures[slot] = device.makeTexture(descriptor: descriptor)
            skyPictures[slot]?.label = "Volumetric Fog over the Sky"
            volumesChanged = true
        }
        guard let volume = volumes[slot], let skyPicture = skyPictures[slot] else { return nil }
        let skyDistance = Self.skyDistance(fogDensity: frame.fogDensity, fogStart: frame.fogStart)

        let logRatio = log(Self.far / Self.near)
        let light = frame.lighting
        let c = frame.shadows?.viewProjections ?? []
        func cascade(_ i: Int) -> simd_float4x4 { i < c.count ? c[i] : matrix_identity_float4x4 }
        var values = Uniforms(
            inverseViewProjection: frame.viewProjection.inverse,
            eye: SIMD4(frame.eye, frame.fogStart),
            grid: SIMD4(Float(columns), Float(rows), Float(grid.slices), skyDistance),
            depth: SIMD4(Self.near, logRatio, max(frame.fogDensity, 0), Self.sunShare),
            sun: SIMD4(light.direction, frame.shadows == nil ? 0 : 1),
            sunColour: SIMD4(light.colour, Self.forwardScattering),
            ambient: SIMD4((light.skyLight == .zero ? light.zenith : light.skyLight) * 0.6 + light.horizon * 0.4, 0),
            horizon: SIMD4(light.horizon, 0),
            groundFog: SIMD4(max(frame.groundFog, 0), max(frame.groundFogHeight, 0.5),
                             frame.floor?.base ?? frame.groundLevel, frame.floor != nil && frame.floorTexture != nil ? 1 : 0),
            groundColour: SIMD4(frame.groundFogColour, 0.6),
            floorPlace: SIMD4(frame.floor?.corner.x ?? 0, frame.floor?.corner.y ?? 0, max(frame.floor?.size ?? 1, 1), 0),
            drift: SIMD4(frame.drift.x, frame.drift.y, Self.haze, 0),
            cascades: (cascade(0), cascade(1), cascade(2), cascade(3)),
            cascadeSplits: frame.shadows?.splits ?? .zero,
            cascadeDepthBias: frame.shadows?.depthBias ?? .zero,
            clouds: frame.clouds.map { SIMD4($0.coverage, $0.darkness, $0.base, $0.thickness) } ?? .zero,
            cloudDrift: SIMD4(frame.clouds?.drift.x ?? 0, frame.clouds?.drift.y ?? 0, 0, 0),
            lightCount: SIMD4(Float(min(frame.lights.count, Self.maxLights)), 0, 0, 0),
            lightPosition: (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
                            .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero),
            lightColour: (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
                          .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero))
        withUnsafeMutableBytes(of: &values.lightPosition) { raw in
            let p = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, l) in frame.lights.prefix(Self.maxLights).enumerated() { p[i] = SIMD4(l.position, l.reach) }
        }
        withUnsafeMutableBytes(of: &values.lightColour) { raw in
            let p = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, l) in frame.lights.prefix(Self.maxLights).enumerated() { p[i] = SIMD4(l.colour, 0) }
        }
        let offset = slot * Self.stride
        uniforms.contents().advanced(by: offset).copyMemory(from: &values, byteCount: MemoryLayout<Uniforms>.size)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Volumetric Fog"
        // The shadow map was drawn by a render pass earlier in this command buffer, and Metal 4 orders nothing unasked.
        encoder.barrier(afterQueueStages: [.vertex, .fragment], beforeStages: .dispatch, visibilityOptions: .device)
        encoder.setComputePipelineState(pipeline)
        encoder.setArgumentTable(table)
        table.setAddress(uniforms.gpuAddress + UInt64(offset), index: 0)
        table.setTexture(volume.gpuResourceID, index: 0)
        table.setTexture((frame.shadows?.texture ?? blankDepth).gpuResourceID, index: 1)
        table.setTexture(((frame.floor != nil ? frame.floorTexture : nil) ?? blank).gpuResourceID, index: 2)
        table.setTexture((frame.cloudMap ?? blank).gpuResourceID, index: 3)
        table.setTexture(skyPicture.gpuResourceID, index: 4)
        encoder.dispatchThreads(threadsPerGrid: MTLSize(width: columns, height: rows, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return Drawn(volume: volume, sky: skyPicture,
                     lookup: Lookup(parameters: SIMD4(1, Self.near, logRatio, Float(grid.slices)), skyDistance: skyDistance))
    }
}

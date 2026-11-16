import Metal
import simd

/// **Draws a ``DaySky`` behind a scene**: a full-screen triangle at the far plane, the zenith fading to the horizon, the
/// ground's colour below it and the sun's disc — and, when given them (2026-11-16), the night's stars, Milky Way and moon
/// with its phase (``NightSky``), and the clouds over all of it: ``CloudPass``'s volumetric picture, or a flat layer.
///
/// **First in the scene pass**, before anything else is drawn: it writes no depth and tests none, so everything drawn
/// after covers it. It sets its own pipeline, depth state and argument table on the encoder; set yours again after.
public final class SkyPass {
    /// Mirrors `SkyUniforms` in `SkyShaders.metal`.
    struct Uniforms {
        var inverseViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var sunDirection: SIMD4<Float>
        var sunColour: SIMD4<Float>
        var zenith: SIMD4<Float>
        var horizon: SIMD4<Float>
        var ground: SIMD4<Float>
        var sun: SIMD4<Float>
        var moon: SIMD4<Float>
        var night: SIMD4<Float>
        var starRow0: SIMD4<Float>
        var starRow1: SIMD4<Float>
        var starRow2: SIMD4<Float>
        var clouds: SIMD4<Float>
        var cloudMotion: SIMD4<Float>
        var aurora: SIMD4<Float>
        var rainbow: SIMD4<Float>
    }
    static let stride = (MemoryLayout<Uniforms>.stride + 255) & ~255

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let table: MTL4ArgumentTable
    private let uniforms: MTLBuffer
    /// Stands in for the clouds' picture when there is none: clear sky.
    private let noClouds: MTLTexture
    /// Where clouds gather, for the flat layer (``CloudLayer/coverageMap``).
    private let coverageMap: MTLTexture

    /// Everything the GPU must be able to reach: add it to the renderer's residency set.
    public var allocations: [any MTLAllocation] { [uniforms, noClouds, coverageMap] }

    /// - Parameter sampleCount: the scene pass's samples per pixel (``FrameRenderer/sampleCount``); make another
    ///   ``SkyPass`` when it changes.
    public init(device: MTLDevice, sampleCount: Int = 1) throws {
        let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "SkyShaders")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = "skyVertex"
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = "skyFragment"
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "Sky"
        descriptor.vertexFunctionDescriptor = vertex
        descriptor.fragmentFunctionDescriptor = fragment
        descriptor.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
        descriptor.rasterSampleCount = max(sampleCount, 1)
        pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw FrameRendererError.couldNotCreate("sky depth state")
        }
        self.depthState = depthState
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 2
        table = try device.makeArgumentTable(descriptor: tableDescriptor)
        guard let map = CloudLayer.coverageTexture(device: device) else { throw FrameRendererError.couldNotCreate("sky map") }
        coverageMap = map
        let clear = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        clear.usage = .shaderRead
        clear.storageMode = .shared
        guard let none = device.makeTexture(descriptor: clear) else { throw FrameRendererError.couldNotCreate("sky clouds") }
        let open: [Float16] = [0, 0, 0, 1]
        open.withUnsafeBytes { none.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                            bytesPerRow: 8) }
        noClouds = none
        guard let buffer = device.makeBuffer(length: Self.stride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw FrameRendererError.couldNotCreate("sky uniforms")
        }
        buffer.label = "Sky"
        uniforms = buffer
    }

    /// The clouds to lay over the sky: the layer, and ``CloudPass``'s picture of it — nil draws it as a flat layer.
    public struct Clouds {
        public var layer: CloudLayer
        public var picture: MTLTexture?
        public init(layer: CloudLayer, picture: MTLTexture?) {
            self.layer = layer
            self.picture = picture
        }
    }

    /// Draws the sky as seen through `viewProjection` from `eye` — with `night`'s stars and moon, and `clouds` over it,
    /// when given; `time` (seconds) twinkles the stars.
    public func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, viewProjection: simd_float4x4,
                       eye: SIMD3<Float>, lighting: DaySky.Lighting, night: NightSky? = nil, clouds: Clouds? = nil,
                       time: Float = 0, rainbow: Float = 0) {
        // Without a night sky, the disc is drawn where the light comes from, as it always was.
        let sun = night.map { SIMD4($0.sun, $0.sun.y > -0.02 ? 1 : 0) } ?? SIMD4(lighting.direction, 1)
        let rotation = night?.starRotation ?? matrix_identity_float3x3
        let layer = clouds?.layer
        var values = Uniforms(inverseViewProjection: viewProjection.inverse, eye: SIMD4(eye, 1),
                              sunDirection: SIMD4(lighting.direction, 0), sunColour: SIMD4(lighting.colour, 0),
                              zenith: SIMD4(lighting.zenith, 0), horizon: SIMD4(lighting.horizon, 0),
                              ground: SIMD4(lighting.ground, 0), sun: sun,
                              moon: night.map { SIMD4($0.moon, $0.illumination) } ?? .zero,
                              night: SIMD4(night?.stars ?? 0, clouds == nil ? 0 : (clouds?.picture == nil ? 1 : 2), time, 0),
                              starRow0: SIMD4(rotation.transpose.columns.0, 0),
                              starRow1: SIMD4(rotation.transpose.columns.1, 0),
                              starRow2: SIMD4(rotation.transpose.columns.2, 0),
                              clouds: layer.map { SIMD4($0.coverage, $0.darkness, $0.base, $0.thickness) } ?? .zero,
                              cloudMotion: layer?.motion ?? SIMD4(0, -1, 0, 0),
                              aurora: night.map { SIMD4($0.pole, $0.aurora) } ?? .zero,
                              rainbow: SIMD4(night == nil ? 0 : max(rainbow, 0), 0, 0, 0))
        let offset = frameSlot * Self.stride
        uniforms.contents().advanced(by: offset).copyMemory(from: &values, byteCount: MemoryLayout<Uniforms>.size)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        table.setAddress(uniforms.gpuAddress + UInt64(offset), index: 0)
        table.setTexture((clouds?.picture ?? noClouds).gpuResourceID, index: 0)
        table.setTexture(coverageMap.gpuResourceID, index: 1)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

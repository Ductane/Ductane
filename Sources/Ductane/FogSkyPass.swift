import Metal

/// **Lays the fog volume over the sky** — ``VolumetricFog/Drawn/sky``, the light the air in front sends toward the eye and
/// how much of the sky shows through it — so ground fog and the light in the haze stand in front of the sky too, where
/// nothing solid was drawn.
///
/// **In the scene pass, after everything solid and before anything see-through**: a triangle over the screen at the far
/// plane whose depth test (reversed-Z, `greaterEqual`) passes only where the depth was left clear. Blended: what the air
/// sends added, the sky kept by what shows through. Surfaces read the volume themselves (`duFogApply` in
/// `DuctaneWeather.h`); this is the sky's share. It sets its own pipeline, depth state and argument table on the encoder;
/// set yours again after.
public final class FogSkyPass {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let table: MTL4ArgumentTable

    /// - Parameter sampleCount: the scene pass's samples per pixel (``FrameRenderer/sampleCount``); make another when it
    ///   changes.
    public init(device: MTLDevice, sampleCount: Int = 1) throws {
        let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "FogShaders")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
            let f = MTL4LibraryFunctionDescriptor()
            f.library = library
            f.name = name
            return f
        }
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "Fog over the Sky"
        descriptor.vertexFunctionDescriptor = function("duFogSkyVertex")
        descriptor.fragmentFunctionDescriptor = function("duFogSkyFragment")
        descriptor.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
        descriptor.colorAttachments[0].blendingState = .enabled
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        descriptor.rasterSampleCount = max(sampleCount, 1)
        pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greaterEqual
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw FrameRendererError.couldNotCreate("fog sky depth state")
        }
        self.depthState = depthState
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxTextureBindCount = 1
        table = try device.makeArgumentTable(descriptor: tableDescriptor)
    }

    /// Draws `fog`'s picture over the sky, if the frame has one — nothing at Low, or with no fog to draw.
    public func encode(into encoder: MTL4RenderCommandEncoder, fog: VolumetricFog.Drawn?) {
        guard let fog else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setArgumentTable(table, stages: [.fragment])
        table.setTexture(fog.sky.gpuResourceID, index: 0)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

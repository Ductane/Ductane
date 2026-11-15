//
//  WeatherCover.swift
//  Ductane
//

import Metal
import simd

/// Why a ``WeatherCover`` could not be made.
public nonisolated enum WeatherCoverError: Error, CustomStringConvertible, Sendable {
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .couldNotCreate(let what): "the device would not create the weather cover's \(what)"
        }
    }
}

/// **What is overhead, around the eye**: the world drawn from straight above into a depth texture, so
/// ``WeatherRenderer`` keeps rain and snow out from under a roof, a bridge or a tree, and lands its splashes on whatever
/// is uppermost.
///
/// **Drawn with a game's own shadow batches** (``ShadowBatch``), asked for ``ShadowPass/Target/cover``: the same
/// pipelines and the same uniforms a sun cascade uses, so a game that casts shadows already has everything a cover
/// needs. Both sides of every triangle are recorded — a roof that is one plane facing up must still be a roof.
///
/// Reversed-Z like every other pass: higher is a greater depth, nothing drawn is 0 — no cover.
public final class WeatherCover {

    /// The depth format, a shadow pipeline's.
    public nonisolated static let depthPixelFormat: MTLPixelFormat = .depth32Float
    /// Texels a side.
    public let resolution: Int
    /// Metres from the middle to an edge: rain falls this far from the eye, and no further.
    public let halfExtent: Float
    /// Metres above the eye the look starts, and how far down it reaches.
    public nonisolated static let above: Float = 80
    public nonisolated static let depthRange: Float = 200

    public let texture: MTLTexture
    /// World to the cover's clip space, as last ``update(around:)`` placed it.
    public private(set) var viewProjection = matrix_identity_float4x4
    /// The height the look starts at, and how far down depth 0 is from it.
    public private(set) var top: Float = 0

    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let matrixBuffer: MTLBuffer
    private static let matrixStride = (MemoryLayout<simd_float4x4>.stride + 255) & ~255

    public init(device: MTLDevice, resolution: Int = 512, halfExtent: Float = 24) throws {
        self.resolution = max(resolution, 16)
        self.halfExtent = max(halfExtent, 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthPixelFormat,
                                                                  width: self.resolution, height: self.resolution,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WeatherCoverError.couldNotCreate("depth texture")
        }
        texture.label = "Weather Cover"
        self.texture = texture
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw WeatherCoverError.couldNotCreate("depth state")
        }
        self.depthState = depthState
        guard let matrices = device.makeBuffer(length: Self.matrixStride * FrameRenderer.maxFramesInFlight,
                                               options: .storageModeShared) else {
            throw WeatherCoverError.couldNotCreate("matrix buffer")
        }
        matrices.label = "Weather Cover Matrix"
        matrixBuffer = matrices
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 5   // through ShadowBufferIndex.instances
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw WeatherCoverError.couldNotCreate("argument table")
        }
    }

    public var allocations: [any MTLAllocation] { [texture, matrixBuffer] }

    /// Metres a texel covers.
    public var texelSize: Float { 2 * halfExtent / Float(resolution) }

    /// **Centres the cover on `eye`**, in whole texels so what is overhead does not shimmer as the eye moves, and returns
    /// the matrix the frame draws with.
    @discardableResult
    public func update(around eye: SIMD3<Float>) -> simd_float4x4 {
        let texel = texelSize
        let centre = SIMD2((eye.x / texel).rounded() * texel, (eye.z / texel).rounded() * texel)
        top = ((eye.y + Self.above) / texel).rounded() * texel
        viewProjection = Self.matrix(centre: centre, halfExtent: halfExtent, top: top)
        return viewProjection
    }

    /// World to clip, looking straight down: `x` east, `y` north, depth 1 at `top` and 0 ``depthRange`` below it.
    public nonisolated static func matrix(centre: SIMD2<Float>, halfExtent e: Float, top: Float) -> simd_float4x4 {
        let range = depthRange
        return simd_float4x4(columns: (
            SIMD4(1 / e, 0, 0, 0),
            SIMD4(0, 0, 1 / range, 0),
            SIMD4(0, -1 / e, 0, 0),
            SIMD4(-centre.x / e, centre.y / e, 1 - top / range, 1)))
    }

    /// The height of what is uppermost where a texel read `depth`; nothing drawn reads as ``depthRange`` below the top.
    public func height(atDepth depth: Float) -> Float { top - (1 - depth) * Self.depthRange }

    /// **Records what is overhead**, with the game's shadow batches asked for ``ShadowPass/Target/cover``.
    /// ``update(around:)`` must have run this frame, and the batches' uniforms be written.
    public func encode(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, batches: [ShadowBatch]) {
        let offset = Self.matrixStride * frameSlot
        var matrix = viewProjection
        matrixBuffer.contents().advanced(by: offset).copyMemory(from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)

        let descriptor = MTL4RenderPassDescriptor()
        let attachment = MTLRenderPassDepthAttachmentDescriptor()
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearDepth = FrameRenderer.reversedZClearDepth
        attachment.storeAction = .store
        descriptor.depthAttachment = attachment
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Weather Cover"
        encoder.barrier(afterQueueStages: .dispatch, beforeStages: .vertex, visibilityOptions: .device)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthStencilState(depthState)
        encoder.setArgumentTable(argumentTable, stages: .vertex)
        argumentTable.setAddress(matrixBuffer.gpuAddress + UInt64(offset), index: ShadowBufferIndex.lightViewProjection)
        let pass = ShadowPass(target: .cover, viewProjection: viewProjection)
        for batch in batches {
            switch batch.kind {
            case .encodes(let encode):
                encoder.setRenderPipelineState(batch.pipeline)
                encode(encoder, argumentTable, pass)
            case .objects(let objects):
                guard objects.count > 0 else { continue }
                encoder.setRenderPipelineState(batch.pipeline)
                for index in 0..<objects.count {
                    ShadowBatch.drawObject(index, of: objects, encoder: encoder, table: argumentTable)
                }
            }
        }
        encoder.endEncoding()
    }
}

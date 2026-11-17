//
//  WaymarkScanRenderer.swift
//  Ductane
//

import Foundation
import Metal
import simd

/// Draws a ``WaymarkScan``: **the ring** as a band over the ground with a faint curtain of light above it, seen through
/// walls; **an outline round each found thing**, seen through walls, from a mask of their shapes
/// (``encodeMask(_:viewProjection:width:height:frameSlot:into:)``) — Unreal's custom-depth outline, a band round each
/// shape and a faint fill inside it; and **an icon over each** in its kind's colour, with its distance beneath, a fixed
/// size on screen and over everything.
///
/// **Into the HDR scene after the opaque geometry**, blended premultiplied, as ``WaymarkRenderer`` draws. Usable by any
/// renderer: ``WorldRenderer`` draws one itself (``WorldRenderer/scan``), a game with its own renderer makes one and
/// hands it its findables' triangles (``Findable/MaskDraw``).
public final class WaymarkScanRenderer {

    /// The frame as the shader reads it — `DUScanFrame`.
    nonisolated struct Frame {
        var viewProjection: simd_float4x4
        var camera: SIMD4<Float>
        var color: SIMD4<Float>
        var ring: SIMD4<Float>
        var screen: SIMD4<Float>
        var origin: SIMD4<Float>
    }

    /// One icon as the shader reads it — `DUScanIcon`: **three `float4`s**, pinned by a test.
    nonisolated struct Icon {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
        var label: SIMD4<Float>
    }

    /// One outlined part as the shader reads it — `DUScanPart`.
    nonisolated struct Part {
        var modelViewProjection: simd_float4x4
        var shape: SIMD4<Float>
    }

    /// **One part of the mask**: triangles, and how much they show.
    public struct MaskPart: Sendable {
        public var draw: Findable.MaskDraw
        public var opacity: Float
        public init(draw: Findable.MaskDraw, opacity: Float) {
            self.draw = draw
            self.opacity = opacity
        }
    }

    /// The most points round the ring, icons and outlined parts a frame draws.
    public nonisolated static let limits = (ring: 256, icons: 512, parts: 2_048)
    /// How tall the curtain over the ring is, meters.
    public nonisolated static let curtainHeight: Float = 5

    private let device: MTLDevice
    private let ringPipeline: MTLRenderPipelineState
    private let curtainPipeline: MTLRenderPipelineState
    private let outlinePipeline: MTLRenderPipelineState
    private let iconPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let testedDepth: MTLDepthStencilState
    private let overDepth: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let maskTable: MTL4ArgumentTable
    private let ringBuffer: MTLBuffer
    private let iconBuffer: MTLBuffer
    private let frameBuffer: MTLBuffer
    private let partBuffer: MTLBuffer
    private var mask: MTLTexture?
    private var retiredMasks: [(MTLTexture, Int)] = []
    private var masksMade = 0
    private static let frameStride = (MemoryLayout<Frame>.size + 255) & ~255
    private static let partStride = (MemoryLayout<Part>.size + 255) & ~255
    private static let ringBytes = MemoryLayout<SIMD4<Float>>.stride * limits.ring
    private static let iconBytes = MemoryLayout<Icon>.stride * limits.icons

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                sampleCount: Int = 1) throws {
        self.device = device
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "WaymarkScanShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
                let f = MTL4LibraryFunctionDescriptor()
                f.library = library
                f.name = name
                return f
            }
            func pipeline(_ name: String, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
                let descriptor = MTL4RenderPipelineDescriptor()
                descriptor.label = name
                descriptor.vertexFunctionDescriptor = function(vertex)
                descriptor.fragmentFunctionDescriptor = function(fragment)
                descriptor.rasterSampleCount = max(sampleCount, 1)
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                descriptor.colorAttachments[0].blendingState = .enabled
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            }
            ringPipeline = try pipeline("Scan Ring", vertex: "duScanRingVertex", fragment: "duScanRingFragment")
            curtainPipeline = try pipeline("Scan Curtain", vertex: "duScanCurtainVertex", fragment: "duScanRingFragment")
            outlinePipeline = try pipeline("Scan Outlines", vertex: "duScanOutlineVertex", fragment: "duScanOutlineFragment")
            iconPipeline = try pipeline("Scan Icons", vertex: "duScanIconVertex", fragment: "duScanIconFragment")
            // The mask: one sample, the most of any shape over a pixel.
            let m = MTL4RenderPipelineDescriptor()
            m.label = "Scan Mask"
            m.vertexFunctionDescriptor = function("duScanMaskVertex")
            m.fragmentFunctionDescriptor = function("duScanMaskFragment")
            m.colorAttachments[0].pixelFormat = .r8Unorm
            m.colorAttachments[0].blendingState = .enabled
            m.colorAttachments[0].rgbBlendOperation = .max
            m.colorAttachments[0].alphaBlendOperation = .max
            m.colorAttachments[0].sourceRGBBlendFactor = .one
            m.colorAttachments[0].destinationRGBBlendFactor = .one
            m.colorAttachments[0].sourceAlphaBlendFactor = .one
            m.colorAttachments[0].destinationAlphaBlendFactor = .one
            maskPipeline = try compiler.makeRenderPipelineState(descriptor: m)
        } catch {
            throw WaymarkRendererError.pipelineUnavailable(String(describing: error))
        }
        let tested = MTLDepthStencilDescriptor()
        tested.depthCompareFunction = .greater
        tested.isDepthWriteEnabled = false
        let over = MTLDepthStencilDescriptor()
        over.depthCompareFunction = .always
        over.isDepthWriteEnabled = false
        guard let testedDepth = device.makeDepthStencilState(descriptor: tested),
              let overDepth = device.makeDepthStencilState(descriptor: over) else {
            throw WaymarkRendererError.couldNotCreate("scan depth states")
        }
        let slots = FrameRenderer.maxFramesInFlight
        guard let ring = device.makeBuffer(length: Self.ringBytes * slots, options: .storageModeShared),
              let icons = device.makeBuffer(length: Self.iconBytes * slots, options: .storageModeShared),
              let frames = device.makeBuffer(length: Self.frameStride * slots, options: .storageModeShared),
              let parts = device.makeBuffer(length: Self.partStride * Self.limits.parts * slots, options: .storageModeShared) else {
            throw WaymarkRendererError.couldNotCreate("scan buffers")
        }
        ring.label = "Scan Ring"
        icons.label = "Scan Icons"
        frames.label = "Scan Frame"
        parts.label = "Scan Mask Parts"
        self.testedDepth = testedDepth
        self.overDepth = overDepth
        ringBuffer = ring
        iconBuffer = icons
        frameBuffer = frames
        partBuffer = parts
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        table.maxTextureBindCount = 1
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
            maskTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw WaymarkRendererError.couldNotCreate("argument table")
        }
    }

    /// What must be resident while it draws: its buffers, and the mask once it has one — ask again after the view's size
    /// changes (``allocationsChanged``).
    public var allocations: [any MTLAllocation] {
        [ringBuffer, iconBuffer, frameBuffer, partBuffer] + (mask.map { [$0] } ?? [])
    }

    /// **Called with the new mask when the view's size makes one**, for a renderer to make it resident; the old one is
    /// given back a few frames later, when nothing in flight reads it.
    public var allocationsChanged: ((_ added: [any MTLAllocation], _ removed: [any MTLAllocation]) -> Void)?

    /// **The shapes to outline, into a mask the view's size**: each part's opacity wherever it covers, the most of any
    /// over a pixel — whatever stands in front of it, so the outline is seen through walls. Its own pass, before the
    /// scene's. Nil when there is nothing to outline.
    @discardableResult
    public func encodeMask(_ parts: [MaskPart], viewProjection: simd_float4x4, width: Int, height: Int, frameSlot: Int,
                           into commandBuffer: MTL4CommandBuffer) -> MTLTexture? {
        masksMade += 1
        if let (old, after) = retiredMasks.first, masksMade > after {
            retiredMasks.removeFirst()
            allocationsChanged?([], [old])
        }
        let parts = parts.filter { $0.opacity > 0 && $0.draw.indexCount > 0 }.prefix(Self.limits.parts)
        guard !parts.isEmpty, width > 0, height > 0 else { return nil }
        if mask?.width != width || mask?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let made = device.makeTexture(descriptor: d) else { return nil }
            made.label = "Scan Mask"
            if let old = mask { retiredMasks.append((old, masksMade + FrameRenderer.maxFramesInFlight + 1)) }
            mask = made
            allocationsChanged?([made], [])
        }
        guard let mask else { return nil }
        let base = partBuffer.contents().advanced(by: Self.partStride * Self.limits.parts * frameSlot)
        for (i, part) in parts.enumerated() {
            var p = Part(modelViewProjection: viewProjection * part.draw.transform,
                         shape: SIMD4(Float(max(part.draw.stride, 12) / 4), simd_clamp(part.opacity, 0, 1), 0, 0))
            base.advanced(by: Self.partStride * i).copyMemory(from: &p, byteCount: MemoryLayout<Part>.size)
        }
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Scan Mask"
        encoder.setRenderPipelineState(maskPipeline)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(maskTable, stages: [.vertex, .fragment])
        let partsAddress = partBuffer.gpuAddress + UInt64(Self.partStride * Self.limits.parts * frameSlot)
        for (i, part) in parts.enumerated() {
            maskTable.setAddress(part.draw.vertices, index: 0)
            maskTable.setAddress(partsAddress + UInt64(Self.partStride * i), index: 1)
            let size = part.draw.indexType == .uint16 ? 2 : 4
            encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: part.draw.indexCount,
                                          indexType: part.draw.indexType, indexBuffer: part.draw.indices,
                                          indexBufferLength: part.draw.indexCount * size)
        }
        encoder.endEncoding()
        return mask
    }

    /// **Draws the scan as it is at its age** — the ring while it travels, the outlines from `mask`, and an icon over each
    /// shown thing. Nothing once it is over.
    ///
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    ///
    /// - Parameters:
    ///   - shown: the found things as they show now (``WaymarkScan/shown(_:from:)``).
    ///   - surface: the height of the ground, or water over it, at a point across it — what the ring runs over.
    ///   - mask: what ``encodeMask(_:viewProjection:width:height:frameSlot:into:)`` made this frame; nil draws no outlines.
    ///   - viewportSize: the drawn view in pixels — the outline's and the icons' sizes are kept in pixels of it.
    @discardableResult
    public func draw(_ scan: WaymarkScan, shown: [WaymarkScan.Shown], surface: (SIMD2<Float>) -> Float,
                     mask: MTLTexture?, into encoder: MTL4RenderCommandEncoder, frameSlot: Int,
                     viewProjection: simd_float4x4, camera: SIMD3<Float>, viewportSize: SIMD2<Float>,
                     time: Float = 0, brightness: Float = 1) -> Bool {
        let look = scan.look
        let ring = scan.ringOpacity
        let icons = shown.filter { $0.icon > 0 }.prefix(Self.limits.icons)
        let outlines = mask != nil && shown.contains { $0.outline > 0 }
        guard ring > 0 || !icons.isEmpty || outlines else { return false }
        let light = max(brightness, 0)
        let points = ring > 0 ? scan.ring(count: Self.limits.ring, surface: surface) : []
        if !points.isEmpty {
            let base = ringBuffer.contents().advanced(by: Self.ringBytes * frameSlot)
                .bindMemory(to: SIMD4<Float>.self, capacity: Self.limits.ring)
            for (i, p) in points.enumerated() { base[i] = SIMD4(p, 0) }
        }
        if !icons.isEmpty {
            let base = iconBuffer.contents().advanced(by: Self.iconBytes * frameSlot)
                .bindMemory(to: Icon.self, capacity: Self.limits.icons)
            let iconIndex = Dictionary(uniqueKeysWithValues: Waymark.Look.Icon.allCases.enumerated().map { ($1, Float($0)) })
            for (i, item) in icons.enumerated() {
                let kind = look.kind(item.findable.kind)
                base[i] = Icon(position: SIMD4(item.findable.iconPosition, item.icon),
                               color: SIMD4(look.iconColor(item.findable.kind) * light * 1.4, iconIndex[kind.icon] ?? 0),
                               label: SIMD4(look.scan.showsDistance ? item.distance : -1, 0, 0, 0))
            }
        }
        var frame = Frame(
            viewProjection: viewProjection,
            camera: SIMD4(camera, time),
            color: SIMD4(look.scan.color * look.scan.intensity * light, ring),
            ring: SIMD4(look.scan.ringWidth * 0.5, look.scan.ringWidth * look.scan.glow, Self.curtainHeight,
                        Float(max(points.count, 1))),
            screen: SIMD4(viewportSize.x, viewportSize.y, look.scan.outlineWidth, look.scan.iconSize),
            origin: SIMD4(scan.origin, scan.front))
        let frameOffset = Self.frameStride * frameSlot
        frameBuffer.contents().advanced(by: frameOffset).copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)

        encoder.pushDebugGroup("Waymark Scan")
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameOffset), index: 1)
        if !points.isEmpty {
            argumentTable.setAddress(ringBuffer.gpuAddress + UInt64(Self.ringBytes * frameSlot), index: 0)
            // The band, tested against the scene; then the curtain, over it.
            encoder.setDepthStencilState(testedDepth)
            encoder.setRenderPipelineState(ringPipeline)
            encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: (points.count + 1) * 2)
            encoder.setDepthStencilState(overDepth)
            encoder.setRenderPipelineState(curtainPipeline)
            encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: (points.count + 1) * 2)
        }
        encoder.setDepthStencilState(overDepth)
        if outlines, let mask {
            argumentTable.setTexture(mask.gpuResourceID, index: 0)
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !icons.isEmpty {
            argumentTable.setAddress(iconBuffer.gpuAddress + UInt64(Self.iconBytes * frameSlot), index: 0)
            encoder.setRenderPipelineState(iconPipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 12, instanceCount: icons.count)
        }
        encoder.popDebugGroup()
        return true
    }
}

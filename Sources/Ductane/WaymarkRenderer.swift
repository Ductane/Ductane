//
//  WaymarkRenderer.swift
//  Ductane
//

import Foundation
import Metal
import simd

/// Why a ``WaymarkRenderer`` could not be made.
public nonisolated enum WaymarkRendererError: Error, CustomStringConvertible, Sendable {
    /// The waymark shaders would not compile, or their pipelines would not build — the reason kept as text.
    case pipelineUnavailable(String)
    /// The device would not create one of the objects drawing needs — named here.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .pipelineUnavailable(let reason): "unable to build the waymark pipelines: \(reason)"
        case .couldNotCreate(let what): "the device would not create the \(what)"
        }
    }
}

/// Draws a ``Waymark`` in its ``Waymark/Look``: **floating marks** each a square turned to face the view — a dot stays
/// round from any angle, an arrow points along the line on screen — or **marks on the ground** as a ribbon lying flat over
/// it, as paint; a floating line as a ribbon facing the view. Shapes, glow, sweep and pulses are worked out per pixel,
/// and **every glow falls to nothing before the edge of what it is drawn on**, so no square shows round a mark. The beam
/// is a column turned to face the view.
///
/// **Into the HDR scene after the opaque geometry**, depth tested and never written, as ``BoundaryRenderer`` draws, and
/// blended premultiplied: its light adds, and **its marks also cover a little of what is behind them** — light added to a
/// bright, foggy sky only whitens it, and a line or beam that is only light vanishes against one.
///
/// **It keeps a size on screen**: a mark further off than its width would show as a few pixels is drawn wider, so the
/// line still reads at a hundred meters and the beam from across a map; a mark's spacing never changes, so a pattern
/// that would crowd itself stops growing first.
///
/// The line's points are copied into a buffer for each frame in flight when the mark changes; the beam is made in the
/// shader from the vertex number.
public final class WaymarkRenderer {

    /// One edge of the ribbon as the shader reads it: **two `float4`s**, pinned by a test.
    nonisolated struct Vertex: Equatable {
        /// The line's point, and the meters along it.
        var positionAndU: SIMD4<Float>
        /// The way it heads there, and which edge: −1 or 1.
        var tangentAndSide: SIMD4<Float>
    }

    /// The frame as the shader reads it — `DUWaymarkFrame`.
    nonisolated struct Frame {
        var viewProjection: simd_float4x4
        var camera: SIMD4<Float>
        var color: SIMD4<Float>
        var shape: SIMD4<Float>
        var reveal: SIMD4<Float>
        var beamColor: SIMD4<Float>
        var beamShape: SIMD4<Float>
        var beamBase: SIMD4<Float>
        var screen: SIMD4<Float>
    }

    /// What the vertices in a frame slot were made from — remade when it changes.
    private nonisolated struct Made: Equatable {
        var count: Int
        var first: SIMD3<Float>
        var middle: SIMD3<Float>
        var last: SIMD3<Float>
        var length: Float
        var floats: Bool
        var spacing: Float
    }

    /// The fewest pixels wide the line and the beam's core are drawn, however far off.
    public nonisolated static let narrowest: (line: Float, beam: Float) = (2.5, 6)

    private let ribbonPipeline: MTLRenderPipelineState
    private let markPipeline: MTLRenderPipelineState
    private let beamPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let vertexBuffer: MTLBuffer
    private let frameBuffer: MTLBuffer
    private static let vertexBytes = MemoryLayout<Vertex>.stride * Waymark.maxPoints * 2
    private static let frameStride = (MemoryLayout<Frame>.size + 255) & ~255
    private var madeFor: [Made?] = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)
    /// How many floating marks each frame slot holds.
    private var markCounts = Array(repeating: 0, count: FrameRenderer.maxFramesInFlight)

    /// - Parameters:
    ///   - colorPixelFormat: what the pass it draws into is — the engine's HDR scene unless a game draws its own.
    ///   - sampleCount: that pass's samples per pixel; a renderer is made again when it changes.
    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                sampleCount: Int = 1) throws {
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "WaymarkShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            func pipeline(_ name: String, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
                let vertexFunction = MTL4LibraryFunctionDescriptor()
                vertexFunction.library = library
                vertexFunction.name = vertex
                let fragmentFunction = MTL4LibraryFunctionDescriptor()
                fragmentFunction.library = library
                fragmentFunction.name = fragment
                let descriptor = MTL4RenderPipelineDescriptor()
                descriptor.label = name
                descriptor.vertexFunctionDescriptor = vertexFunction
                descriptor.fragmentFunctionDescriptor = fragmentFunction
                descriptor.rasterSampleCount = max(sampleCount, 1)
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                // Premultiplied: its light adds and its marks cover, with one blend.
                descriptor.colorAttachments[0].blendingState = .enabled
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            }
            ribbonPipeline = try pipeline("Waymark Line", vertex: "duWaymarkRibbonVertex", fragment: "duWaymarkRibbonFragment")
            markPipeline = try pipeline("Waymark Marks", vertex: "duWaymarkMarkVertex", fragment: "duWaymarkMarkFragment")
            beamPipeline = try pipeline("Waymark Beam", vertex: "duWaymarkBeamVertex", fragment: "duWaymarkBeamFragment")
        } catch {
            throw WaymarkRendererError.pipelineUnavailable(String(describing: error))
        }
        // Reversed-Z, like every other pass: nearer is greater.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw WaymarkRendererError.couldNotCreate("depth state")
        }
        guard let vertices = device.makeBuffer(length: Self.vertexBytes * FrameRenderer.maxFramesInFlight,
                                               options: .storageModeShared),
              let frames = device.makeBuffer(length: Self.frameStride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw WaymarkRendererError.couldNotCreate("waymark buffers")
        }
        vertices.label = "Waymark Line"
        frames.label = "Waymark Frame"
        self.depthState = depthState
        vertexBuffer = vertices
        frameBuffer = frames
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw WaymarkRendererError.couldNotCreate("argument table")
        }
    }

    public var allocations: [any MTLAllocation] { [vertexBuffer, frameBuffer] }

    /// Draws the waymark as it is at its age — nothing once it is over.
    ///
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    ///
    /// - Parameters:
    ///   - camera: where the view is — the line faces it, and grows with distance from it.
    ///   - time: seconds on any steady clock — the pulses running along it and climbing the beam.
    ///   - pixelAngle: the angle a pixel spans, radians — the vertical field of view over the view's height. What keeps
    ///     a far mark at least ``narrowest`` pixels wide.
    ///   - brightness: what its colors are multiplied by into the scene's light, for a game whose exposure needs it.
    /// - Returns: whether it drew.
    @discardableResult
    public func draw(_ mark: Waymark, into encoder: MTL4RenderCommandEncoder, frameSlot: Int,
                     viewProjection: simd_float4x4, camera: SIMD3<Float>, time: Float,
                     pixelAngle: Float = 1.1 / 1080, brightness: Float = 1) -> Bool {
        guard !mark.isOver else { return false }
        let look = mark.look
        let count = mark.points.count
        // **Floating marks are drawn one by one**, each facing the view; a line, or marks on the ground, as a ribbon.
        let floats = look.placement == .floating && look.pattern != .line
        let drawsLine = count > 1 && mark.front > 0
        let beam = mark.beamOpacity
        guard drawsLine || beam > 0 else { return false }

        var drawn = count * 2
        if drawsLine {
            let made = Made(count: count, first: mark.points[0], middle: mark.points[count / 2],
                            last: mark.points[count - 1], length: mark.length, floats: floats, spacing: look.spacing)
            let base = vertexBuffer.contents().advanced(by: Self.vertexBytes * frameSlot)
                .bindMemory(to: Vertex.self, capacity: Waymark.maxPoints * 2)
            if floats {
                if madeFor[frameSlot] != made {
                    let marks = mark.marks
                    for (i, m) in marks.enumerated() {
                        base[i] = Vertex(positionAndU: SIMD4(m.position, m.distance), tangentAndSide: SIMD4(m.tangent, 0))
                    }
                    markCounts[frameSlot] = marks.count
                    madeFor[frameSlot] = made
                }
                drawn = markCounts[frameSlot]
            } else if madeFor[frameSlot] != made {
                for i in 0..<count {
                    let a = mark.points[max(i - 1, 0)], b = mark.points[min(i + 1, count - 1)]
                    var tangent = b - a
                    tangent = simd_length(tangent) > 1e-5 ? simd_normalize(tangent) : SIMD3(0, 0, 1)
                    let p = SIMD4(mark.points[i], mark.distances[i])
                    base[i * 2] = Vertex(positionAndU: p, tangentAndSide: SIMD4(tangent, -1))
                    base[i * 2 + 1] = Vertex(positionAndU: p, tangentAndSide: SIMD4(tangent, 1))
                }
                madeFor[frameSlot] = made
            }
        }

        let pattern: Float = switch look.pattern { case .dots: 0; case .dashes: 1; case .arrows: 2; case .chevrons: 3; case .line: 4 }
        let light = max(brightness, 0)
        var frame = Frame(
            viewProjection: viewProjection,
            camera: SIMD4(camera, time),
            color: SIMD4(look.color * look.intensity * light, look.glow),
            shape: SIMD4(pattern, look.width, look.spacing, look.roundness),
            reveal: SIMD4(mark.front, mark.ending, look.flow, mark.length),
            beamColor: SIMD4(look.beam.color * look.beam.intensity * light, beam),
            beamShape: SIMD4(look.beam.width, look.beam.height, look.beam.roundness, look.beam.glow),
            beamBase: SIMD4(mark.target, look.beam.flow),
            screen: SIMD4(pixelAngle * Self.narrowest.line, pixelAngle * Self.narrowest.beam,
                          look.placement == .floating ? 1 : 0, 0))
        let frameOffset = Self.frameStride * frameSlot
        frameBuffer.contents().advanced(by: frameOffset).copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)

        encoder.pushDebugGroup("Waymark")
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameOffset), index: 1)
        if drawsLine && drawn > 0 {
            argumentTable.setAddress(vertexBuffer.gpuAddress + UInt64(Self.vertexBytes * frameSlot), index: 0)
            if floats {
                encoder.setRenderPipelineState(markPipeline)
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drawn)
            } else {
                encoder.setRenderPipelineState(ribbonPipeline)
                encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: drawn)
            }
        }
        if beam > 0 {
            encoder.setRenderPipelineState(beamPipeline)
            argumentTable.setAddress(vertexBuffer.gpuAddress, index: 0)
            // The column, then the glow at its foot: two quads made from the vertex number.
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 12)
        }
        encoder.popDebugGroup()
        return true
    }
}

//
//  WeatherRenderer.swift
//  Ductane
//

import Metal
import simd

/// Why a ``WeatherRenderer`` could not be made.
public nonisolated enum WeatherRendererError: Error, CustomStringConvertible, Sendable {
    case pipelineUnavailable(String)
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .pipelineUnavailable(let reason): "the weather's pipelines could not be made — \(reason)"
        case .couldNotCreate(let what): "the device would not create the weather's \(what)"
        }
    }
}

/// **Draws a ``Weather``'s rain or snow**, falling round the eye, pushed by its wind, kept out from under a roof by a
/// ``WeatherCover``, and — for rain — splashing where it lands.
///
/// **Nothing is simulated.** Every drop is made in the vertex shader from its number and the time, in a box that follows
/// the eye and wraps, so a drop that falls out of the bottom comes back at the top, and the box never runs dry however
/// the eye moves. What it costs is the drops drawn: up to ``maxDrops`` streaks, ``maxFlakes`` flakes and
/// ``maxSplashes`` splashes, in as many as the weather's precipitation asks for.
///
/// **Into the HDR scene after the opaque geometry**, depth tested and never written, blended premultiplied, as
/// ``WaymarkRenderer`` draws. A drop is lit by the sky's light and a little of the sun's, so rain at dusk is dusk's colour
/// and lightning (``Weather/lighting(_:flash:)``) lights it up.
///
/// The cover is a game's to draw (``WeatherCover/encode(into:frameSlot:batches:)``). Without one rain falls everywhere,
/// through roofs too, and there are no splashes — they land on what the cover says is uppermost.
public final class WeatherRenderer {

    /// The frame as the shader reads it — `DUWeatherFrame`.
    nonisolated struct Frame {
        var viewProjection: simd_float4x4
        var coverViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var wind: SIMD4<Float>
        var shape: SIMD4<Float>
        var light: SIMD4<Float>
        var cover: SIMD4<Float>
        var screen: SIMD4<Float>
        var fog: SIMD4<Float>
    }

    /// The most of each drawn in a frame, at the heaviest.
    public nonisolated static let maxDrops = 24_000
    public nonisolated static let maxFlakes = 16_000
    public nonisolated static let maxSplashes = 2_400
    /// **Places looked at for a roof's edge to drip from**, round the eye: most are not one and draw nothing.
    public nonisolated static let dripCandidates = 6_000
    /// How far round the eye rain falls, and how tall its box is, metres.
    public nonisolated static let rainBox: (halfWidth: Float, height: Float) = (18, 20)
    public nonisolated static let snowBox: (halfWidth: Float, height: Float) = (16, 16)
    /// How fast each falls, metres a second.
    public nonisolated static let rainSpeed: Float = 9
    public nonisolated static let snowSpeed: Float = 1.1
    /// The time is wrapped at this many seconds, so a long session never loses a float's precision; a jump every ten
    /// minutes in a box of rain is invisible.
    nonisolated static let wrap: Double = 600

    private let rainPipeline: MTLRenderPipelineState
    private let snowPipeline: MTLRenderPipelineState
    private let splashPipeline: MTLRenderPipelineState
    private let dripPipeline: MTLRenderPipelineState
    private let dripSplashPipeline: MTLRenderPipelineState
    private let boltPipeline: MTLRenderPipelineState
    /// A bolt's pieces, a stretch per frame in flight.
    private let boltBuffer: MTLBuffer
    /// The most pieces of bolt drawn in a frame — a few strikes at once.
    public nonisolated static let maxBoltSegments = 4096
    private static let boltStride = 32
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let frameBuffer: MTLBuffer
    private let blankCover: MTLTexture
    private static let frameStride = (MemoryLayout<Frame>.size + 255) & ~255

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                sampleCount: Int = 1) throws {
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "WeatherShaders")
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
                descriptor.colorAttachments[0].blendingState = .enabled
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            }
            rainPipeline = try pipeline("Rain", vertex: "duWeatherRainVertex", fragment: "duWeatherRainFragment")
            snowPipeline = try pipeline("Snow", vertex: "duWeatherSnowVertex", fragment: "duWeatherSnowFragment")
            splashPipeline = try pipeline("Splashes", vertex: "duWeatherSplashVertex", fragment: "duWeatherSplashFragment")
            dripPipeline = try pipeline("Drips", vertex: "duWeatherDripVertex", fragment: "duWeatherRainFragment")
            dripSplashPipeline = try pipeline("Drip Splashes", vertex: "duWeatherDripSplashVertex",
                                              fragment: "duWeatherSplashFragment")
            boltPipeline = try pipeline("Lightning", vertex: "duBoltVertex", fragment: "duBoltFragment")
        } catch {
            throw WeatherRendererError.pipelineUnavailable(String(describing: error))
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw WeatherRendererError.couldNotCreate("depth state")
        }
        self.depthState = depthState
        // Twice over: the rain's frame and the lightning's, both drawn in one frame.
        guard let frames = device.makeBuffer(length: Self.frameStride * FrameRenderer.maxFramesInFlight * 2,
                                             options: .storageModeShared) else {
            throw WeatherRendererError.couldNotCreate("frame buffer")
        }
        frames.label = "Weather Frame"
        frameBuffer = frames
        guard let bolts = device.makeBuffer(length: Self.maxBoltSegments * Self.boltStride * FrameRenderer.maxFramesInFlight,
                                            options: .storageModeShared) else {
            throw WeatherRendererError.couldNotCreate("lightning buffer")
        }
        bolts.label = "Lightning"
        boltBuffer = bolts
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1,
                                                             mipmapped: false)
        blank.usage = .shaderRead
        blank.storageMode = .private
        guard let blankCover = device.makeTexture(descriptor: blank) else {
            throw WeatherRendererError.couldNotCreate("blank cover")
        }
        blankCover.label = "No Weather Cover"
        self.blankCover = blankCover
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        table.maxTextureBindCount = 1
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw WeatherRendererError.couldNotCreate("argument table")
        }
    }

    public var allocations: [any MTLAllocation] { [frameBuffer, blankCover, boltBuffer] }

    /// How many of each a weather draws: drops or flakes — or grains of dust — and splashes.
    public nonisolated static func counts(_ weather: Weather) -> (falling: Int, splashes: Int) {
        let s = weather.settings
        if s.precipitation <= 0, s.dust > 0 { return (Int(Float(maxFlakes) * s.dust), 0) }
        guard s.precipitation > 0 else { return (0, 0) }
        if s.snow { return (Int(Float(maxFlakes) * s.precipitation), 0) }
        return (Int(Float(maxDrops) * s.precipitation), Int(Float(maxSplashes) * s.precipitation))
    }

    /// Draws `weather`'s rain or snow as it is at `time`.
    ///
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    ///
    /// - Parameters:
    ///   - eye: where the view is: the drops fall round it.
    ///   - time: seconds on the clock the weather runs by.
    ///   - lighting: the frame's sky, with the weather and any flash already in it (``Weather/lighting(_:flash:)``).
    ///   - fogDensity: the frame's fog (``Weather/fogDensity(over:)``): far drops fade into it.
    ///   - cover: what is overhead, updated and drawn this frame; nil lets rain fall everywhere.
    ///   - pixelAngle: the angle a pixel spans — the vertical field of view over the view's height. What keeps a far
    ///     drop at least a pixel and a half wide.
    ///   - brightness: what the light on a drop is multiplied by, for a game whose exposure needs it.
    /// - Returns: whether it drew.
    @discardableResult
    public func draw(_ weather: Weather, into encoder: MTL4RenderCommandEncoder, frameSlot: Int,
                     viewProjection: simd_float4x4, eye: SIMD3<Float>, time: Double, lighting: DaySky.Lighting,
                     fogDensity: Float = 0, cover: WeatherCover? = nil, pixelAngle: Float = 1.1 / 1080,
                     brightness: Float = 1) -> Bool {
        let (falling, splashes) = Self.counts(weather)
        guard falling > 0 else { return false }
        let s = weather.settings
        // **Dust** (2026-11-16) is drawn as flakes are, but small, barely falling and carried hard on the wind, in the
        // world's dust colour.
        let dust = s.precipitation <= 0 && s.dust > 0
        let flaky = s.snow || dust
        let box = flaky ? Self.snowBox : Self.rainBox
        let halfWidth = min(box.halfWidth, cover?.halfExtent ?? box.halfWidth)
        let speed = dust ? 0.25 : s.snow ? Self.snowSpeed : Self.rainSpeed
        // A raindrop falls fast and leans only so far into the wind; a flake drifts with it; dust goes with it.
        let wind = weather.wind * (dust ? 1.1 : s.snow ? 0.6 : 0.35)
        let sky = lighting.skyLight == .zero ? lighting.zenith : lighting.skyLight
        var light = (sky * (flaky ? 1.0 : 0.6) + lighting.colour * (flaky ? 0.4 : 0.1)) * max(brightness, 0)
        if dust { light = weather.dustColour * (Weather.luminance(sky) + Weather.luminance(lighting.colour) * 0.3) * 1.6 }
        let wrapped = Float(time.isFinite ? time.truncatingRemainder(dividingBy: Self.wrap) : 0)
        var frame = Frame(
            viewProjection: viewProjection,
            coverViewProjection: cover?.viewProjection ?? matrix_identity_float4x4,
            eye: SIMD4(eye, wrapped),
            wind: SIMD4(wind, speed),
            shape: SIMD4(halfWidth, box.height, Float(falling), dust ? 0.02 : s.snow ? 0.035 : 0.55),
            light: SIMD4(light, dust ? 0.45 : s.snow ? 0.8 : 0.16),
            cover: SIMD4(cover?.top ?? 0, WeatherCover.depthRange, cover == nil ? 0 : 1, Float(cover?.resolution ?? 1)),
            screen: SIMD4(pixelAngle, fogDensity, min(12, halfWidth * 0.7), s.snow ? 0 : s.precipitation),
            fog: SIMD4(lighting.horizon, 0))
        let offset = Self.frameStride * frameSlot
        frameBuffer.contents().advanced(by: offset).copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)

        encoder.pushDebugGroup(dust ? "Dust" : s.snow ? "Snow" : "Rain")
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(offset), index: 0)
        argumentTable.setTexture((cover?.texture ?? blankCover).gpuResourceID, index: 0)
        encoder.setRenderPipelineState(flaky ? snowPipeline : rainPipeline)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: falling)
        if splashes > 0, cover != nil {
            encoder.setRenderPipelineState(splashPipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: splashes)
            // **Drips from roof edges** (2026-11-16): where the cover steps down a metre or more, a drop falls to what is
            // below and splashes there — found from the cover, nothing placed.
            encoder.setRenderPipelineState(dripPipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.dripCandidates)
            encoder.setRenderPipelineState(dripSplashPipeline)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.dripCandidates)
        }
        encoder.popDebugGroup()
        return true
    }

    /// **Draws the bolts of `weather`'s strikes flickering at `time`** (``LightningBolt``): each strike's bolt from
    /// `cloudBase` down to where `landing` says it lands — the ground under it, or for a close one the tallest thing near
    /// it — or along under the clouds for one that stays in them; behind what is in front of it, added to the scene.
    ///
    /// Into the HDR scene after the opaque geometry, as ``draw(_:into:frameSlot:viewProjection:eye:time:lighting:fogDensity:cover:pixelAngle:brightness:)``.
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    /// - Returns: the strikes drawn — a game's cue for what a close one does.
    @discardableResult
    public func drawLightning(_ weather: Weather, into encoder: MTL4RenderCommandEncoder, frameSlot: Int,
                              viewProjection: simd_float4x4, eye: SIMD3<Float>, time: Double, fogDensity: Float = 0,
                              pixelAngle: Float = 1.1 / 1080, cloudBase: Float = 1500,
                              landing: (Weather.Strike) -> SIMD3<Float>) -> [Weather.Strike] {
        let strikes = weather.strikes(from: time - Weather.flashLength, to: time + 1e-9)
        guard !strikes.isEmpty else { return [] }
        let base = frameSlot * Self.maxBoltSegments * Self.boltStride
        let out = boltBuffer.contents().advanced(by: base).bindMemory(to: SIMD4<Float>.self, capacity: Self.maxBoltSegments * 2)
        var count = 0
        for strike in strikes {
            let bright = strike.boltBrightness(after: time - strike.time)
            guard bright > 0.01 else { continue }
            let bolt = LightningBolt.make(strike, cloudBase: cloudBase, landing: landing(strike))
            for segment in bolt.segments where count < Self.maxBoltSegments {
                out[count * 2] = SIMD4(segment.a, segment.width)
                out[count * 2 + 1] = SIMD4(segment.b, segment.brightness * bright)
                count += 1
            }
        }
        guard count > 0 else { return strikes }
        var frame = Frame(viewProjection: viewProjection, coverViewProjection: matrix_identity_float4x4,
                          eye: SIMD4(eye, 0), wind: .zero, shape: .zero, light: .zero, cover: .zero,
                          screen: SIMD4(pixelAngle, fogDensity, 0, 0), fog: .zero)
        let offset = Self.frameStride * (FrameRenderer.maxFramesInFlight + frameSlot)
        frameBuffer.contents().advanced(by: offset).copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)
        encoder.pushDebugGroup("Lightning")
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(offset), index: 0)
        argumentTable.setAddress(boltBuffer.gpuAddress + UInt64(base), index: 1)
        encoder.setRenderPipelineState(boltPipeline)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        encoder.popDebugGroup()
        return strikes
    }
}

import Metal
import simd

/// **Draws the clouds volumetric** (2026-11-16): a raymarch through the ``CloudLayer`` from its base to its top, into a
/// picture at half the screen's width and height (``GraphicsSettings/CloudQuality/high``) or a quarter
/// (``GraphicsSettings/CloudQuality/medium``), which ``SkyPass`` lays over the sky — the light the clouds send toward the
/// eye, and how much sky still shows through them. Lit by the sun (the moon by night) through a few steps toward it, dark
/// underneath in rain, drifting with the wind. At ``GraphicsSettings/CloudQuality/flat`` there is no picture: ``SkyPass``
/// draws a flat layer from the same coverage instead.
///
/// **Each frame's picture is blended with the last** (2026-11-16), found where the same direction was: a frame's steps
/// leave grain at every cloud's edge, which shimmered like static when each frame was drawn alone. A frame is drawn
/// alone when there is no last picture to use — the first, a new size or quality, the light or the clouds changing at
/// once (lightning's flash), the eye moving far in one frame.
///
/// **Before the scene pass**: ``encode(into:frameSlot:viewProjection:eye:lighting:layer:quality:width:height:)`` records
/// its own render pass, and the picture it returns is what the frame's ``SkyPass`` reads.
public final class CloudPass {
    /// Mirrors `CloudUniforms` in `SkyShaders.metal`.
    struct Uniforms {
        var inverseViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var light: SIMD4<Float>
        var lightColour: SIMD4<Float>
        var zenith: SIMD4<Float>
        var horizon: SIMD4<Float>
        var clouds: SIMD4<Float>
        var motion: SIMD4<Float>
        var march: SIMD4<Float>
        var previousViewProjection: simd_float4x4
    }
    static let stride = (MemoryLayout<Uniforms>.stride + 255) & ~255

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let table: MTL4ArgumentTable
    private let uniforms: MTLBuffer
    /// The clouds' shape: a tileable 3D noise, made once (``CloudNoise``).
    public let noise: MTLTexture
    /// Where clouds gather (``CloudLayer/coverageMap``) — bind it for the clouds' shadows, read at `metres / 61,440`.
    public let coverageMap: MTLTexture
    /// One picture per frame in flight, so a frame still being drawn is never written over.
    private var pictures: [MTLTexture?] = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)
    private var frame: UInt32 = 0
    /// **What the last frame drew**, for this one to blend with: its picture, its view, and what it was drawn under.
    private var last: (picture: MTLTexture, viewProjection: simd_float4x4, eye: SIMD3<Float>, light: SIMD3<Float>,
                       clouds: SIMD4<Float>)?
    /// **The share of a new picture against the last** — the last one fades to under a tenth in about 20 frames.
    public static let blend: Float = 0.12

    /// Everything the GPU must be able to reach: add it to the renderer's residency set — again after a picture is made
    /// anew (``picturesChanged``).
    public var allocations: [any MTLAllocation] { [uniforms, noise, coverageMap] + pictures.compactMap { $0 } }
    /// Set when a picture was made anew, its size changed: the renderer adds ``allocations`` again and clears it.
    public var picturesChanged = false

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "SkyShaders")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = "cloudVertex"
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = "cloudFragment"
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "Clouds"
        descriptor.vertexFunctionDescriptor = vertex
        descriptor.fragmentFunctionDescriptor = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor)
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 3
        table = try device.makeArgumentTable(descriptor: tableDescriptor)
        guard let map = CloudLayer.coverageTexture(device: device) else { throw FrameRendererError.couldNotCreate("cloud map") }
        coverageMap = map
        guard let buffer = device.makeBuffer(length: Self.stride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw FrameRendererError.couldNotCreate("cloud uniforms")
        }
        buffer.label = "Clouds"
        uniforms = buffer
        noise = try CloudNoise.texture(device: device)
    }

    /// **Records the clouds** for a frame drawn `width` × `height` and returns the picture ``SkyPass`` lays over the sky —
    /// nil at ``GraphicsSettings/CloudQuality/flat``, where the sky draws a flat layer itself.
    public func encode(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, viewProjection: simd_float4x4,
                       eye: SIMD3<Float>, lighting: DaySky.Lighting, layer: CloudLayer,
                       quality: GraphicsSettings.CloudQuality, width: Int, height: Int) -> MTLTexture? {
        guard quality != .flat else { last = nil; return nil }
        let divisor = quality == .high ? 2 : 4
        let w = max(width / divisor, 8), h = max(height / divisor, 8)
        let slot = frameSlot % pictures.count
        if pictures[slot]?.width != w || pictures[slot]?.height != h {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            pictures[slot] = device.makeTexture(descriptor: descriptor)
            pictures[slot]?.label = "Clouds"
            picturesChanged = true
        }
        guard let picture = pictures[slot] else { return nil }
        frame &+= 1
        let clouds = SIMD4(layer.coverage, layer.darkness, layer.base, layer.thickness)
        let light = lighting.colour
        // The last picture, if this one may build on it: the same size, from a frame drawn just before, under the same
        // light and clouds near enough — a change too sudden to blend into (lightning's flash, a new weather set by hand,
        // a jump across the map) is drawn alone, so it never lags behind.
        let previous = last.flatMap { last -> (picture: MTLTexture, viewProjection: simd_float4x4)? in
            guard last.picture !== picture, last.picture.width == w, last.picture.height == h,
                  simd_distance(last.eye, eye) < 100,
                  simd_length(last.light - light) <= 0.05 * max(simd_length(light), simd_length(last.light), 0.05),
                  simd_reduce_max(abs(last.clouds - clouds) / SIMD4(1, 1, 100, 100)) < 0.02 else { return nil }
            return (last.picture, last.viewProjection)
        }
        last = (picture, viewProjection, eye, light, clouds)
        var values = Uniforms(inverseViewProjection: viewProjection.inverse, eye: SIMD4(eye, 1),
                              light: SIMD4(lighting.direction, 0), lightColour: SIMD4(light, 0),
                              zenith: SIMD4(lighting.zenith, 0), horizon: SIMD4(lighting.horizon, 0),
                              clouds: clouds, motion: layer.motion,
                              march: SIMD4(quality == .high ? 32 : 20, Float(frame % 1024), previous == nil ? 1 : Self.blend, 0),
                              previousViewProjection: previous?.viewProjection ?? viewProjection)
        let offset = slot * Self.stride
        uniforms.contents().advanced(by: offset).copyMemory(from: &values, byteCount: MemoryLayout<Uniforms>.size)

        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = picture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { last = nil; return nil }
        encoder.label = "Clouds"
        // The last frame's picture is read here, and this one is written over a picture an earlier frame's sky read: both
        // must be finished first.
        encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        table.setAddress(uniforms.gpuAddress + UInt64(offset), index: 0)
        table.setTexture(noise.gpuResourceID, index: 0)
        table.setTexture(coverageMap.gpuResourceID, index: 1)
        table.setTexture((previous?.picture ?? coverageMap).gpuResourceID, index: 2)   // never the picture being drawn
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return picture
    }
}

/// **The clouds' shape**: a 32³ noise that repeats in all three directions — in red a billowing Perlin–Worley, in green a
/// finer Worley that erodes the edges. Made once on the CPU and kept.
enum CloudNoise {
    static let size = 32

    static func texture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FrameRendererError.couldNotCreate("cloud noise")
        }
        texture.label = "Cloud Noise"
        let bytes = Self.bytes
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        }
        return texture
    }

    /// The texels, made once for every pass.
    static let bytes: [UInt8] = {
        var out = [UInt8](repeating: 0, count: size * size * size * 4)
        for z in 0..<size {
            for y in 0..<size {
                for x in 0..<size {
                    let p = SIMD3(Float(x), Float(y), Float(z)) / Float(size)
                    let perlin = (gradient(p, period: 4) * 0.6 + gradient(p, period: 8) * 0.3 + gradient(p, period: 16) * 0.1)
                        * 0.5 + 0.5
                    let billow = 1 - worley(p, period: 4)
                    let base = min(max(perlin * 0.55 + billow * 0.6 - 0.1, 0), 1)
                    let fine = 1 - (worley(p, period: 8) * 0.65 + worley(p, period: 16) * 0.35)
                    let i = ((z * size + y) * size + x) * 4
                    out[i] = UInt8(base * 255)
                    out[i + 1] = UInt8(min(max(fine, 0), 1) * 255)
                    out[i + 2] = 0
                    out[i + 3] = 255
                }
            }
        }
        return out
    }()

    static func hash(_ c: SIMD3<Int32>, _ salt: UInt32 = 0) -> UInt32 {
        var h = (UInt32(bitPattern: c.x) &* 73_856_093) ^ (UInt32(bitPattern: c.y) &* 19_349_663)
            ^ (UInt32(bitPattern: c.z) &* 83_492_791) ^ (salt &* 2_654_435_761)
        h = h &* 747_796_405 &+ 2_891_336_453
        h ^= h >> 16
        h = h &* 2_246_822_519
        h ^= h >> 13
        return h
    }

    static func wrap(_ c: SIMD3<Int32>, _ period: Int32) -> SIMD3<Int32> {
        SIMD3((c.x % period + period) % period, (c.y % period + period) % period, (c.z % period + period) % period)
    }

    /// Tileable gradient noise, about −1…1, `period` cells across the unit cube.
    static func gradient(_ p: SIMD3<Float>, period: Int32) -> Float {
        let q = p * Float(period)
        let i = SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
        let f = q - SIMD3(Float(i.x), Float(i.y), Float(i.z))
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        func dot(_ corner: SIMD3<Int32>) -> Float {
            let h = hash(wrap(i &+ corner, period))
            let g = simd_normalize(SIMD3(Float(h & 1023), Float((h >> 10) & 1023), Float((h >> 20) & 1023)) / 511.5 - 1)
            let d = f - SIMD3(Float(corner.x), Float(corner.y), Float(corner.z))
            return simd_dot(g, d)
        }
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let x00 = lerp(dot([0, 0, 0]), dot([1, 0, 0]), u.x), x10 = lerp(dot([0, 1, 0]), dot([1, 1, 0]), u.x)
        let x01 = lerp(dot([0, 0, 1]), dot([1, 0, 1]), u.x), x11 = lerp(dot([0, 1, 1]), dot([1, 1, 1]), u.x)
        return lerp(lerp(x00, x10, u.y), lerp(x01, x11, u.y), u.z) * 1.6
    }

    /// Tileable Worley noise: the distance to the nearest of one point per cell, 0…1.
    static func worley(_ p: SIMD3<Float>, period: Int32) -> Float {
        let q = p * Float(period)
        let i = SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
        var nearest: Float = 9
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let c = i &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))
                    let h = hash(wrap(c, period), 7)
                    let jitter = SIMD3(Float(h & 1023), Float((h >> 10) & 1023), Float((h >> 20) & 1023)) / 1023
                    let point = SIMD3(Float(c.x), Float(c.y), Float(c.z)) + jitter
                    nearest = min(nearest, simd_length(point - q))
                }
            }
        }
        return min(nearest, 1)
    }
}

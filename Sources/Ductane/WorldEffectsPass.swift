//
//  WorldEffectsPass.swift
//  Ductane
//

import CoreGraphics
import Metal
import MetalKit
import simd

/// **A world's living effects, playing**: every ``WorldScene/Effect`` an emitter in one ``ParticleSystem``, stepped on
/// the fixed clock, prewarmed so a swarm is a swarm the moment it appears, and drawn by ``ParticleRenderer`` with **simple
/// sprites drawn here** — a butterfly, a leaf, a petal, a wisp of wind, a fly, a frog, a sunbeam, soft and hard circles —
/// so a world shows what moves and roughly what it is.
final class WorldEffectsPass {

    private let device: MTLDevice
    private(set) var renderer: ParticleRenderer
    private let sprites: MTLTexture
    private var system = ParticleSystem(recipes: [], capacity: 1)
    private var emitters: [ParticleEmitter] = []
    private var origins: [SIMD3<Float>] = []
    private var directions: [SIMD3<Float>] = []
    /// What the system was built from — rebuilt when anything but where an effect stands changes, or the sun moves.
    private var built: [Shape] = []
    private var builtSun: SIMD3<Float>?
    private struct Shape: Equatable {
        let seed: Int; let kind: String; let variety: Int; let rate: Float; let radius: Float; let direction: SIMD3<Float>
        let recipe: ParticleRecipe; let followers: [ParticleRecipe]; let followsSun: Bool; let prewarm: Float
    }
    /// The pack meshes the system was built able to draw (``WorldScene/Effect/meshes``).
    private var builtMeshes: Set<String> = []

    /// Sprites a frame can draw: a dozen dense effects — a wasteland's goop glow alone keeps 2,400 alive and its seven
    /// smoke columns another thousand.
    static let capacity = 8192
    /// The sheet: four butterflies across the top, two leaves and two petals below, then a sunbeam, a wisp of wind, a
    /// fly and a frog; then the soft and hard circles (12, 13).
    static let atlas = DecalAtlas(columns: 4, rows: 4)

    /// **The particle circles packs draw smoke, fog and glow with, alpha from centre to edge** — measured from one
    /// pack's soft and hard circle at sixteenths of the radius. The soft one is half gone by 0.55 of its radius; the hard
    /// one is solid to 0.85.
    static let circles: (soft: [Float], hard: [Float]) = (
        [1, 0.996, 0.99, 0.97, 0.922, 0.846, 0.728, 0.58, 0.421, 0.275, 0.158, 0.077, 0.032, 0.011, 0.002, 0, 0],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.723, 0.295, 0.25])

    init(device: MTLDevice, sampleCount: Int) throws {
        self.device = device
        sprites = try Self.makeSprites(device: device)
        renderer = try ParticleRenderer(device: device, capacity: Self.capacity, sampleCount: sampleCount,
                                        sprites: sprites, atlas: Self.atlas)
    }

    var allocations: [any MTLAllocation] { renderer.allocations }

    /// A renderer for another sample count; the old one is the caller's to keep until no frame in flight uses it.
    func rebuild(sampleCount: Int) throws -> ParticleRenderer {
        let old = renderer
        renderer = try ParticleRenderer(device: device, capacity: Self.capacity, sampleCount: sampleCount,
                                        sprites: sprites, atlas: Self.atlas)
        return old
    }

    /// The sprite cell a kind and look are drawn with here — by the kind a world file names (``WorldFile/Effect/kind``);
    /// nil for a soft disc. `follower` is which of its ``WorldScene/Effect/followers`` (1 on), nil for its own recipe.
    static func sprite(_ kind: String, _ variety: Int, follower: Int? = nil) -> Int? {
        // The circles where a pack's effects use them: the fog the soft one, the rest the hard one.
        if follower != nil { return kind == "goopBubbles" ? 13 : nil }
        return switch kind {
        case "butterflies": min(max(variety, 0), 3)
        case "leaves": 4 + min(max(variety, 0), 1)
        case "petals": 6 + min(max(variety, 0), 1)
        case "sunbeams": 8
        case "wind": 9
        case "flies": 10
        case "frogs": 11
        case "fog": 12
        case "smoke", "goopEmbers", "goopDrip", "drips": 13
        default: nil
        }
    }

    /// Follows the scene: a new system when an effect is added, removed or changed — prewarmed — and only new origins
    /// when one is dragged, so a swarm follows its handle rather than starting again.
    ///
    /// **Each effect's recipe and its followers** (``WorldScene/Effect/followers``: a frog's sit, a bubble's splash) go in
    /// one after another, their `then` shifted to where they landed. **A recipe drawn as a pack mesh** (`mesh`) keeps it
    /// when `meshes` holds it — the renderer draws those (``meshCopies()``) — and is a sprite or a disc otherwise.
    func sync(_ effects: [WorldScene.Effect], lighting: DaySky.Lighting, meshes: Set<String> = []) {
        let shapes = effects.map {
            Shape(seed: $0.seed, kind: $0.kind, variety: $0.variety, rate: $0.rate, radius: $0.radius, direction: $0.direction,
                  recipe: $0.recipe, followers: $0.followers, followsSun: $0.followsSun, prewarm: $0.prewarm)
        }
        origins = effects.map(\.position)
        directions = effects.map(\.direction)
        let sun = effects.contains { $0.followsSun } ? lighting.direction : nil
        guard shapes != built || sun != builtSun || meshes != builtMeshes else { return }
        built = shapes
        builtSun = sun
        builtMeshes = meshes
        var recipes: [ParticleRecipe] = [], firsts: [Int] = []
        for effect in effects {
            let offset = recipes.count
            firsts.append(offset)
            for (index, var recipe) in ([effect.recipe] + effect.followers).enumerated() {
                if let mesh = recipe.mesh, !meshes.contains(mesh) { recipe.mesh = nil }
                recipe.sprite = Self.sprite(effect.kind, effect.variety, follower: index == 0 ? nil : index)
                // Leaning along the sun, and as bright as its light: gone at dusk, absent by night.
                recipes.append((effect.followsSun ? recipe.shafts(of: lighting) : recipe).shiftingThen(by: offset))
            }
        }
        system = ParticleSystem(recipes: recipes, capacity: Self.capacity)
        emitters = effects.enumerated().map { index, effect in
            ParticleEmitter(recipe: firsts[index], rate: effect.rate, seedBase: effect.seed)
        }
        let longest = effects.map(\.prewarm).max() ?? 0
        ParticleEmitter.prewarm(&emitters, at: origins, directions: directions, into: &system, seconds: longest)
    }

    func step(deltaTime: Float) {
        guard !emitters.isEmpty else { return }
        for index in emitters.indices {
            emitters[index].emit(into: &system, at: origins[index], direction: directions[index], deltaTime: deltaTime)
        }
        system.step(deltaTime: deltaTime)
    }

    /// **Whether anything alive fades where it meets the solid scene** (`softness`) — then the renderer draws in two
    /// passes, so it can.
    var softens: Bool { system.recipes.contains { $0.softness > 0 } && system.hasLive }

    /// **The particles drawn as pack meshes**, by mesh: where each is (``ParticleSystem/meshTransform(of:)``) and its
    /// colour, which tints its mesh — a bubble's goop green over a white circle.
    func meshCopies() -> [String: [(transform: simd_float4x4, tint: SIMD3<Float>)]] {
        var out: [String: [(transform: simd_float4x4, tint: SIMD3<Float>)]] = [:]
        for particle in system.particles where particle.isAlive {
            let recipe = system.recipes[particle.recipe]
            guard let mesh = recipe.mesh else { continue }
            out[mesh, default: []].append((system.meshTransform(of: particle), recipe.color))
        }
        return out
    }

    /// Draws the sprites and discs; `solidDepth` and `nearPlane` soften them where they meet the solid scene, in a
    /// frame drawn in two passes.
    func draw(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, viewProjection: simd_float4x4,
              camera: WorldRenderer.View, lighting: DaySky.Lighting, solidDepth: MTLTexture? = nil, nearPlane: Float = 0) {
        guard system.hasLive else { return }
        // Lit as a small thing in the open is: the sun on a level face and the sky above.
        let light = lighting.colour * max(lighting.direction.y, 0) / .pi + lighting.skyLight
        let forward = simd_normalize(camera.target - camera.eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        renderer.draw(system, into: encoder, frameSlot: frameSlot, viewProjection: viewProjection,
                      cameraRight: right, cameraUp: simd_cross(right, forward), matterLight: light,
                      solidDepth: solidDepth, nearPlane: nearPlane)
    }

    // MARK: The sprites

    /// **Drawn here, not shipped**: a butterfly is two pairs of wings and a body, a leaf a pointed oval with a vein, a
    /// petal a rounded drop. Enough to see what moves and what it is.
    private static func makeSprites(device: MTLDevice) throws -> MTLTexture {
        let cell = 128, width = cell * 4, height = cell * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ParticleRendererError.couldNotCreate("effect sprite sheet")
        }
        // Core Graphics is y-up; the atlas reads row 0 at the top.
        func origin(_ index: Int) -> CGPoint {
            CGPoint(x: CGFloat(index % 4 * cell), y: CGFloat(height - (index / 4 + 1) * cell))
        }
        let wings: [(CGColor, CGColor)] = [
            // Albedos as the world's are — an orange as bright as paper washes to yellow in sunlight.
            (CGColor(srgbRed: 0.82, green: 0.36, blue: 0.04, alpha: 1), CGColor(srgbRed: 0.08, green: 0.05, blue: 0.04, alpha: 1)),
            (CGColor(srgbRed: 0.1, green: 0.32, blue: 0.78, alpha: 1), CGColor(srgbRed: 0.04, green: 0.06, blue: 0.16, alpha: 1)),
            (CGColor(srgbRed: 0.82, green: 0.8, blue: 0.72, alpha: 1), CGColor(srgbRed: 0.22, green: 0.22, blue: 0.2, alpha: 1)),
            (CGColor(srgbRed: 0.48, green: 0.72, blue: 0.46, alpha: 1), CGColor(srgbRed: 0.3, green: 0.17, blue: 0.2, alpha: 1)),
        ]
        for (index, (fill, edge)) in wings.enumerated() {
            let o = origin(index), c = CGFloat(cell)
            context.setLineWidth(3)
            for side in [-1.0, 1.0] {
                let upper = CGRect(x: o.x + c / 2 + (side < 0 ? -c * 0.44 : c * 0.04), y: o.y + c * 0.45, width: c * 0.4, height: c * 0.42)
                let lower = CGRect(x: o.x + c / 2 + (side < 0 ? -c * 0.32 : c * 0.04), y: o.y + c * 0.14, width: c * 0.28, height: c * 0.32)
                for wing in [upper, lower] {
                    context.setFillColor(fill)
                    context.fillEllipse(in: wing)
                    context.setStrokeColor(edge)
                    context.strokeEllipse(in: wing.insetBy(dx: 1.5, dy: 1.5))
                }
            }
            context.setFillColor(edge)
            context.fillEllipse(in: CGRect(x: o.x + c / 2 - c * 0.035, y: o.y + c * 0.16, width: c * 0.07, height: c * 0.66))
        }
        let leaves = [CGColor(srgbRed: 0.35, green: 0.62, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.85, green: 0.45, blue: 0.12, alpha: 1)]
        for (index, colour) in leaves.enumerated() {
            let o = origin(4 + index), c = CGFloat(cell)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: o.x + c / 2, y: o.y + c * 0.08))
            path.addQuadCurve(to: CGPoint(x: o.x + c / 2, y: o.y + c * 0.92), control: CGPoint(x: o.x + c * 0.95, y: o.y + c * 0.5))
            path.addQuadCurve(to: CGPoint(x: o.x + c / 2, y: o.y + c * 0.08), control: CGPoint(x: o.x + c * 0.05, y: o.y + c * 0.5))
            context.setFillColor(colour)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.15, blue: 0.05, alpha: 0.6))
            context.setLineWidth(2.5)
            context.move(to: CGPoint(x: o.x + c / 2, y: o.y + c * 0.1))
            context.addLine(to: CGPoint(x: o.x + c / 2, y: o.y + c * 0.88))
            context.strokePath()
        }
        let petals = [CGColor(srgbRed: 0.85, green: 0.12, blue: 0.18, alpha: 1), CGColor(srgbRed: 0.98, green: 0.82, blue: 0.15, alpha: 1)]
        for (index, colour) in petals.enumerated() {
            let o = origin(6 + index), c = CGFloat(cell)
            context.setFillColor(colour)
            context.fillEllipse(in: CGRect(x: o.x + c * 0.22, y: o.y + c * 0.15, width: c * 0.56, height: c * 0.7))
        }
        // A sunbeam: soft at both ends and both edges, with a few brighter strands down its length.
        do {
            let o = origin(8), c = CGFloat(cell)
            for strand in 0..<14 {
                let x = o.x + c * (0.18 + 0.64 * CGFloat(strand) / 13)
                let brightness = CGFloat([0.5, 0.8, 0.6, 1, 0.7, 0.55, 0.9, 0.65, 1, 0.6, 0.75, 0.5, 0.85, 0.6][strand])
                let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.5 * brightness),
                                               CGColor(gray: 1, alpha: 0.5 * brightness), CGColor(gray: 1, alpha: 0)] as CFArray,
                                      locations: [0, 0.3, 0.7, 1])!
                context.saveGState()
                context.clip(to: CGRect(x: x - c * 0.03, y: o.y, width: c * 0.06, height: c))
                context.drawLinearGradient(fade, start: CGPoint(x: x, y: o.y), end: CGPoint(x: x, y: o.y + c), options: [])
                context.restoreGState()
            }
        }
        // A wisp of wind, running up the cell — a particle's height lies along its motion.
        do {
            let o = origin(9), c = CGFloat(cell)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
            context.setLineCap(.round)
            for (offset, width) in [(-0.12, 5.0), (0.0, 9.0), (0.1, 4.0)] as [(CGFloat, CGFloat)] {
                context.setLineWidth(width)
                context.move(to: CGPoint(x: o.x + c * (0.5 + offset), y: o.y + c * 0.1))
                context.addCurve(to: CGPoint(x: o.x + c * (0.5 + offset), y: o.y + c * 0.9),
                                 control1: CGPoint(x: o.x + c * (0.62 + offset), y: o.y + c * 0.4),
                                 control2: CGPoint(x: o.x + c * (0.38 + offset), y: o.y + c * 0.6))
                context.strokePath()
            }
        }
        // A fly from above: a dark body and two pale wings, which the flap folds.
        do {
            let o = origin(10), c = CGFloat(cell)
            context.setFillColor(CGColor(srgbRed: 0.75, green: 0.78, blue: 0.8, alpha: 0.55))
            context.fillEllipse(in: CGRect(x: o.x + c * 0.12, y: o.y + c * 0.42, width: c * 0.36, height: c * 0.2))
            context.fillEllipse(in: CGRect(x: o.x + c * 0.52, y: o.y + c * 0.42, width: c * 0.36, height: c * 0.2))
            context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.04, alpha: 1))
            context.fillEllipse(in: CGRect(x: o.x + c * 0.4, y: o.y + c * 0.2, width: c * 0.2, height: c * 0.6))
        }
        // A frog mid-leap, side on: a green body, its head forward, its hind legs trailing.
        do {
            let o = origin(11), c = CGFloat(cell)
            let skin = CGColor(srgbRed: 0.36, green: 0.5, blue: 0.16, alpha: 1)
            context.setFillColor(skin)
            context.fillEllipse(in: CGRect(x: o.x + c * 0.25, y: o.y + c * 0.38, width: c * 0.5, height: c * 0.28))
            context.fillEllipse(in: CGRect(x: o.x + c * 0.62, y: o.y + c * 0.48, width: c * 0.22, height: c * 0.2))
            context.setStrokeColor(skin)
            context.setLineCap(.round)
            context.setLineWidth(c * 0.07)
            context.move(to: CGPoint(x: o.x + c * 0.3, y: o.y + c * 0.45))
            context.addLine(to: CGPoint(x: o.x + c * 0.1, y: o.y + c * 0.3))
            context.addLine(to: CGPoint(x: o.x + c * 0.05, y: o.y + c * 0.42))
            context.move(to: CGPoint(x: o.x + c * 0.66, y: o.y + c * 0.42))
            context.addLine(to: CGPoint(x: o.x + c * 0.78, y: o.y + c * 0.28))
            context.strokePath()
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.8, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: o.x + c * 0.74, y: o.y + c * 0.6, width: c * 0.06, height: c * 0.06))
        }
        // **The two particle circles**, white, their alpha as measured from the centre out (``circles``) — the shapes
        // smoke, fog, goop glow and drips are drawn with, written straight into the sheet's pixels.
        if let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) {
            for (index, profile) in [(12, Self.circles.soft), (13, Self.circles.hard)] {
                let o = origin(index)
                for y in 0..<cell { for x in 0..<cell {
                    let dx = (Float(x) + 0.5) / Float(cell) * 2 - 1, dy = (Float(y) + 0.5) / Float(cell) * 2 - 1
                    let r = (dx * dx + dy * dy).squareRoot() * Float(profile.count - 1)
                    let i = Int(r), f = r - Float(i)
                    let a = i + 1 < profile.count ? profile[i] + (profile[i + 1] - profile[i]) * f : 0
                    let byte = UInt8((min(max(a, 0), 1) * 255).rounded())
                    // The context's rows run from the top of its memory; `origin` is in Core Graphics' y-up terms.
                    let row = height - Int(o.y) - cell + y, offset = (row * width + Int(o.x) + x) * 4
                    pixels[offset] = byte; pixels[offset + 1] = byte; pixels[offset + 2] = byte; pixels[offset + 3] = byte
                } }
            }
        }
        guard let image = context.makeImage() else { throw ParticleRendererError.couldNotCreate("effect sprite image") }
        return try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .generateMipmaps: true, .SRGB: true, .textureStorageMode: MTLStorageMode.private.rawValue,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ])
    }
}

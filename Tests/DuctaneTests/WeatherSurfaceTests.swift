//
//  WeatherSurfaceTests.swift
//  DuctaneTests
//

import Foundation
import Metal
import Testing
import simd
@testable import Ductane

/// **`DuctaneWeather.h` and ``WeatherSurface``**: what a game's own shaders call for the weather on its surfaces. Checked on
/// the GPU — a kernel compiled from source through the header, as ``ShaderLibrary`` compiles one — so the header compiles,
/// its block of uniforms reads as Swift writes it, and its sums agree with the engine's own.
@Suite("Weather on a game's surfaces")
struct WeatherSurfaceTests {
    /// Compiles `body` (a kernel) after `#include "DuctaneWeather.h"`, runs it over `count` threads with `input` at
    /// buffer 0 and `count` floats out at buffer 1, and returns them.
    private func run(_ body: String, count: Int, input: [UInt8]) throws -> [Float]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let source = ShaderLibrary.withEngineHeaders("#include \"DuctaneWeather.h\"\n" + body)
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try #require(library.makeFunction(name: "probe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let inputBuffer = try #require(input.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)
        })
        let output = try #require(device.makeBuffer(length: count * 4, options: .storageModeShared))
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(count, 64), height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: Float.self, capacity: count), count: count))
    }

    private func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    @Test("Swift and Metal lay the block out the same: every field read back where Swift wrote it")
    func layout() throws {
        #expect(MemoryLayout<WeatherSurface>.size == 13 * 16 + 64)
        var surface = WeatherSurface()
        surface.snow = SIMD4(1, 2, 3, 4)
        surface.cover = simd_float4x4(diagonal: SIMD4(5, 6, 7, 8))
        surface.coverTop = SIMD4(9, 10, 11, 12)
        surface.prints = SIMD4(13, 14, 15, 16)
        surface.printGrid = SIMD4(17, 18, 19, 20)
        surface.wet = SIMD4(21, 22, 23, 24)
        surface.fallColour0 = SIMD4(25, 26, 27, 28)
        surface.fallColour1 = SIMD4(29, 30, 31, 32)
        surface.fallColour2 = SIMD4(33, 34, 35, 36)
        surface.fallLitter = SIMD4(37, 38, 39, 40)
        surface.clouds = SIMD4(41, 42, 43, 44)
        surface.cloudMotion = SIMD4(45, 46, 47, 48)
        surface.dust = SIMD4(49, 50, 51, 52)
        surface.fogVolume = SIMD4(53, 54, 55, 56)
        guard let read = try run("""
            kernel void probe(uint i [[thread_position_in_grid]], constant DUWeatherSurface &w [[buffer(0)]],
                              device float *out [[buffer(1)]]) {
                float4 fields[14] = { w.snow, w.cover[3], w.coverTop, w.prints, w.printGrid, w.wet, w.fallColours[0],
                                      w.fallColours[1], w.fallColours[2], w.fallLitter, w.clouds, w.cloudMotion, w.dust,
                                      w.fogVolume };
                out[i] = fields[i / 4][i % 4];
            }
            """, count: 56, input: bytes(of: surface)) else { return }
        var expected: [Float] = []
        for field in [surface.snow, surface.cover.columns.3, surface.coverTop, surface.prints, surface.printGrid,
                      surface.wet, surface.fallColour0, surface.fallColour1, surface.fallColour2, surface.fallLitter,
                      surface.clouds, surface.cloudMotion, surface.dust, surface.fogVolume] {
            expected += [field.x, field.y, field.z, field.w]
        }
        #expect(read == expected)
    }

    @Test("A tree's seed on the GPU is FallColors.seed: the same hash, the same numbers to a rounding")
    func fallSeed() throws {
        let places: [SIMD2<Float>] = (0..<64).map { SIMD2(Float($0) * 3.7 - 120, Float($0 * $0 % 97) * 1.3 - 60) }
        guard let read = try run("""
            kernel void probe(uint i [[thread_position_in_grid]], device const float2 *places [[buffer(0)]],
                              device float *out [[buffer(1)]]) {
                float2 s = duFallSeed(places[i / 2]);
                out[i] = i % 2 == 0 ? s.x : s.y;
            }
            """, count: places.count * 2, input: places.withUnsafeBytes { Array($0) }) else { return }
        for (k, place) in places.enumerated() {
            let seed = FallColors.seed(x: place.x, z: place.y)
            // The hash is the same bit for bit; fast maths divides by a reciprocal, a rounding away at most.
            #expect(abs(read[2 * k] - seed.timing) < 1e-6, "\(place)")
            #expect(abs(read[2 * k + 1] - seed.pick) < 1e-6, "\(place)")
        }
    }

    @Test("A print's shape on the GPU is the trail's own, for boots and bare feet")
    func footprintShape() throws {
        var points: [SIMD4<Float>] = []
        for shape in FootprintTrail.Shape.allCases {
            for k in 0..<60 {
                let q = SIMD2(Float(k % 10) / 4.5 - 1, Float(k / 10) / 2.5 - 1)
                points.append(SIMD4(q.x, q.y, shape == .boot ? 0 : 1, 0))
            }
        }
        guard let read = try run("""
            kernel void probe(uint i [[thread_position_in_grid]], device const float4 *points [[buffer(0)]],
                              device float *out [[buffer(1)]]) {
                out[i] = duFootprintShape(points[i].xy, points[i].z);
            }
            """, count: points.count, input: points.withUnsafeBytes { Array($0) }) else { return }
        for (k, p) in points.enumerated() {
            let shape: FootprintTrail.Shape = p.z < 0.5 ? .boot : .bare
            #expect(abs(read[k] - shape.press(at: SIMD2(p.x, p.y))) < 1e-4)
        }
    }

    @Test("Clear weather lays nothing; rain wets, dust settles, clouds and fog are carried")
    @MainActor func fromWeather() {
        let clear = WeatherSurface(weather: .clear)
        #expect(clear.snow.x == 0 && clear.wet == .zero && clear.dust == .zero && clear.clouds == .zero)
        #expect(clear.fogVolume == .zero)

        var rain = Weather(kind: .rain, severity: 0.8)
        rain.wetness = 0.6
        let wet = WeatherSurface(weather: rain, time: 1234.5)
        #expect(wet.wet.x == 0.6 && wet.wet.y == rain.puddles)
        #expect(wet.wet.z == rain.settings.precipitation && wet.wet.z > 0)
        #expect(wet.wet.w == Float(1234.5 - 1200))

        var snow = Weather(kind: .snow, severity: 0.8)
        snow.lyingSnow = 0.5
        snow.snowDepth = true
        #expect(WeatherSurface(weather: snow).snow.y == 0.5 * Weather.deepestSnow)
        #expect(WeatherSurface(weather: snow, snowDepth: false).snow.y == 0)
        #expect(WeatherSurface(weather: snow).wet.z == 0, "snow falling is not rain running")

        let dust = WeatherSurface(weather: Weather(kind: .dust, severity: 0.6))
        #expect(dust.dust.w > 0)

        let layer = CloudLayer(coverage: 0.4, darkness: 0.2, motion: SIMD4(1, 0, 30, 0), base: 1200, thickness: 900)
        let fog = VolumetricFog.Lookup(parameters: SIMD4(1, 0.5, 7, 64), skyDistance: 300)
        let both = WeatherSurface(weather: .clear, clouds: layer, fog: fog)
        #expect(both.clouds == SIMD4(0.4, 0.2, 1200, 900) && both.cloudMotion == SIMD4(1, 0, 30, 0))
        #expect(both.fogVolume == fog.parameters)
    }

    @Test("A source compiled at run time has the engine's header written in, once")
    func headersWrittenIn() {
        let source = ShaderLibrary.withEngineHeaders("#include \"DuctaneWeather.h\"\n#include <DuctaneWeather.h>\nkernel x")
        #expect(source.contains("struct DUWeatherSurface"))
        #expect(source.components(separatedBy: "struct DUWeatherSurface {").count == 2)
        #expect(source.hasSuffix("kernel x"))
        #expect(ShaderLibrary.withEngineHeaders("#include <metal_stdlib>") == "#include <metal_stdlib>")
    }
}

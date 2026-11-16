// swift-tools-version: 6.2
import PackageDescription

/// **`DuctaneCulling` built optimised in Debug too**, on a toolchain known to accept the flag in a dependency used by URL
/// (see the target).
#if compiler(>=6.4)
let optimisedInDebug: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]
#else
let optimisedInDebug: [SwiftSetting] = []
#endif

let package = Package(
    name: "Ductane",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Ductane", targets: ["Ductane"]),
        // **The sample is a product, not a test fixture.** `swift run DuctaneSample` is the first
        // thing somebody who cloned this repo should be able to do.
        .executable(name: "DuctaneSample", targets: ["DuctaneSample"]),
        // **A new game, ready to run**: `swift run ductane-new "My Game"`, or the same files written by a world editor
        // through `DuctaneTemplate`.
        .library(name: "DuctaneTemplate", targets: ["DuctaneTemplate"]),
        .executable(name: "ductane-new", targets: ["ductane-new"]),
    ],
    targets: [
        // meshoptimizer's simplifier, for level of detail (`MeshDetail`): C++, vendored unmodified from the 1.3
        // release (MIT, LICENSE beside it) — `simplifier.cpp`, the `allocator.cpp` it needs, and the header.
        // The one part of the engine not written in Swift: it is the simplifier gltfpack and most engines use,
        // and a reimplementation would be slower and less trustworthy. **An app shipping `MeshDetail` ships
        // its license.**
        .target(
            name: "MeshOptimizer",
            exclude: ["LICENSE.md"]
        ),
        // Google's Draco decoder, for glTF's KHR_draco_mesh_compression: C++, vendored unmodified from the 1.5.7
        // release (Apache 2.0, LICENSE beside it), behind a small C interface of the engine's own (`DUDraco`).
        // The reference decoder is what every serious glTF reader uses; a reimplementation would be months of
        // work and less trustworthy. `draco_features.h` is written here in place of the one Draco's CMake makes.
        .target(
            name: "Draco",
            exclude: ["LICENSE"],
            // **Silenced by name, and through the safe setting rather than a compiler flag.** Xcode warns about
            // 64-to-32-bit conversions that Draco's own build does not, and the code is Google's, unmodified.
            cxxSettings: [.headerSearchPath("src"), .disableWarning("shorten-64-to-32")]
        ),
        // Binomial's Basis Universal transcoder, for glTF's KHR_texture_basisu (KTX2 textures): C++, vendored
        // unmodified from the 2.50 release with Meta's Zstandard decoder beside it (Apache 2.0 and BSD — LICENSE,
        // NOTICE and LICENSES/), behind a small C interface of the engine's own (`DUBasis`). The same decision as
        // Draco's. The excluded files are included by the transcoder's source rather than compiled on their own.
        .target(
            name: "Basis",
            exclude: ["LICENSE", "NOTICE", "LICENSES", "src/transcoder/basisu_astc_cfgs.inl",
                      "src/transcoder/basisu_dds_transcoder.inl", "src/transcoder/basisu_etc1_mods.inl",
                      "src/transcoder/basisu_xbc7_decoder.inl", "src/transcoder/basisu_transcoder_tables_astc.inc",
                      "src/transcoder/basisu_transcoder_tables_astc_0_255.inc",
                      "src/transcoder/basisu_transcoder_tables_atc_55.inc", "src/transcoder/basisu_transcoder_tables_atc_56.inc",
                      "src/transcoder/basisu_transcoder_tables_bc7_m5_alpha.inc",
                      "src/transcoder/basisu_transcoder_tables_bc7_m5_color.inc",
                      "src/transcoder/basisu_transcoder_tables_dxt1_5.inc", "src/transcoder/basisu_transcoder_tables_dxt1_6.inc",
                      "src/transcoder/basisu_transcoder_tables_pvrtc2_45.inc",
                      "src/transcoder/basisu_transcoder_tables_pvrtc2_alpha_33.inc"],
            cSettings: [.define("BASISD_SUPPORT_KTX2", to: "1"), .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1")],
            cxxSettings: [.headerSearchPath("src"), .define("BASISD_SUPPORT_KTX2", to: "1"),
                          .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1")]
        ),
        // **A world's per-frame loops, optimised in every configuration**: which of tens of thousands of placed and scattered
        // copies a frame draws and casts (`WorldCopyField`), the ground's vertices, coarser levels and puddles, a mesh's
        // triangles read back. Unoptimised, a 400 m zone of 48,000 copies spent 85 ms of every Debug frame here against 4
        // optimised — a game run from Xcode's Run button would stutter on any real map. So this target alone is built with
        // `-O` in Debug too. It calls nothing outside itself, so an unoptimised call in an inner loop cannot undo it; the
        // only thing given up is stepping through it in a debugger.
        //
        // **`unsafeFlags` in a package used by URL**: SwiftPM used to refuse a versioned dependency with them. Checked on
        // 2026-11-16 with Swift 6.4.2 (Xcode 27.2): `swift build`, `xcodebuild` on a package and an Xcode app project all
        // resolve a tagged release served over HTTP whose target has unsafe flags, and apply `-O` after `-Onone`. On an
        // older toolchain, which may refuse it, the target is built as everything else is (`optimisedInDebug`).
        .target(
            name: "DuctaneCulling",
            swiftSettings: optimisedInDebug
        ),
        .target(
            name: "Ductane",
            dependencies: ["MeshOptimizer", "Draco", "Basis", "DuctaneCulling"],
            // Declared so SwiftPM synthesises `Bundle.module`, which the HUD and tone-map pipelines
            // load their shaders from. Xcode compiles the .metal into the same bundle as `default.metallib`;
            // SwiftPM's CLI does not compile Metal at all, which is why `swift test` can build the
            // package but cannot exercise anything needing a GPU.
            resources: [.copy("HUDShaders.metal"), .copy("ToneMapShaders.metal"), .copy("SkyShaders.metal"),
                        .copy("ParticleShaders.metal"), .copy("DecalShaders.metal"), .copy("SkinningShaders.metal"),
                        .copy("BoundaryShaders.metal"), .copy("WaymarkShaders.metal"),
                        .copy("WeatherShaders.metal"), .copy("FogShaders.metal"), .copy("WorldShaders.metal"),
                        // **What a game's own shaders include** (`#include "DuctaneWeather.h"`, this folder on the Metal
                        // compiler's header search path): what the weather does to its surfaces. Copied into the bundle as
                        // well, so a library compiled from source at run time (`ShaderLibrary`) can include it too.
                        .copy("ShaderHeaders/DuctaneWeather.h")],
            swiftSettings: [
                // Matches the game targets: everything is main-actor by default unless it says
                // otherwise. Engine types that must run off the main thread say `nonisolated`
                // explicitly, which is a decision worth having to write down.
                .defaultIsolation(MainActor.self)
            ]
        ),
        // A complete, deliberately dull game built against the engine's **public API only**.
        //
        // It is the standing check that the engine is usable by someone who did not write it: if
        // the sample cannot be built without reaching inside, the API is wrong. It found its first
        // one immediately — `swift build` compiles no Metal, so nothing that loaded a default
        // library could start outside Xcode. See `ShaderLibrary`.
        // **The sample's logic, split out of its app the way the studio requires of a title.**
        // A game loop, a save format and a level's contents need no window, so they live where
        // `swift test` can reach them — and the sample demonstrating the recommended shape is worth
        // more than the fifty lines it costs.
        .target(
            name: "DuctaneSampleCore",
            dependencies: ["Ductane"],
            // **The levels are files, and this is where they ship from.** `.process` rather than
            // `.copy` so they land flat in the bundle, which is where `Level.load(named:bundle:)`
            // looks — the same arrangement a title uses.
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DuctaneSampleCoreTests",
            dependencies: ["DuctaneSampleCore"]
        ),
        .executableTarget(
            name: "DuctaneSample",
            dependencies: ["Ductane", "DuctaneSampleCore"],
            // `.copy` and not `.process`: the shader **source** has to survive into the bundle so it
            // can be compiled at runtime when no metallib exists.
            resources: [.copy("SampleShaders.metal"), .process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // **A new game's project**, as text: no GPU, no window, nothing but Foundation — so a sandboxed app can write
        // one into a folder it was given, and `swift test` checks every file.
        .target(
            name: "DuctaneTemplate",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DuctaneTemplateTests",
            dependencies: ["DuctaneTemplate"]
        ),
        .executableTarget(
            name: "ductane-new",
            dependencies: ["Ductane", "DuctaneTemplate"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DuctaneTests",
            dependencies: ["Ductane", "DuctaneCulling"],
            // A rig and a textured-material fixture, so the loaders are tested against real files
            // rather than mocks of them. Neither a skeleton nor a material's numbers need a GPU,
            // which is the whole reason `RigLoader` and `Material` are split from the halves that
            // do — see their doc comments.
            resources: [.process("Resources")]
        )
    ],
    // Draco and Basis Universal are C++17; meshoptimizer is happy with anything since C++98.
    cxxLanguageStandard: .cxx17
)

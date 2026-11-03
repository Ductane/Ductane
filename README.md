<p align="center"><img src="Brand/ductane.svg" width="96" alt="Ductane"></p>

# Ductane

A Swift 6 and Metal 4 game engine for the Mac. Your game is a Swift package: no runtime, no translation layer, no
editor you have to learn.

**[Documentation](https://ductane.com/docs/start.html)** · **[Changelog](CHANGELOG.md)** ·
**[ductane.com](https://ductane.com)**

## Requirements

- macOS 26 or later, on a Mac with Apple silicon (Metal 4)
- Swift 6.2 (Xcode 26)

## Installation

Add the package to your game's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Ductane/Ductane.git", from: "1.3.0")
],
targets: [
    .executableTarget(name: "MyGame", dependencies: ["Ductane"])
]
```

## Run the sample

The repository includes a complete small game written against the public API only: two levels, an in-game
editor, sound and saving.

```bash
git clone https://github.com/Ductane/Ductane.git
cd Ductane
swift run DuctaneSample
```

**WASD** to move, click to capture the mouse, **esc** to release it.

## What's included

- **Frame pacing** — frames in flight, a fixed simulation step, interpolation between steps
- **Rendering** — reversed-Z depth, HDR with tone mapping, physically based materials, image-based lighting
- **Light and shadow** — cascaded sun shadows; spot and point lights, clustered, each able to cast
- **Meshes** — USD through Model I/O, and glTF / GLB with meshopt, Draco and KTX2 compression
- **Many copies** — instanced drawing, frustum culling and automatic level of detail
- **Characters** — skinned animation from USD, skinned once a frame on the GPU, clips mixed and strides aligned, attachments, and a character controller
- **Input** — keyboard, mouse and game controllers, with rebindable actions
- **Audio, particles, a HUD, levels and saving**

Each has a guide in the [documentation](https://ductane.com/docs/start.html).

## Tests

```bash
swift test
```

## Versioning

Ductane follows [Semantic Versioning](https://semver.org). Each release is listed in the
[changelog](CHANGELOG.md), and a change that breaks existing code waits for the next major version.

## License

Free for small businesses under the [PolyForm Small Business License 1.0.0](LICENSE). For a license beyond its
terms, contact [legal@pixla.app](mailto:legal@pixla.app).

A game built with the engine includes the notice `Uses Ductane © 2026 Pixla LLC (https://ductane.com)`,
and ships the licenses of the third-party code compiled into it:

| Component | License | In |
|---|---|---|
| meshoptimizer | MIT | `Sources/MeshOptimizer` |
| Draco | Apache 2.0 | `Sources/Draco` |
| Basis Universal, with Zstandard | Apache 2.0, BSD | `Sources/Basis` |

© 2026 Pixla LLC

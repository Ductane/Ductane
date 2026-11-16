//
//  ProjectTemplate.swift
//  DuctaneTemplate
//
//  The project's files, with `{{…}}` where `GameProject` fills them in. The code is the game a person starts from,
//  so it is written for them: short, commented where a choice was made, nothing they would have to delete.
//

nonisolated enum ProjectTemplate {

    // MARK: The game

    static let main = #"""
//
//  main.swift
//  {{TARGET}}
//
//  Opens a window, finds the world in the Worlds folder, and hands it to the game. The engine owns no window:
//  the window, its view and its menu are this app's.
//

import AppKit
import MetalKit
import Ductane

let application = NSApplication.shared
application.setActivationPolicy(.regular)

/// Says what went wrong and quits.
func fail(_ message: String, _ detail: String = "") -> Never {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.runModal()
    exit(1)
}

/// **The world this game opens**: the first scene package in the app's Worlds folder, by name. A world editor's
/// export writes it there, and Run builds the folder into the app.
func worldURL() -> URL? {
    guard let folder = Bundle.main.url(forResource: "{{WORLDS}}", withExtension: nil),
          let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    else { return nil }
    return files.filter { $0.pathExtension.lowercased() == "usdz" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first
}

// A menu with Quit, which a window of its own does not bring.
let menu = NSMenu()
let appItem = NSMenuItem()
menu.addItem(appItem)
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "Quit \(ProcessInfo.processInfo.processName)",
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
application.mainMenu = menu

guard let url = worldURL() else {
    fail("There's no world to play.", "Export a scene into this project's {{WORLDS}} folder, then press Run again.")
}
guard let device = MTLCreateSystemDefaultDevice() else { fail("This Mac has no Metal device.") }

let engine: FrameRenderer
let game: Game
do {
    // Fails on a Mac without Metal 4.
    engine = try FrameRenderer(device: device)
    game = try Game(engine: engine, world: WorldPackage(contentsOf: url))
} catch {
    fail("\(url.lastPathComponent) didn't open.", "\(error)")
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "{{TITLE_SWIFT}}"
window.center()
window.acceptsMouseMovedEvents = true

let view = GameView(frame: window.contentLayoutRect, device: device)
view.colorPixelFormat = FrameRenderer.colorPixelFormat
view.depthStencilPixelFormat = FrameRenderer.depthPixelFormat
// The view hosts the layer; the display link below drives the frames.
view.isPaused = true
view.enableSetNeedsDisplay = false
view.game = game
window.contentView = view

// The engine holds its game weakly: `game` keeps the world alive.
engine.game = game.world
guard let layer = view.layer as? CAMetalLayer else { fail("The view has no Metal layer.") }
FrameRenderer.prepare(layer, device: device)
let displayLink = engine.makeDisplayLink(for: layer)
displayLink.add(to: .main, forMode: .common)
game.world.viewportSizeChanged(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))

// Closing the window quits; leaving it lets go of the mouse and the keys.
NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
    MainActor.assumeIsolated { application.terminate(nil) }
}
NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
    MainActor.assumeIsolated { game.letGo() }
}

window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
application.activate()
application.run()

"""#

    static let game = #"""
//
//  Game.swift
//  {{TARGET}}
//

import Foundation
import simd
import Ductane

/// **The game**: one world, drawn by Ductane's `WorldRenderer` the way its editor showed it, walked in first
/// person and heard. What a game adds — things to do, people to meet — goes in `step` (fixed steps) and `frame` (once
/// a frame, before it is drawn).
final class Game {

    /// Draws the world: ground, props, sky, shadows, weather, fog and the seasons.
    let world: WorldRenderer
    /// Keys, the mouse and controllers.
    let input = InputState()

    /// The player's body: walking, running, jumping, steps and slopes.
    private var body: CharacterController
    /// Where the player looks from, and which way.
    private var camera: Camera
    /// What the body walks on and into: the ground, the world's edge and the props near it.
    private var surroundings: CharacterController.Surroundings
    /// Where the solid props were last gathered round; nil until the first are in, and the player waits until then.
    private var solidsCentre: SIMD2<Float>?
    private var gathering = false
    private var soundscape: Soundscape?
    /// Seconds stepped since the last frame, for the sound.
    private var stepped: Float = 0

    /// How far round the player its props are solid, and how far it goes before they are gathered again.
    static let reach: Float = 150
    static let regather: Float = 60

    init(engine: FrameRenderer, world package: WorldPackage) throws {
        world = try WorldRenderer(engine: engine)
        let ground = try package.ground()
        surroundings = .init(groundHeight: { x, z in ground?.height(x: x, z: z) ?? 0 },
                             boundary: package.world.boundary)

        // Start at the scene's first spawn marker, or in its middle.
        let spawn = package.world.markers("spawn").first
        let x = spawn?.position.x ?? 0, z = spawn?.position.z ?? 0
        body = CharacterController(feet: SIMD3(x, spawn?.position.y ?? ground?.height(x: x, z: z) ?? 0, z))
        camera = Camera(position: body.eye, yaw: spawn?.yaw ?? 0)
        world.camera = WorldRenderer.View(camera)

        // The props load in the background and appear as they arrive; once they are all in, they can be walked into.
        try world.show(package) { [weak self] failures in
            for (prop, error) in failures { print("\(prop.lastPathComponent) didn't load: \(error)") }
            self?.gatherSolids()
        }
        world.onStep = { [weak self] seconds in self?.step(seconds) }
        world.onFrame = { [weak self] in self?.frame() }
        input.start()
        if let sounds = package.world.sounds { startSound(sounds, from: package) }
    }

    /// One fixed step of the simulation.
    func step(_ seconds: Float) {
        camera.turn(rate: input.lookRate, deltaTime: seconds)
        if solidsCentre != nil {
            body.step(yaw: camera.yaw, input: input.movement, isJumpHeld: input.isHeld(.jump),
                      isCrouching: input.isHeld(.crouch), deltaTime: seconds, in: surroundings)
        }
        if let centre = solidsCentre, simd_distance(centre, SIMD2(body.feet.x, body.feet.z)) > Self.regather {
            gatherSolids()
        }
        stepped += seconds
    }

    /// Once a frame, after its steps: the view, and what is heard from it.
    func frame() {
        camera.look(mouseDelta: input.consumeLook())
        camera.position = body.eye
        world.camera = WorldRenderer.View(camera, fieldOfView: 65 * .pi / 180)
        if let soundscape {
            // The weather on the clock its lightning is drawn by, so a flash and its thunder agree.
            let weather = world.frameWeather
            soundscape.setWeather(weather == .clear ? nil : weather, at: world.weatherTime)
            soundscape.setDaylight(Soundscape.daylight(sunElevation: world.frameDaySky.lighting.elevation))
            soundscape.update(listener: camera.position, forward: camera.forward, up: SIMD3(0, 1, 0), elapsed: stepped)
        }
        stepped = 0
    }

    /// The window was left: the mouse comes back, and no key stays held.
    func letGo() {
        input.setMouseCaptured(false)
        input.releaseKeys()
    }

    /// **The props near the player, made solid**: gathered here, built into one collision mesh off the main thread.
    private func gatherSolids() {
        guard !gathering else { return }
        gathering = true
        let centre = SIMD2(body.feet.x, body.feet.z)
        let near = world.solids(around: centre, reach: Self.reach)
        Task {
            let mesh = await Task.detached { near.isEmpty ? nil : CollisionMesh(placed: near) }.value
            surroundings.meshes = mesh
            if solidsCentre == nil, let mesh { standOnFloor(of: mesh) }
            solidsCentre = centre
            gathering = false
        }
    }

    /// The first time: onto the highest floor under the start, when one is above it — a floor of props over the ground.
    private func standOnFloor(of mesh: CollisionMesh) {
        let feet = body.feet
        guard let floor = mesh.standingFloor(x: feet.x, z: feet.z, below: feet.y + 1.5), floor > feet.y else { return }
        body.teleport(to: SIMD3(feet.x, floor, feet.z))
    }

    /// **The world's sounds**: its sound points, ambience, scattered sounds, music and the weather's recordings.
    private func startSound(_ sounds: WorldFile.Sounds, from package: WorldPackage) {
        // No output device: the game plays quietly.
        guard let audio = try? AudioEngine() else { return }
        let soundscape = Soundscape(audio: audio, music: sounds.music == nil ? nil : MusicPlayer())
        Task {
            let failures = await soundscape.play(sounds) { package.url(of: $0) }
            for (file, error) in failures { print("\(file) didn't load: \(error)") }
            self.soundscape = soundscape
        }
    }
}

"""#

    static let view = #"""
//
//  GameView.swift
//  {{TARGET}}
//

import AppKit
import MetalKit
import Ductane

/// **The window's view**: keys and the mouse go to the game's `InputState`. Click to look round with the mouse; Esc
/// lets go of it.
final class GameView: MTKView {
    weak var game: Game?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            game?.input.setMouseCaptured(false)
            return
        }
        game?.input.keyDown(KeyCode(rawValue: event.keyCode))
    }

    override func keyUp(with event: NSEvent) {
        game?.input.keyUp(KeyCode(rawValue: event.keyCode))
    }

    // Shift, Control, Option and Command arrive only here, never as keyDown.
    override func flagsChanged(with event: NSEvent) {
        game?.input.flagsChanged(key: KeyCode(rawValue: event.keyCode), modifierFlags: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        game?.input.setMouseCaptured(true)
    }

    override func mouseMoved(with event: NSEvent) {
        game?.input.addMouseDelta(x: Float(event.deltaX), y: Float(event.deltaY))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }
}

"""#

    // MARK: Around it

    static let readme = #"""
# {{TITLE}}

A game made with [Ductane](https://ductane.com). It opens the world in `{{WORLDS}}/`, draws it with
`WorldRenderer` the way its editor showed it, walks it in first person and plays its sounds.

## Run it

Open `{{TARGET}}.xcodeproj` in Xcode and press **Run**. The first build fetches Ductane. A Mac with Apple
silicon and macOS 26 is needed for Metal 4.

## Its world

The game opens the first `.usdz` scene package in `{{WORLDS}}/`, by name. Export a scene there from your world
editor, and turn on its export on save, so every save of the scene lands in the game the next time you press Run.

## Controls

| Key | Does |
| --- | --- |
| W A S D | move |
| Shift | run |
| Space | jump |
| C | crouch |
| click / Esc | look round with the mouse / let go of it |

A controller works too: the left stick moves, the right stick looks.

## Where to go next

- `Game.swift` is the game: add to `step` (fixed steps) and `frame` (once a frame).
- The scene's markers are in `package.world.markers`. The game starts at the first one of kind `spawn`; what other
  kinds mean is yours to decide.
- Ductane's guide: https://ductane.com/docs/

"""#

    static let worldsReadme = #"""
# {{WORLDS}}

The game opens the first `.usdz` scene package here, by name. Export a scene into this folder from your world editor;
everything in it is built into the app.

"""#

    static let gitignore = #"""
.DS_Store
xcuserdata/
DerivedData/
.build/
.swiftpm/

"""#

    // MARK: The project file

    static let pbxproj = #"""
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		C0DE00000000000000000101 /* Ductane in Frameworks */ = {isa = PBXBuildFile; productRef = C0DE00000000000000000401 /* Ductane */; };
		C0DE00000000000000000102 /* {{WORLDS}} in Resources */ = {isa = PBXBuildFile; fileRef = C0DE00000000000000000202 /* {{WORLDS}} */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		C0DE00000000000000000201 /* {{TARGET}}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {{TARGET}}.app; sourceTree = BUILT_PRODUCTS_DIR; };
		C0DE00000000000000000202 /* {{WORLDS}} */ = {isa = PBXFileReference; lastKnownFileType = folder; path = {{WORLDS}}; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		C0DE00000000000000000301 /* {{TARGET}} */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {{TARGET}};
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		C0DE00000000000000000501 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				C0DE00000000000000000101 /* Ductane in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		C0DE00000000000000000601 = {
			isa = PBXGroup;
			children = (
				C0DE00000000000000000301 /* {{TARGET}} */,
				C0DE00000000000000000202 /* {{WORLDS}} */,
				C0DE00000000000000000602 /* Products */,
			);
			sourceTree = "<group>";
		};
		C0DE00000000000000000602 /* Products */ = {
			isa = PBXGroup;
			children = (
				C0DE00000000000000000201 /* {{TARGET}}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		C0DE00000000000000000701 /* {{TARGET}} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = C0DE00000000000000000902 /* Build configuration list for PBXNativeTarget "{{TARGET}}" */;
			buildPhases = (
				C0DE00000000000000000502 /* Sources */,
				C0DE00000000000000000501 /* Frameworks */,
				C0DE00000000000000000503 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				C0DE00000000000000000301 /* {{TARGET}} */,
			);
			name = {{TARGET}};
			packageProductDependencies = (
				C0DE00000000000000000401 /* Ductane */,
			);
			productName = {{TARGET}};
			productReference = C0DE00000000000000000201 /* {{TARGET}}.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		C0DE00000000000000000801 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {
					C0DE00000000000000000701 = {
						CreatedOnToolsVersion = 26.0;
					};
				};
			};
			buildConfigurationList = C0DE00000000000000000901 /* Build configuration list for PBXProject "{{TARGET}}" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = C0DE00000000000000000601;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				C0DE00000000000000000402 /* {{ENGINE_REFERENCE_ISA}} "Ductane" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = C0DE00000000000000000602 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				C0DE00000000000000000701 /* {{TARGET}} */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		C0DE00000000000000000503 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				C0DE00000000000000000102 /* {{WORLDS}} in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		C0DE00000000000000000502 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		C0DE00000000000000000A01 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		C0DE00000000000000000A02 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
			};
			name = Release;
		};
		C0DE00000000000000000A03 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				EXCLUDED_ARCHS = x86_64;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {{TITLE_PBX}};
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.games";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "{{BUNDLE_ID}}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
			};
			name = Debug;
		};
		C0DE00000000000000000A04 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				EXCLUDED_ARCHS = x86_64;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {{TITLE_PBX}};
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.games";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "{{BUNDLE_ID}}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		C0DE00000000000000000901 /* Build configuration list for PBXProject "{{TARGET}}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				C0DE00000000000000000A01 /* Debug */,
				C0DE00000000000000000A02 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		C0DE00000000000000000902 /* Build configuration list for PBXNativeTarget "{{TARGET}}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				C0DE00000000000000000A03 /* Debug */,
				C0DE00000000000000000A04 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin {{ENGINE_REFERENCE_ISA}} section */
		C0DE00000000000000000402 /* {{ENGINE_REFERENCE_ISA}} "Ductane" */ = {
			isa = {{ENGINE_REFERENCE_ISA}};
			{{ENGINE_REFERENCE}}
		};
/* End {{ENGINE_REFERENCE_ISA}} section */

/* Begin XCSwiftPackageProductDependency section */
		C0DE00000000000000000401 /* Ductane */ = {
			isa = XCSwiftPackageProductDependency;
			package = C0DE00000000000000000402 /* {{ENGINE_REFERENCE_ISA}} "Ductane" */;
			productName = Ductane;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = C0DE00000000000000000801 /* Project object */;
}

"""#

    static let workspace = #"""
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>

"""#

    static let scheme = #"""
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "C0DE00000000000000000701"
               BuildableName = "{{TARGET}}.app"
               BlueprintName = "{{TARGET}}"
               ReferencedContainer = "container:{{TARGET}}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "C0DE00000000000000000701"
            BuildableName = "{{TARGET}}.app"
            BlueprintName = "{{TARGET}}"
            ReferencedContainer = "container:{{TARGET}}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "C0DE00000000000000000701"
            BuildableName = "{{TARGET}}.app"
            BlueprintName = "{{TARGET}}"
            ReferencedContainer = "container:{{TARGET}}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>

"""#
}

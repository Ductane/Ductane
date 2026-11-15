//
//  AudioEngine.swift
//  Ductane
//

import AppKit
import AVFoundation
import os
import simd

/// Why an ``AudioEngine`` could not be made, or a sound could not be loaded into one.
public nonisolated enum AudioEngineError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No audio format could be made at this sample rate.
    case unsupportedSampleRate(Double)
    /// The engine could not be put into offline rendering, or could not start; the reason is
    /// AVFoundation's.
    case couldNotStart(reason: String)
    /// No sound file by that name and extension in the bundle.
    case soundNotFound(String)
    /// The file is there and could not be read as audio.
    case unreadableSound(String, reason: String)
    /// Samples handed to ``AudioEngine/load(_:samples:sampleRate:)`` that make no sound: none at all,
    /// or none a buffer could be made for.
    case noSamples(String)

    public var description: String {
        switch self {
        case .unsupportedSampleRate(let rate): "no audio format at \(rate) Hz"
        case .couldNotStart(let reason): "the audio engine could not start — \(reason)"
        case .soundNotFound(let name): "no sound file \(name)"
        case .unreadableSound(let name, let reason): "sound \(name) could not be read — \(reason)"
        case .noSamples(let name): "sound \(name) has no samples"
        }
    }
}

/// Positional one-shot audio.
///
/// **Spatialized from the start, not stereo panning bolted on later.** A game about distance needs
/// sound to carry distance: a plate hit at 800 m should arrive from where the plate is and sound
/// like it is 800 m away. `AVAudioEnvironmentNode` does the head-related work; what a title supplies
/// is a listener each frame and a world position per sound.
///
/// **One-shots, and loops that belong to a place** — a brazier's crackle, a generator's hum — since
/// 2026-09-11. **Unplaced sounds with pan and pitch, an effects bus, a meter and background quiet** since
/// 2026-10-27, taken from a game's own effects deck; the score is ``MusicPlayer``'s.
///
/// ### Three volumes under one
///
/// ``masterVolume`` scales everything; under it ``effectsVolume`` takes every one-shot, placed or not,
/// and ``loopVolume`` every loop. ``apply(_:)`` sets all three from a player's ``PlayerSettings``.
///
/// ### Two spatialisers, because one distance curve cannot serve both
///
/// **The one-shots' default curve was tuned for a shot heard across a range**: full volume out to
/// 8 m, then 90% of the inverse law. Put a brazier's crackle through it and it is as loud at 8 m as at
/// arm's length and still 43% at 20 m — two braziers fill a level with fire. Loops go through a second
/// spatializer with the physical inverse law from 2 m: half as loud at twice the distance, which is
/// what a small, near sound does. Measured, not argued — see ``renderOffline(seconds:)``. Both curves,
/// and the number of one-shot voices, are a game's to set: ``Configuration``.
///
/// ### And a reach per sound, for a world laid out in an editor
///
/// **A sound given a reach carries exactly that far** (``SoundReach``): ``startLoop(_:at:volume:reach:)`` and
/// ``playAmbient(_:at:volume:reach:)`` go through a third spatializer that attenuates nothing, and each voice is levelled
/// from its own reach as the listener moves — a generator heard from 60 m beside a drip heard from 5, which no one
/// curve can hold. **Any recording can be placed**: a stereo or 96 kHz file is mixed to one channel at the engine's rate
/// the first time it is placed, and kept.
///
/// ### Lifecycle
///
/// An engine plays from the moment it is made. ``pause()`` holds everything — one-shots, loops and
/// any delayed one-shot still waiting — and ``resume()`` carries on from where it was. ``stop()`` is
/// **final**: it frees the output device, and an engine that has stopped plays nothing again. Make a
/// new one.
///
/// > **A landmine worth knowing before adding any AVFoundation callback here.** This type is
/// > main-actor-isolated like everything else in the engine, and a closure written inside one of its
/// > methods *inherits that isolation*. AVFoundation calls taps and completion handlers on a
/// > realtime audio thread, so such a closure trips the actor assertion and takes the process down
/// > — `_dispatch_assert_queue_fail`, on `RealtimeMessenger.mServiceQueue`, with no mention of
/// > actors anywhere in the crash. Mark any callback `@Sendable` and give it its own thread-safe
/// > storage. Nothing here uses one today, which is the only reason this is a note and not a bug.
public final class AudioEngine {

    /// How an engine spreads sound over distance, and how many one-shots it can play at once — set
    /// when the engine is made. **The defaults are what every game has had so far.**
    public struct Configuration: Equatable, Sendable {

        /// One spatializer's distance curve: the inverse law, in meters.
        public struct Falloff: Equatable, Sendable {
            /// Full volume nearer than this.
            public var referenceDistance: Float
            /// No quieter beyond this.
            public var maximumDistance: Float
            /// 1 is the physical inverse law — half as loud at twice the reference distance; below 1
            /// falls off more gently.
            public var rolloffFactor: Float

            public init(referenceDistance: Float, maximumDistance: Float, rolloffFactor: Float) {
                self.referenceDistance = referenceDistance
                self.maximumDistance = maximumDistance
                self.rolloffFactor = rolloffFactor
            }
        }

        /// One-shots that can overlap. Beyond this the oldest is reused, because a game that runs out of
        /// voices silently drops the *newest* sound — which is always the one that just happened and
        /// therefore the one that mattered.
        public var voiceCount: Int
        /// The one-shots' curve. The default — full volume to 8 m, 90% of the inverse law out to 2 km —
        /// was tuned for a shot heard across a range.
        public var oneShotFalloff: Falloff
        /// The loops' curve. The default is the physical inverse law from 2 m, to 200 m — a small, near
        /// sound.
        public var loopFalloff: Falloff

        public init(voiceCount: Int = 16,
                    oneShotFalloff: Falloff = Falloff(referenceDistance: 8, maximumDistance: 2000,
                                                      rolloffFactor: 0.9),
                    loopFalloff: Falloff = Falloff(referenceDistance: 2, maximumDistance: 200,
                                                   rolloffFactor: 1)) {
            self.voiceCount = max(1, voiceCount)
            self.oneShotFalloff = oneShotFalloff
            self.loopFalloff = loopFalloff
        }
    }

    public let configuration: Configuration

    private let engine = AVAudioEngine()
    /// Every one-shot, placed or not — ``effectsVolume``.
    private let effectsBus = AVAudioMixerNode()
    private let environment = AVAudioEnvironmentNode()
    /// The loops' spatializer — see the type's notes.
    private let nearEnvironment = AVAudioEnvironmentNode()
    /// Every loop, placed or not — ``loopVolume``.
    private let ambienceBus = AVAudioMixerNode()
    /// Ambient beds playing — see ``startAmbience(_:volume:)``.
    private var beds: [Int: AVAudioPlayerNode] = [:]
    /// **The spatializer for sounds with a reach of their own** — see ``startLoop(_:at:volume:reach:)``. It attenuates
    /// nothing: each voice's level is set from its own reach (``SoundReach``) as the listener moves, and the node only
    /// says which way the sound is.
    private let reachEnvironment = AVAudioEnvironmentNode()
    /// Loops with a reach, by id: where each is, how loud, how far it carries.
    private var reached: [Int: SoundReach.Placed] = [:]
    private var idleReachPlayers: [AVAudioPlayerNode] = []
    /// One-shots with a reach — ``playAmbient(_:at:volume:reach:)`` — a ring like the range one-shots'.
    private var ambientVoices: [AVAudioPlayerNode] = []
    private var nextAmbientVoice = 0
    /// Where the ears are, for the reached sounds' levels.
    private var listener = SIMD3<Float>.zero
    /// Sounds as a placed voice plays them — mono at the engine's rate, made from ``buffers`` the first time one is
    /// placed.
    private var placedBuffers: [String: AVAudioPCMBuffer] = [:]
    private var players: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let monoFormat: AVAudioFormat
    private var loops: [Int: AVAudioPlayerNode] = [:]
    private var idleLoopPlayers: [AVAudioPlayerNode] = []
    private var nextLoop = 0
    private let isOffline: Bool
    private var hasStopped = false

    /// Unplaced voices, a ring per format (sample rate and channel count) — see ``play(_:volume:pan:rate:)``.
    private var directVoices: [DirectFormat: (voices: [DirectVoice], next: Int)] = [:]
    private struct DirectFormat: Hashable { let rate: Double; let channels: AVAudioChannelCount }
    private struct DirectVoice { let player: AVAudioPlayerNode; let speed: AVAudioUnitVarispeed }

    /// The player's volume, before background quiet — what ``masterVolume`` reads back.
    private var requestedMaster: Float = 1
    private var isInBackground = false
    private var focus: AppFocusWatch?
    private let peak = OSAllocatedUnfairLock(initialState: Float(0))
    private var isMetering = false

    /// A loop that is playing. Hand it back to ``moveLoop(_:to:)`` and ``stopLoop(_:)``.
    public struct Loop: Hashable, Sendable {
        fileprivate let id: Int
    }

    /// An engine that plays through the output device.
    ///
    /// - Throws: ``AudioEngineError`` when the device's format is unusable or the engine will not start
    ///   — a machine with no output device, say. A game can run without sound; this says why it is.
    public convenience init(configuration: Configuration = Configuration()) throws {
        try self.init(offline: nil, configuration: configuration)
    }

    /// **An engine with no device at all**, whose mix is pulled with ``renderOffline(seconds:)`` —
    /// for measuring what a game sounds like without anyone listening: how loud a loop is at a
    /// distance, whether it is still going after a minute. `AVAudioEngine`'s manual rendering mode.
    public convenience init(offlineSampleRate sampleRate: Double,
                            configuration: Configuration = Configuration()) throws {
        try self.init(offline: sampleRate, configuration: configuration)
    }

    private init(offline sampleRate: Double?, configuration: Configuration) throws {
        self.configuration = configuration
        isOffline = sampleRate != nil
        if let sampleRate {
            // Before anything is attached: the engine must be stopped, and its format is fixed here.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw AudioEngineError.unsupportedSampleRate(sampleRate)
            }
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            } catch {
                throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
            }
        }
        let rate = sampleRate ?? engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw AudioEngineError.unsupportedSampleRate(rate)
        }
        monoFormat = mono

        engine.attach(effectsBus)
        engine.connect(effectsBus, to: engine.mainMixerNode, format: nil)
        engine.attach(environment)
        engine.connect(environment, to: effectsBus, format: nil)
        engine.attach(ambienceBus)
        engine.connect(ambienceBus, to: engine.mainMixerNode, format: nil)
        engine.attach(nearEnvironment)
        engine.connect(nearEnvironment, to: ambienceBus, format: nil)
        engine.attach(reachEnvironment)
        engine.connect(reachEnvironment, to: ambienceBus, format: nil)
        // No attenuation of its own: every voice through it is levelled by its reach.
        reachEnvironment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        reachEnvironment.distanceAttenuationParameters.referenceDistance = 1
        reachEnvironment.distanceAttenuationParameters.rolloffFactor = 0

        // Distance attenuation in metres, matching the world's units.
        for (node, falloff) in [(environment, configuration.oneShotFalloff),
                                (nearEnvironment, configuration.loopFalloff)] {
            node.distanceAttenuationParameters.distanceAttenuationModel = .inverse
            node.distanceAttenuationParameters.referenceDistance = falloff.referenceDistance
            node.distanceAttenuationParameters.maximumDistance = falloff.maximumDistance
            node.distanceAttenuationParameters.rolloffFactor = falloff.rolloffFactor
        }
        // **Each voice renders `.auto` — HRTF on stereo output — and that is measured, not assumed.**
        // This line used to set `.sphericalHead` on the *environment* node, with a note that spherical
        // head "keeps the directional cue a game reads at a fraction of the cost". Neither half held:
        // the algorithm is a property of each source, so setting it here did nothing, and measured
        // offline a source 5 m to the right comes out **1.01× louder in the right ear under spherical
        // head, against 4.6× under HRTF** and 5.6× under `.auto`. A game that tells a player which way
        // a shot landed needs the second. (If sixteen HRTF voices ever overload the render thread —
        // `HALC_ProxyIOContext: skipping cycle` — the answer is fewer voices, not a model with no cue.)

        // Mono voices: a spatialiser needs a point source, and a stereo file already has a position
        // baked into it that would fight the one being applied.
        for _ in 0..<configuration.voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: environment, format: mono)
            // Per voice, where it takes effect — see above. Once here rather than on every play().
            player.renderingAlgorithm = .auto
            players.append(player)
        }
        for _ in 0..<configuration.voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: reachEnvironment, format: mono)
            player.renderingAlgorithm = .auto
            ambientVoices.append(player)
        }

        do {
            if isOffline {
                try engine.start()
            } else {
                // **Started off the main thread.** Starting the first audio in a process brings up the audio
                // session, and part of that is a synchronous code-signature check on whichever thread asked —
                // reported by Xcode as "this method should not be called on the main thread" on the frame a game
                // starts its sound. The wait is the same either way; the check is not on the main thread.
                let avEngine = engine
                try DispatchQueue.global(qos: .userInitiated).sync { try avEngine.start() }
            }
        } catch {
            throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
        }
        players.forEach { $0.play() }
        ambientVoices.forEach { $0.play() }
        followAppFocus()
    }

    /// Loads a sound and keeps it decoded in memory.
    ///
    /// One-shots are short and are needed *now*; streaming them would add latency to exactly the
    /// sounds that must be immediate.
    ///
    /// **`bundle` has no default, deliberately.** It used to default to `.main`, which is right for
    /// an app bundle and wrong for a SwiftPM executable — there `.main` is the executable itself and
    /// holds no resources, so every load failed and printed. There is no default that is right for
    /// both, and a default that is silently wrong for one of them is worse than making every caller
    /// say where its sounds are. An app passes `.main`; a package target passes `.module`.
    ///
    /// Loading a name already loaded does nothing.
    ///
    /// - Throws: ``AudioEngineError/soundNotFound(_:)`` or ``AudioEngineError/unreadableSound(_:reason:)``.
    public func load(_ name: String, withExtension ext: String = "wav", bundle: Bundle) throws {
        guard buffers[name] == nil else { return }
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw AudioEngineError.soundNotFound("\(name).\(ext)")
        }
        try load(name, url: url)
    }

    /// Loads a sound from a file, under `name` — for a game that finds its sounds itself, such as every
    /// take in a folder. Loading a name already loaded does nothing.
    ///
    /// - Throws: ``AudioEngineError/unreadableSound(_:reason:)``.
    public func load(_ name: String, url: URL) throws {
        guard buffers[name] == nil else { return }
        do {
            buffers[name] = try AudioEngine.decode(url)
        } catch let error as AudioEngineError {
            throw error
        } catch {
            throw AudioEngineError.unreadableSound(url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// **Loads many sounds, reading them off the main thread** — a game's whole library of takes at once,
    /// where reading tens of megabytes on the main thread would stall a frame. Names already loaded are
    /// skipped. Returns what could not be loaded, and why; everything else is ready when it returns.
    public func load(_ files: [String: URL]) async -> [String: AudioEngineError] {
        let wanted = files.filter { buffers[$0.key] == nil }
        let read = await Task.detached(priority: .userInitiated) {
            wanted.mapValues { url -> ReadSound in
                do { return .loaded(DecodedSound(buffer: try AudioEngine.decode(url))) } catch let error as AudioEngineError {
                    return .failed(error)
                } catch {
                    return .failed(.unreadableSound(url.lastPathComponent, reason: error.localizedDescription))
                }
            }
        }.value
        var failures: [String: AudioEngineError] = [:]
        for (name, result) in read {
            switch result {
            case .loaded(let sound): buffers[name] = sound.buffer
            case .failed(let error): failures[name] = error
            }
        }
        return failures
    }

    /// A buffer read on another thread and handed over once — never touched there again.
    nonisolated private struct DecodedSound: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
    nonisolated private enum ReadSound: Sendable { case loaded(DecodedSound), failed(AudioEngineError) }

    nonisolated private static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioEngineError.unreadableSound(url.lastPathComponent, reason: "no buffer for its format")
        }
        try file.read(into: buffer)
        return buffer
    }

    /// Whether a sound is loaded under this name.
    public func isLoaded(_ name: String) -> Bool { buffers[name] != nil }

    /// How long a loaded sound plays at normal speed, in seconds; nil when it is not loaded.
    public func duration(of name: String) -> Double? {
        buffers[name].map { Double($0.frameLength) / $0.format.sampleRate }
    }

    /// Loads a sound from samples already in memory — mono, at `sampleRate` — for a sound a game
    /// makes rather than ships, and for a test that wants a signal it knows exactly. Replaces a sound
    /// already loaded under the name.
    ///
    /// - Throws: ``AudioEngineError/noSamples(_:)`` for an empty array,
    ///   ``AudioEngineError/unsupportedSampleRate(_:)`` for a rate no format can have.
    public func load(_ name: String, samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty else { throw AudioEngineError.noSamples(name) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioEngineError.unsupportedSampleRate(sampleRate)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { throw AudioEngineError.noSamples(name) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        buffers[name] = buffer
        placedBuffers[name] = nil
    }

    /// Where the ears are. Call once per frame.
    public func updateListener(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let point = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        let orientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))
        // Every spatialiser hears from the same head.
        for node in [environment, nearEnvironment, reachEnvironment] {
            node.listenerPosition = point
            node.listenerVectorOrientation = orientation
        }
        listener = position
        for (id, sound) in reached { loops[id]?.volume = sound.level(heardFrom: position) }
    }

    // MARK: - Loops

    /// Starts a sound looping at a world position, until ``stopLoop(_:)``.
    ///
    /// **Each loop starts somewhere different in its sound**, so two braziers playing the same
    /// crackle are not a single crackle in two places — which is what starting both at sample zero
    /// sounds like. Through the near spatializer; see the type's notes.
    ///
    /// **Keep what it returns**: a loop nobody holds cannot be stopped, short of ``stopAllLoops()``.
    /// `nil` when no sound of that name is loaded.
    public func startLoop(_ name: String, at position: SIMD3<Float>, volume: Float = 1) -> Loop? {
        startLoop(name, at: position, volume: volume, reach: nil)
    }

    /// **Starts a sound looping at a world position that carries as far as its own reach** — a generator heard from 60 m
    /// beside a drip heard from 5 — full near it and fading to silence at `reach` metres (``SoundReach``). Through a
    /// spatializer of its own that only says which way the sound is; its level is set from the reach each time the
    /// listener moves. Under ``loopVolume`` with every loop. `nil` when no sound of that name is loaded.
    public func startLoop(_ name: String, at position: SIMD3<Float>, volume: Float = 1, reach: Float?) -> Loop? {
        guard let buffer = placedBuffer(name), buffer.frameLength > 0 else { return nil }
        let player: AVAudioPlayerNode
        if let reach {
            player = idleReachPlayers.popLast() ?? makeLoopPlayer(through: reachEnvironment)
            let sound = SoundReach.Placed(position: position, volume: max(volume, 0), reach: SoundReach.clamped(reach))
            reached[nextLoop] = sound
            player.volume = sound.level(heardFrom: listener)
        } else {
            player = idleLoopPlayers.popLast() ?? makeLoopPlayer(through: nearEnvironment)
            player.volume = volume
        }
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        let id = nextLoop
        nextLoop += 1
        // A different starting point for every loop: Knuth's multiplicative hash of its number.
        let offset = AVAudioFrameCount((UInt64(id) &* 2_654_435_761) % UInt64(buffer.frameLength))
        if offset > 0, let tail = AudioEngine.frames(of: buffer, from: offset) {
            player.scheduleBuffer(tail, at: nil, options: [])
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        loops[id] = player
        return Loop(id: id)
    }

    /// **An ambient bed: a loop heard everywhere, not from a point** — the wind across a valley, a room's
    /// tone, rain. Unplaced and in the sound's own channels (a stereo bed stays wide), under ``loopVolume``
    /// with the placed loops. Stopped with ``stopLoop(_:)``. `nil` when no sound of that name is loaded.
    ///
    /// **Starts somewhere different in its sound each time**, like a placed loop, so two beds of the same
    /// recording are not one sound doubled.
    public func startAmbience(_ name: String, volume: Float = 1) -> Loop? {
        guard let buffer = buffers[name], buffer.frameLength > 0 else { return nil }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: ambienceBus, format: buffer.format)
        player.volume = max(volume, 0)
        let id = nextLoop
        nextLoop += 1
        let offset = AVAudioFrameCount((UInt64(id) &* 2_654_435_761) % UInt64(buffer.frameLength))
        if offset > 0, let tail = AudioEngine.frames(of: buffer, from: offset) {
            player.scheduleBuffer(tail, at: nil, options: [])
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        beds[id] = player
        return Loop(id: id)
    }

    /// An ambient bed's level, 0…1, for a game that fades its weather.
    public func setAmbienceVolume(_ loop: Loop, to volume: Float) {
        beds[loop.id]?.volume = max(volume, 0)
    }

    /// **Any loop's level** — placed, reached or a bed — for a game that fades one, or an editor whose slider moved.
    public func setLoopVolume(_ loop: Loop, to volume: Float) {
        if beds[loop.id] != nil { return setAmbienceVolume(loop, to: volume) }
        if var sound = reached[loop.id] {
            sound.volume = max(volume, 0)
            reached[loop.id] = sound
            loops[loop.id]?.volume = sound.level(heardFrom: listener)
        } else {
            loops[loop.id]?.volume = max(volume, 0)
        }
    }

    /// A reached loop's reach, in metres — an editor's slider. Does nothing to a loop started without one.
    public func setLoopReach(_ loop: Loop, to reach: Float) {
        guard var sound = reached[loop.id] else { return }
        sound.reach = SoundReach.clamped(reach)
        reached[loop.id] = sound
        loops[loop.id]?.volume = sound.level(heardFrom: listener)
    }

    public func moveLoop(_ loop: Loop, to position: SIMD3<Float>) {
        loops[loop.id]?.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        if var sound = reached[loop.id] {
            sound.position = position
            reached[loop.id] = sound
            loops[loop.id]?.volume = sound.level(heardFrom: listener)
        }
    }

    public func stopLoop(_ loop: Loop) {
        if let bed = beds.removeValue(forKey: loop.id) {
            bed.stop()
            engine.detach(bed)
            return
        }
        guard let player = loops.removeValue(forKey: loop.id) else { return }
        player.stop()
        if reached.removeValue(forKey: loop.id) != nil {
            idleReachPlayers.append(player)
        } else {
            idleLoopPlayers.append(player)
        }
    }

    public func stopAllLoops() {
        for loop in (Array(loops.keys) + Array(beds.keys)).map(Loop.init(id:)) { stopLoop(loop) }
    }

    /// Placed loops and ambient beds playing.
    public var loopCount: Int { loops.count + beds.count }

    /// **Made on demand and kept**, unlike the one-shots' fixed ring: a level has as many loops as it
    /// has things that hum, and a voice stolen from a brazier by a footstep is a fire that goes out.
    private func makeLoopPlayer(through environment: AVAudioEnvironmentNode) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: environment, format: monoFormat)
        // As the one-shots: a fire to your left should sound as if it is on your left.
        player.renderingAlgorithm = .auto
        return player
    }

    /// **A sound as a placed voice plays it: one channel at the engine's rate.** A spatializer needs a point source, and
    /// a placed voice is connected in that format — so a stereo recording, or one at 96 kHz, is mixed down and converted
    /// once, the first time it is placed, and kept. Scheduled as it came, it would stop the engine: AVFoundation raises
    /// on a buffer whose format is not its player's. Unplaced sounds keep their own channels and rate.
    private func placedBuffer(_ name: String) -> AVAudioPCMBuffer? {
        if let made = placedBuffers[name] { return made }
        guard let buffer = buffers[name], let made = AudioEngine.converted(buffer, to: monoFormat) else { return nil }
        placedBuffers[name] = made
        return made
    }

    /// `buffer` as one channel at `format`'s rate: its channels averaged, then converted.
    nonisolated static func converted(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source.channelCount == 1, source.sampleRate == format.sampleRate, source.commonFormat == format.commonFormat,
           !source.isInterleaved {
            return buffer
        }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: max(buffer.frameLength, 1)),
              let from = buffer.floatChannelData, let to = mixed.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), channels = Int(source.channelCount)
        mixed.frameLength = buffer.frameLength
        let scale = 1 / Float(max(channels, 1))
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += from[channel][frame] }
            to[0][frame] = sum * scale
        }
        if source.sampleRate == format.sampleRate { return mixed }
        guard let converter = AVAudioConverter(from: mono, to: format) else { return nil }
        let capacity = AVAudioFrameCount((Double(frames) * format.sampleRate / source.sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let handed = HandedOnce(mixed)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            guard let buffer = handed.take() else {
                state.pointee = .endOfStream
                return nil
            }
            state.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    /// The input a converter is given once — called on the converting thread, synchronously.
    nonisolated private final class HandedOnce: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// The frames of `buffer` from `start` to its end, as a buffer of their own.
    private static func frames(of buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let count = buffer.frameLength - start
        guard count > 0, let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let from = buffer.floatChannelData, let to = tail.floatChannelData else { return nil }
        tail.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            to[channel].update(from: from[channel] + Int(start), count: Int(count))
        }
        return tail
    }

    // MARK: - Measuring

    /// Pulls `seconds` of the mix from an engine made with ``init(offlineSampleRate:)``, one array per
    /// output channel. Nil for an engine playing through a device.
    ///
    /// **What makes a sound checkable without ears.** Every level in this type — the loops' falloff,
    /// a loop still going after its buffer has come round — was measured through this before it was
    /// described.
    public func renderOffline(seconds: Float) -> [[Float]]? {
        guard isOffline else { return nil }
        let format = engine.manualRenderingFormat
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return nil }
        let total = AVAudioFrameCount(Double(seconds) * format.sampleRate)
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        var done: AVAudioFrameCount = 0
        while done < total {
            let wanted = min(block.frameCapacity, total - done)
            guard let status = try? engine.renderOffline(wanted, to: block), status == .success,
                  let data = block.floatChannelData else { return nil }
            for channel in channels.indices {
                channels[channel] += UnsafeBufferPointer(start: data[channel], count: Int(block.frameLength))
            }
            done += block.frameLength
        }
        return channels
    }

    /// Plays a sound at a world position.
    ///
    /// - Parameter delay: seconds to wait first. **The reason this exists:** sound travels at about
    ///   343 m/s, so an impact 800 m away is heard nearly two and a half seconds after it happens.
    ///   In most games that is a detail; in one built around long shots it is the feedback loop
    ///   itself, and the wait is the point.
    ///
    /// **The wait is counted on the audio clock**, not the main thread's: it holds while the engine is
    /// paused, is exact to the sample in an offline render, and a sound still waiting is cancelled by
    /// ``stop()`` — none of which held while it was a `DispatchQueue` timer.
    public func play(_ name: String, at position: SIMD3<Float>, volume: Float = 1, delay: Float = 0) {
        guard let buffer = placedBuffer(name) else { return }

        let player = players[nextVoice]
        nextVoice = (nextVoice + 1) % players.count

        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        player.volume = volume
        player.scheduleBuffer(buffer, at: startTime(on: player, after: delay), options: .interrupts)
    }

    /// **A one-shot of the place rather than of play** — a crow, a creak, distant metal — at a world position, as loud
    /// as its own reach allows from where the listener is when it starts (``SoundReach``). **Under ``loopVolume``**, with
    /// the loops and beds, because it is part of a world's ambience: a player who turns the ambience down expects the
    /// crows to go with the wind. A ring of ``Configuration/voiceCount`` voices of its own; when all are busy the oldest
    /// is cut. Nothing when no sound of that name is loaded, or the listener is beyond its reach.
    public func playAmbient(_ name: String, at position: SIMD3<Float>, volume: Float = 1, reach: Float) {
        let sound = SoundReach.Placed(position: position, volume: max(volume, 0), reach: SoundReach.clamped(reach))
        let level = sound.level(heardFrom: listener)
        guard level > 0, let buffer = placedBuffer(name), buffer.frameLength > 0, !ambientVoices.isEmpty else { return }
        let player = ambientVoices[nextAmbientVoice]
        nextAmbientVoice = (nextAmbientVoice + 1) % ambientVoices.count
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        player.volume = level
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// When a voice should start a sound `delay` seconds from now, on its own timeline; `nil` — as soon
    /// as it can — for no delay.
    ///
    /// A voice that has not rendered yet has no "now", and its timeline starts at zero when it does.
    private func startTime(on player: AVAudioPlayerNode, after delay: Float) -> AVAudioTime? {
        guard delay > 0 else { return nil }
        var now: AVAudioFramePosition = 0
        var rate = monoFormat.sampleRate
        if let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            now = playerTime.sampleTime
            rate = playerTime.sampleRate
        }
        return AVAudioTime(sampleTime: now + AVAudioFramePosition((Double(delay) * rate).rounded()), atRate: rate)
    }

    /// Plays without a position — for anything that happens *to the player* rather than in the world, and
    /// for a game that places its sounds by its own rule: the interface, a blow the player threw, a fight
    /// panned by where it is.
    ///
    /// - Parameters:
    ///   - pan: −1 left to +1 right.
    ///   - rate: playback speed, and pitch with it — 1 as recorded. **What makes the same take sound like a
    ///     different blow**; see ``SoundVariation``.
    ///
    /// **Not through the spatializer**: a sound in stereo plays in stereo, at any sample rate. Voices are a
    /// ring per format, ``Configuration/voiceCount`` each, made the first time a format is played; when every
    /// one is busy **the oldest is cut**, which in a fight is the sound the ear has already moved past.
    public func play(_ name: String, volume: Float = 1, pan: Float = 0, rate: Float = 1) {
        guard let buffer = buffers[name], buffer.frameLength > 0 else { return }
        let key = DirectFormat(rate: buffer.format.sampleRate, channels: buffer.format.channelCount)
        if directVoices[key] == nil {
            let voices = (0..<configuration.voiceCount).map { _ in
                let voice = DirectVoice(player: AVAudioPlayerNode(), speed: AVAudioUnitVarispeed())
                engine.attach(voice.player)
                engine.attach(voice.speed)
                engine.connect(voice.player, to: voice.speed, format: buffer.format)
                engine.connect(voice.speed, to: effectsBus, format: buffer.format)
                return voice
            }
            directVoices[key] = (voices, 0)
        }
        guard var ring = directVoices[key] else { return }
        let voice = ring.voices[ring.next]
        ring.next = (ring.next + 1) % ring.voices.count
        directVoices[key] = ring

        voice.player.stop()
        voice.speed.rate = min(max(rate, 0.25), 4)
        voice.player.volume = max(volume, 0)
        voice.player.pan = min(max(pan, -1), 1)
        voice.player.scheduleBuffer(buffer, at: nil, options: [])
        voice.player.play()
    }

    /// The loops, 0…1 — a brazier's crackle, a generator's hum, an ambient bed — and **nothing else**: what
    /// a game offers a player as its ambience setting.
    ///
    /// **On the loops' own bus**, which is why it can be separate at all: every loop and ambient bed and no
    /// one-shot passes through it. A player who wants the fire quieter should not have to turn down
    /// their own footsteps with it, which is what one volume made them do. ``masterVolume`` still
    /// scales everything, this included.
    public var loopVolume: Float {
        get { ambienceBus.outputVolume }
        set { ambienceBus.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Every one-shot, placed or unplaced, 0…1 — what a game offers as its effects setting. Under
    /// ``masterVolume``, beside ``loopVolume``.
    public var effectsVolume: Float {
        get { effectsBus.outputVolume }
        set { effectsBus.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Everything this engine plays, 0…1 — the player's volume setting.
    ///
    /// **On the main mixer, after the spatializer**, so it scales every voice by the same amount
    /// without touching the distance attenuation that says how far away each one is.
    public var masterVolume: Float {
        get { requestedMaster }
        set {
            requestedMaster = min(max(newValue, 0), 1)
            applyMaster()
        }
    }

    /// **Whether the game is heard while it is not the front app.** Off by default: sound still playing over
    /// whatever the player switched to is noise, and the usual next move is to turn it off entirely —
    /// losing the setting they wanted. On for a second monitor with the world on it.
    public var playsInBackground = false {
        didSet { applyMaster() }
    }

    /// The player's sound settings: ``masterVolume``, ``effectsVolume``, ``loopVolume`` and
    /// ``playsInBackground`` from theirs. The score's are ``MusicPlayer/apply(_:)``.
    public func apply(_ settings: PlayerSettings) {
        masterVolume = settings.volume
        effectsVolume = settings.effectsVolume
        loopVolume = settings.ambienceVolume
        playsInBackground = settings.soundInBackground
    }

    private func applyMaster() {
        engine.mainMixerNode.outputVolume = isInBackground && !playsInBackground ? 0 : requestedMaster
    }

    private func followAppFocus() {
        focus = AppFocusWatch { [weak self] background in self?.appFocusChanged(inBackground: background) }
    }

    /// What the application's going to the background, or coming back, does to the mix. Internal for tests,
    /// which call it rather than post app-wide notifications that would reach every engine running beside them.
    func appFocusChanged(inBackground background: Bool) {
        isInBackground = background
        applyMaster()
    }

    // MARK: - Metering

    /// **The loudest sample the mix has carried since the last reset**, 0…1 linear — how a sound is checked
    /// without ears: a play that reaches the output shows here. Call ``startMetering()`` first.
    ///
    /// - Parameter resetting: start the next reading from silence. **Pass `false` while other sounds being
    ///   measured are still playing** — one mix has one peak, and a reset for a second sound erases the first
    ///   one's reading.
    public func readPeak(resetting: Bool = true) -> Float {
        peak.withLock { level in
            defer { if resetting { level = 0 } }
            return level
        }
    }

    /// Starts measuring the mix's peak, for ``readPeak()``. **A tap on the main mixer**, called on a
    /// realtime audio thread — see the type's note on callbacks; this one is `@Sendable` and writes only
    /// through a lock.
    public func startMetering() {
        guard !isMetering else { return }
        isMetering = true
        let peak = peak
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[channel][frame])) }
            }
            let found = loudest
            peak.withLock { $0 = max($0, found) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tap)
    }

    /// Holds everything — one-shots, loops and delayed one-shots still waiting — until ``resume()``.
    public func pause() {
        engine.pause()
    }

    /// Carries on after ``pause()``. Does nothing after ``stop()``, which is final.
    ///
    /// - Throws: ``AudioEngineError/couldNotStart(reason:)`` — the output device went away, say.
    public func resume() throws {
        guard !hasStopped, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
        }
    }

    /// **Final**: stops every sound, cancels any one-shot still waiting on its delay, and frees the
    /// output device. A stopped engine plays nothing again — make a new one. To hold sound for a while,
    /// ``pause()``.
    public func stop() {
        hasStopped = true
        focus = nil
        if isMetering { engine.mainMixerNode.removeTap(onBus: 0) }
        stopAllLoops()
        players.forEach { $0.stop() }
        ambientVoices.forEach { $0.stop() }
        directVoices.values.forEach { $0.voices.forEach { $0.player.stop() } }
        engine.stop()
    }
}

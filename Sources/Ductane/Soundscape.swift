//
//  Soundscape.swift
//  Ductane
//

import Foundation
import simd

/// **A world's sounds, played as its editor laid them out** (``WorldFile/Sounds``): loops at places that start as the
/// listener comes within their reach and stop when they are left behind, ambience that rises and falls by area, sounds
/// now and then, and the world's music.
///
/// A game makes one beside its ``AudioEngine`` and ``MusicPlayer``, hands it the world's sounds once, and tells it where
/// the ears are every frame. **What a game keeps**: when the world is heard at all — ``pause()`` under a menu — and any
/// music that follows play, for which it simply leaves ``music`` out and drives its own player. An editor uses the same
/// type, so what an author hears is what a player will.
///
/// **Only what can be heard plays**: a loop runs while the listener is within its reach, so a world of hundreds of them
/// costs a handful of voices; a scattered sound counts down only while its area is within reach.
public final class Soundscape {

    public let audio: AudioEngine
    /// The world's music plays here, when it has some. Nil leaves the score to the game.
    public let music: MusicPlayer?
    public private(set) var sounds = WorldFile.Sounds()

    /// Loops playing, by point, with the file each plays.
    private var points: [Int: (loop: AudioEngine.Loop, file: String)] = [:]
    /// Ambient beds playing, by ambience, with the file each plays.
    private var beds: [Int: (loop: AudioEngine.Loop, file: String)] = [:]
    /// Seconds until each scattered area's next sound.
    private var waits: [Int: Float] = [:]
    private var variation = SoundVariation(pitchSpread: 0, gainSpreadDecibels: 2)
    private var random: SoundRandom
    private var listener = SIMD3<Float>.zero
    private var isPaused = false

    /// - Parameter seed: where the scattered sounds' timing and places start — fixed, a run sounds the same twice.
    public init(audio: AudioEngine, music: MusicPlayer? = nil, seed: UInt64 = 0x5EED) {
        self.audio = audio
        self.music = music
        random = SoundRandom(seed: seed)
    }

    /// **Plays `sounds` from now on**, its files found by `file` (a path in ``WorldFile/Sounds/files`` to where it is),
    /// loaded off the main thread. Called again with a changed set — an editor's slider — it keeps what is still playing
    /// the same file and changes its level, reach and place in passing, so nothing restarts. Returns the files that could
    /// not be loaded, and why; the rest play.
    @discardableResult
    public func play(_ sounds: WorldFile.Sounds, file: (String) -> URL) async -> [String: AudioEngineError] {
        var wanted: [String: URL] = [:]
        for path in sounds.files {
            let url = file(path)
            urls[path] = url
            if !audio.isLoaded(path) { wanted[path] = url }
        }
        let failures = wanted.isEmpty ? [:] : await audio.load(wanted)
        set(sounds)
        return failures
    }

    /// Takes `sounds` as what is laid out, for files already loaded.
    func set(_ sounds: WorldFile.Sounds) {
        self.sounds = sounds
        for (i, playing) in points {
            guard sounds.points.indices.contains(i), file(of: sounds.points[i].sound) == playing.file else {
                audio.stopLoop(playing.loop)
                points[i] = nil
                continue
            }
            let point = sounds.points[i]
            audio.moveLoop(playing.loop, to: point.position)
            audio.setLoopReach(playing.loop, to: point.reach)
            audio.setLoopVolume(playing.loop, to: point.volume)
        }
        for (i, playing) in beds where !sounds.ambiences.indices.contains(i)
            || file(of: sounds.ambiences[i].sound) != playing.file {
            audio.stopLoop(playing.loop)
            beds[i] = nil
        }
        waits = waits.filter { sounds.scattered.indices.contains($0.key) }
        if let music {
            let tracks = (sounds.music?.tracks ?? []).compactMap { file(of: $0).flatMap { urls[$0] } }
            if tracks.isEmpty {
                if !music.playlist.isEmpty { music.stop() }
            } else {
                music.volume = sounds.music?.volume ?? music.volume
                if !isPaused { music.play(playlist: tracks) }
            }
        }
        refresh()
    }

    /// Where each file is, as ``play(_:file:)`` was told — what the music's player opens.
    private var urls: [String: URL] = [:]

    private func file(of index: Int) -> String? {
        sounds.files.indices.contains(index) ? sounds.files[index] : nil
    }

    /// **Where the ears are, and how long since the last call** — once a frame.
    public func update(listener position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, elapsed seconds: Float) {
        listener = position
        audio.updateListener(position: position, forward: forward, up: up)
        guard !isPaused else { return }
        refresh()
        scatter(elapsed: max(seconds.isFinite ? seconds : 0, 0))
    }

    /// Starts the loops come within reach and stops those left behind, and sets each ambience by where the ears are.
    private func refresh() {
        guard !isPaused else { return }
        for (i, point) in sounds.points.enumerated() {
            let distance = simd_distance(point.position, listener)
            if let playing = points[i] {
                // Left a little way past its reach, so walking along the edge does not start and stop it.
                if distance > point.reach * 1.2 + 5 {
                    audio.stopLoop(playing.loop)
                    points[i] = nil
                }
            } else if distance < point.reach, let path = file(of: point.sound),
                      let loop = audio.startLoop(path, at: point.position, volume: point.volume, reach: point.reach) {
                points[i] = (loop, path)
            }
        }
        let here = SIMD2(listener.x, listener.z)
        for (i, ambience) in sounds.ambiences.enumerated() {
            let level = ambience.volume * SoundArea.presence(ambience.outline, fade: ambience.fade, at: here)
            if let playing = beds[i] {
                if level <= 0 {
                    audio.stopLoop(playing.loop)
                    beds[i] = nil
                } else {
                    audio.setAmbienceVolume(playing.loop, to: level)
                }
            } else if level > 0, let path = file(of: ambience.sound), let loop = audio.startAmbience(path, volume: level) {
                beds[i] = (loop, path)
            }
        }
    }

    /// Counts down each scattered area within reach, and sounds it when its time comes.
    private func scatter(elapsed seconds: Float) {
        let here = SIMD2(listener.x, listener.z)
        for (i, area) in sounds.scattered.enumerated() where !area.sounds.isEmpty {
            guard SoundArea.distanceOutside(area.outline, here) < area.reach else { continue }
            var wait = waits[i] ?? Self.interval(area, using: &random)
            wait -= seconds
            if wait <= 0 {
                if let place = Self.place(for: area, around: listener, using: &random) {
                    let take = variation.take(for: "scattered \(i)", among: area.sounds.count, using: &random)
                    let gain = variation.jitter(using: &random).gain
                    if let path = file(of: area.sounds[take]) {
                        audio.playAmbient(path, at: place, volume: min(area.volume * gain, 1), reach: area.reach)
                    }
                }
                wait = Self.interval(area, using: &random)
            }
            waits[i] = wait
        }
    }

    /// Seconds to the next sound of an area: between its shortest and longest.
    static func interval<G: RandomNumberGenerator>(_ area: WorldFile.Sounds.Scattered, using random: inout G) -> Float {
        let shortest = max(min(area.shortest, area.longest), 0.1), longest = max(area.shortest, area.longest, 0.1)
        return shortest == longest ? shortest : Float.random(in: shortest...longest, using: &random)
    }

    /// **Where a scattered sound is heard from**: a random place inside its area and within most of its reach of the
    /// listener, never right on top of them, up to its height above their ears. Nil when the area has no such place.
    static func place<G: RandomNumberGenerator>(for area: WorldFile.Sounds.Scattered, around listener: SIMD3<Float>,
                                                using random: inout G) -> SIMD3<Float>? {
        let reach = SoundReach.clamped(area.reach) * 0.85, nearest = min(reach * 0.15, 3)
        let here = SIMD2(listener.x, listener.z)
        var low = here - reach, high = here + reach
        if let bounds = SoundArea.bounds(area.outline) {
            low = simd_max(low, bounds.minimum)
            high = simd_min(high, bounds.maximum)
            guard low.x <= high.x, low.y <= high.y else { return nil }
        }
        for _ in 0..<32 {
            let at = SIMD2(Float.random(in: low.x...high.x, using: &random), Float.random(in: low.y...high.y, using: &random))
            let distance = simd_distance(at, here)
            guard distance <= reach, distance >= nearest, SoundArea.contains(area.outline, at) else { continue }
            let rise = area.height > 0 ? Float.random(in: 0...area.height, using: &random) : 0
            return SIMD3(at.x, listener.y + rise, at.y)
        }
        return nil
    }

    /// Loops and beds playing — for a test, or a game's statistics.
    public var playingCount: Int { points.count + beds.count }

    /// **Holds the world's sound** — under a menu, in a paused editor — stopping every loop and bed; ``resume()`` starts
    /// what is in reach again. The music is held too, when it is the world's.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        stopLoops()
        if sounds.music != nil { music?.stop(fade: 0.3) }
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        set(sounds)
    }

    public var paused: Bool { isPaused }

    /// Stops everything it plays; ``play(_:file:)`` starts again.
    public func stop() {
        stopLoops()
        waits = [:]
        if sounds.music != nil { music?.stop() }
        sounds = WorldFile.Sounds()
    }

    private func stopLoops() {
        for playing in points.values { audio.stopLoop(playing.loop) }
        for playing in beds.values { audio.stopLoop(playing.loop) }
        points = [:]
        beds = [:]
    }
}

/// SplitMix64: a small generator that is the same everywhere for a seed — a scattered sound's timing and place.
struct SoundRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

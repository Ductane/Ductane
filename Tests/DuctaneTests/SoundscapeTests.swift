//
//  SoundscapeTests.swift
//  DuctaneTests
//

import AVFoundation
import Foundation
import Testing
import simd
@testable import Ductane

/// **A world's sounds, measured offline** — each sound's own reach, a sound of any format placed, the ambient one-shots,
/// areas, and a world's sounds played as laid out (``Soundscape``).
@MainActor
@Suite("Audio — reach, areas and a world's sounds")
struct SoundscapeTests {

    private static let rate = 48_000.0

    private static let noise: [Float] = {
        var state: UInt32 = 0x1234_5678
        return (0..<48_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
    }()

    private func engine() throws -> AudioEngine {
        let audio = try AudioEngine(offlineSampleRate: Self.rate)
        try audio.load("noise", samples: Self.noise, sampleRate: Self.rate)
        audio.updateListener(position: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        return audio
    }

    private func rms(_ audio: AudioEngine, seconds: Float) throws -> Float {
        let all = try #require(audio.renderOffline(seconds: seconds)).flatMap { $0 }
        return (all.reduce(0) { $0 + $1 * $1 } / Float(max(all.count, 1))).squareRoot()
    }

    private func ahead(_ metres: Float) -> SIMD3<Float> { SIMD3(0, 0, -metres) }

    // MARK: Reach

    @Test("A sound's reach: full near it, a quarter about half way, nothing at or past it")
    func reachCurve() {
        #expect(SoundReach.gain(atDistance: 0.5, reach: 20) == 1)
        #expect(SoundReach.gain(atDistance: 1, reach: 20) == 1)
        let half = SoundReach.gain(atDistance: 10.5, reach: 20)
        #expect(abs(half - 0.25) < 0.001, "\(half)")
        #expect(SoundReach.gain(atDistance: 20, reach: 20) == 0)
        #expect(SoundReach.gain(atDistance: 400, reach: 20) == 0)
        #expect(SoundReach.gain(atDistance: .nan, reach: 20) == 0)
        // A small reach's full-volume radius is a tenth of it.
        #expect(SoundReach.nearDistance(reach: 4) == 0.4)
        #expect(SoundReach.clamped(.infinity) == SoundReach.range.lowerBound)
        #expect(SoundReach.clamped(1e9) == SoundReach.range.upperBound)
    }

    @Test("Two loops at the same place carry as far as their own reaches, and one past its reach is silent")
    func loopsCarryTheirOwnReach() throws {
        let audio = try engine()
        let far = try #require(audio.startLoop("noise", at: ahead(8), reach: 60))
        _ = try rms(audio, seconds: 0.1)
        let wide = try rms(audio, seconds: 0.4)
        audio.setLoopReach(far, to: 12)
        _ = try rms(audio, seconds: 0.1)
        let narrow = try rms(audio, seconds: 0.4)
        audio.setLoopReach(far, to: 6)
        _ = try rms(audio, seconds: 0.1)
        let gone = try rms(audio, seconds: 0.4)
        print("AUDIO reach 60/12/6 at 8 m: \(wide), \(narrow), \(gone)")
        #expect(wide > 0.01, "a 60 m sound at 8 m is heard: \(wide)")
        // The curve says (1 − 7/59)² against (1 − 6.8/10.8)²: about 0.78 and 0.14 — a ratio near 5.6.
        #expect(narrow < wide * 0.3 && narrow > wide * 0.1, "a 12 m sound is much quieter at 8 m: \(narrow) against \(wide)")
        #expect(gone < 1e-4, "past its reach it is silent: \(gone)")
    }

    @Test("A reached loop follows the listener: walking away fades it, and its volume can be set")
    func reachFollowsListener() throws {
        let audio = try engine()
        let loop = try #require(audio.startLoop("noise", at: ahead(2), volume: 1, reach: 20))
        _ = try rms(audio, seconds: 0.1)
        let near = try rms(audio, seconds: 0.4)
        audio.updateListener(position: SIMD3(0, 0, 13), forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        _ = try rms(audio, seconds: 0.1)
        let away = try rms(audio, seconds: 0.4)
        audio.setLoopVolume(loop, to: 0.5)
        _ = try rms(audio, seconds: 0.1)
        let halved = try rms(audio, seconds: 0.4)
        #expect(away < near * 0.5, "walked off: \(away) against \(near)")
        #expect(abs(halved / away - 0.5) < 0.08, "half volume: \(halved / away)")
    }

    @Test("A stereo file at another rate placed as a loop and a one-shot plays, mixed down, without stopping the engine")
    func placedStereo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("we-placed-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for frame in 0..<48_000 {
            buffer.floatChannelData![0][frame] = 0.4 * sin(Float(frame) * 0.03)
            buffer.floatChannelData![1][frame] = 0.4 * sin(Float(frame) * 0.03)
        }
        do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
        let audio = try engine()
        try audio.load("wide", url: url)
        let loop = try #require(audio.startLoop("wide", at: ahead(3), reach: 30))
        _ = try rms(audio, seconds: 0.1)
        #expect(try rms(audio, seconds: 0.3) > 0.01)
        audio.stopLoop(loop)
        audio.play("wide", at: ahead(3))
        _ = try rms(audio, seconds: 0.05)
        #expect(try rms(audio, seconds: 0.2) > 0.01)
        // Half a second of 96 kHz is half a second at the engine's rate.
        let converted = try #require(AudioEngine.converted(buffer, to: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!))
        #expect(converted.format.channelCount == 1)
        #expect(abs(Int(converted.frameLength) - 24_000) < 200, "\(converted.frameLength)")
    }

    @Test("An ambient one-shot is heard within its reach, not beyond, and follows ambience, not effects")
    func ambientOneShot() throws {
        let audio = try engine()
        audio.playAmbient("noise", at: ahead(5), reach: 30)
        _ = try rms(audio, seconds: 0.05)
        let heard = try rms(audio, seconds: 0.3)
        _ = try rms(audio, seconds: 1)
        audio.playAmbient("noise", at: ahead(40), reach: 30)
        let beyond = try rms(audio, seconds: 0.3)
        audio.effectsVolume = 0
        audio.playAmbient("noise", at: ahead(5), reach: 30)
        _ = try rms(audio, seconds: 0.05)
        let effectsOff = try rms(audio, seconds: 0.3)
        _ = try rms(audio, seconds: 1)
        audio.loopVolume = 0
        audio.playAmbient("noise", at: ahead(5), reach: 30)
        _ = try rms(audio, seconds: 0.05)
        let ambienceOff = try rms(audio, seconds: 0.3)
        #expect(heard > 0.01)
        #expect(beyond < 1e-4)
        #expect(abs(effectsOff / heard - 1) < 0.1, "effects at nothing leaves it: \(effectsOff) against \(heard)")
        #expect(ambienceOff < 1e-4)
    }

    // MARK: Areas

    @Test("An area: inside, outside, how far out, and ambience easing to nothing at its fade")
    func areas() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        #expect(SoundArea.contains(square, SIMD2(5, 5)))
        #expect(!SoundArea.contains(square, SIMD2(15, 5)))
        #expect(SoundArea.contains(square.reversed(), SIMD2(5, 5)))
        #expect(SoundArea.distanceOutside(square, SIMD2(5, 5)) == 0)
        #expect(abs(SoundArea.distanceOutside(square, SIMD2(13, 5)) - 3) < 1e-5)
        #expect(abs(SoundArea.distanceOutside(square, SIMD2(13, 14)) - 5) < 1e-5)
        #expect(SoundArea.presence(square, fade: 10, at: SIMD2(5, 5)) == 1)
        #expect(abs(SoundArea.presence(square, fade: 10, at: SIMD2(15, 5)) - 0.5) < 1e-5)
        #expect(SoundArea.presence(square, fade: 10, at: SIMD2(20, 5)) == 0)
        // Fewer than three corners is the whole world.
        #expect(SoundArea.contains([], SIMD2(1e6, -1e6)))
        #expect(SoundArea.presence([SIMD2(0, 0)], fade: 1, at: SIMD2(1e6, 0)) == 1)
    }

    @Test("A scattered sound's place is inside its area, within its reach, and not on top of the listener")
    func scatteredPlace() throws {
        let square: [SIMD2<Float>] = [SIMD2(-20, -20), SIMD2(20, -20), SIMD2(20, 20), SIMD2(-20, 20)]
        let area = WorldFile.Sounds.Scattered(sounds: [0], outline: square, reach: 30, height: 4)
        var random = SoundRandom(seed: 7)
        let listener = SIMD3<Float>(15, 1.7, 0)
        for _ in 0..<200 {
            let p = try #require(Soundscape.place(for: area, around: listener, using: &random))
            #expect(SoundArea.contains(square, SIMD2(p.x, p.z)))
            let d = simd_distance(SIMD2(p.x, p.z), SIMD2(listener.x, listener.z))
            #expect(d <= 30 * 0.85 + 1e-4 && d >= 3 - 1e-4, "\(d)")
            #expect(p.y >= 1.7 && p.y <= 5.7 + 1e-4)
        }
        // An area wholly beyond its reach has nowhere to sound.
        let far = WorldFile.Sounds.Scattered(sounds: [0], outline: square.map { $0 + SIMD2(500, 0) }, reach: 30)
        #expect(Soundscape.place(for: far, around: listener, using: &random) == nil)
        for _ in 0..<50 {
            let wait = Soundscape.interval(WorldFile.Sounds.Scattered(sounds: [0], shortest: 4, longest: 9), using: &random)
            #expect(wait >= 4 && wait <= 9)
        }
    }

    // MARK: A world's sounds

    private func world(_ sounds: WorldFile.Sounds) async throws -> Soundscape {
        let audio = try engine()
        let scape = Soundscape(audio: audio)
        // Already loaded under its path: nothing to read.
        await scape.play(sounds) { URL(filePath: "/nonexistent/\($0)") }
        return scape
    }

    private func walk(_ scape: Soundscape, to point: SIMD3<Float>, seconds: Float = 0.1) {
        scape.update(listener: point, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), elapsed: seconds)
    }

    /// The world's music level was written over the player's volume, so the music slider stopped working the moment a
    /// world with music was shown; and pausing stopped the score, so resuming started it from the top.
    @Test("A world's music level is a mix under the player's volume, and a pause holds it in place")
    func worldMusicMixesAndHolds() async throws {
        let audio = try engine()
        let music = MusicPlayer(volume: 0.6)
        let scape = Soundscape(audio: audio, music: music)
        let sounds = WorldFile.Sounds(files: ["score.m4a"], music: .init(tracks: [0], volume: 0.3))
        await scape.play(sounds) { URL(filePath: "/nonexistent/\($0)") }
        #expect(abs(music.volume - 0.6) < 1e-6, "the world's level replaced the player's")
        #expect(abs(music.mix - 0.3) < 1e-6 && abs(music.heard - 0.18) < 1e-6)
        let playlist = music.playlist
        #expect(playlist.count == 1)

        scape.pause()
        #expect(music.isHeld && music.playlist == playlist, "a pause stopped the score instead of holding it")
        scape.resume()
        #expect(!music.isHeld && music.playlist == playlist)

        scape.stop()
        #expect(music.playlist.isEmpty && music.mix == 1 && !music.isHeld)
        await music.settle()
    }

    @Test("A world's loop starts as the listener comes within reach and stops once left behind")
    func pointsStartAndStop() async throws {
        let scape = try await world(WorldFile.Sounds(files: ["noise"], points: [.init(sound: 0, position: .zero, reach: 20)]))
        walk(scape, to: SIMD3(100, 0, 0))
        #expect(scape.playingCount == 0)
        walk(scape, to: SIMD3(15, 0, 0))
        #expect(scape.playingCount == 1)
        _ = try rms(scape.audio, seconds: 0.05)
        #expect(try rms(scape.audio, seconds: 0.3) > 0.001)
        walk(scape, to: SIMD3(25, 0, 0))
        #expect(scape.playingCount == 1, "kept a little past its reach")
        walk(scape, to: SIMD3(40, 0, 0))
        #expect(scape.playingCount == 0)
        // Changing its reach in passing keeps it playing rather than starting it again.
        walk(scape, to: SIMD3(5, 0, 0))
        await scape.play(WorldFile.Sounds(files: ["noise"], points: [.init(sound: 0, position: .zero, volume: 0.5, reach: 50)])) { URL(filePath: $0) }
        #expect(scape.playingCount == 1)
        scape.pause()
        #expect(scape.playingCount == 0)
        walk(scape, to: SIMD3(5, 0, 0))
        #expect(scape.playingCount == 0, "nothing starts while held")
        scape.resume()
        #expect(scape.playingCount == 1)
        scape.stop()
        #expect(scape.playingCount == 0)
    }

    @Test("An ambience plays inside its area, fades outside it, and stops past the fade")
    func ambience() async throws {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let scape = try await world(WorldFile.Sounds(files: ["noise"],
                                                     ambiences: [.init(sound: 0, outline: square, fade: 10, volume: 1)]))
        walk(scape, to: SIMD3(5, 0, 5))
        _ = try rms(scape.audio, seconds: 0.05)
        let inside = try rms(scape.audio, seconds: 0.3)
        walk(scape, to: SIMD3(15, 0, 5))
        _ = try rms(scape.audio, seconds: 0.05)
        let edge = try rms(scape.audio, seconds: 0.3)
        walk(scape, to: SIMD3(25, 0, 5))
        #expect(scape.playingCount == 0)
        #expect(inside > 0.01)
        #expect(abs(edge / inside - 0.5) < 0.08, "half way through its fade: \(edge / inside)")
    }

    @Test("A scattered area sounds now and then while within reach, and not while far off")
    func scattered() async throws {
        let square: [SIMD2<Float>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]
        let scape = try await world(WorldFile.Sounds(files: ["noise"], scattered: [
            .init(sounds: [0], outline: square, shortest: 1, longest: 1, volume: 1, reach: 30, height: 0)]))
        walk(scape, to: SIMD3(300, 0, 0), seconds: 5)
        #expect(try rms(scape.audio, seconds: 0.3) < 1e-4, "far off: nothing")
        walk(scape, to: SIMD3(0, 0, 0), seconds: 0.5)
        walk(scape, to: SIMD3(0, 0, 0), seconds: 0.6)
        _ = try rms(scape.audio, seconds: 0.02)
        #expect(try rms(scape.audio, seconds: 0.3) > 0.001, "its second came: a sound")
    }

    // MARK: Day and night

    @Test("Daylight from the sun: night 6° below the horizon, day 4° above; hours weigh by it")
    func daylight() {
        let degree = Float.pi / 180
        #expect(Soundscape.daylight(sunElevation: -10 * degree) == 0)
        #expect(Soundscape.daylight(sunElevation: 10 * degree) == 1)
        #expect(abs(Soundscape.daylight(sunElevation: -1 * degree) - 0.5) < 0.01)
        #expect(Soundscape.daylight(sunElevation: .nan) == 1)
        typealias Hours = WorldFile.Sounds.Hours
        #expect(Hours.always.weight(daylight: 0) == 1 && Hours.day.weight(daylight: 0.25) == 0.25)
        #expect(Hours.night.weight(daylight: 0.25) == 0.75 && Hours.day.weight(daylight: .nan) == 1)
    }

    @Test("An ambience with a night loop plays its day loop by day, its night loop by night, and both through dusk")
    func nightAmbience() async throws {
        let audio = try engine()
        try audio.load("crickets", samples: Self.noise, sampleRate: Self.rate)
        let scape = Soundscape(audio: audio)
        await scape.play(WorldFile.Sounds(files: ["noise", "crickets"], ambiences: [.init(sound: 0, night: 1, volume: 1)])) {
            URL(filePath: "/nonexistent/\($0)")
        }
        walk(scape, to: .zero)
        #expect(scape.playingCount == 1, "day: the day loop")
        _ = try rms(audio, seconds: 0.05)
        let day = try rms(audio, seconds: 0.3)
        scape.setDaylight(0.5)
        walk(scape, to: .zero)
        #expect(scape.playingCount == 2, "dusk: both, each at half")
        scape.setDaylight(0)
        walk(scape, to: .zero)
        #expect(scape.playingCount == 1, "night: the night loop")
        _ = try rms(audio, seconds: 0.05)
        #expect(abs(try rms(audio, seconds: 0.3) / day - 1) < 0.15, "as loud by night as by day")
        // One loop and no night loop plays day and night.
        await scape.play(WorldFile.Sounds(files: ["noise"], ambiences: [.init(sound: 0, volume: 1)])) { URL(filePath: $0) }
        walk(scape, to: .zero)
        #expect(scape.playingCount == 1)
    }

    @Test("A loop heard by night fades in as the light goes; scattered sounds by day are silent at night")
    func hours() async throws {
        let scape = try await world(WorldFile.Sounds(files: ["noise"], points: [.init(sound: 0, position: .zero, reach: 20,
                                                                                      hours: .night)]))
        walk(scape, to: SIMD3(2, 0, 0))
        #expect(scape.playingCount == 0, "a night loop by day: nothing")
        scape.setDaylight(0)
        walk(scape, to: SIMD3(2, 0, 0))
        #expect(scape.playingCount == 1)
        scape.setDaylight(1)
        walk(scape, to: SIMD3(2, 0, 0))
        #expect(scape.playingCount == 0, "gone again at dawn")

        let crows = try await world(WorldFile.Sounds(files: ["noise"], scattered: [
            .init(sounds: [0], shortest: 1, longest: 1, volume: 1, reach: 30, height: 0, hours: .day)]))
        crows.setDaylight(0)
        walk(crows, to: .zero, seconds: 0.5)
        walk(crows, to: .zero, seconds: 0.6)
        #expect(try rms(crows.audio, seconds: 0.3) < 1e-4, "crows by day are silent at night")
        crows.setDaylight(1)
        walk(crows, to: .zero, seconds: 0.5)
        walk(crows, to: .zero, seconds: 0.6)
        _ = try rms(crows.audio, seconds: 0.02)
        #expect(try rms(crows.audio, seconds: 0.3) > 0.001, "and heard by day")
    }

    // MARK: The world file

    @Test("A world's sounds survive the world file, and one naming a file it has not, or outside its package, is refused")
    func worldFile() throws {
        var world = WorldFile(name: "w", props: [], placements: [])
        world.sounds = WorldFile.Sounds(
            files: ["sounds/1_Wind/wind.caf", "sounds/1_Wind/crow_01.wav", "sounds/2_Music/theme.m4a"],
            points: [.init(sound: 0, position: SIMD3(1, 2, 3), volume: 0.7, reach: 25)],
            ambiences: [.init(sound: 0, outline: [SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 5)], fade: 8, volume: 0.4)],
            scattered: [.init(sounds: [1], outline: [], shortest: 3, longest: 12, volume: 0.9, reach: 50, height: 6)],
            music: .init(tracks: [2], volume: 0.3))
        let read = try WorldFile.read(world.data())
        #expect(read == world)
        // Day and night: a night loop and hours survive; always is not written, and an hour not known is always.
        var nights = world
        nights.sounds?.ambiences[0].night = 1
        nights.sounds?.points[0].hours = .night
        nights.sounds?.scattered[0].hours = .day
        #expect(try WorldFile.read(nights.data()) == nights)
        #expect(!String(decoding: try JSONEncoder().encode(world.sounds), as: UTF8.self).contains("hours"))
        let odd = try JSONDecoder().decode(WorldFile.Sounds.Point.self,
                                           from: Data(#"{"sound":0,"position":[0,0,0],"hours":"dusk"}"#.utf8))
        #expect(odd.hours == .always && odd.volume == 1 && odd.reach == 20)
        var badNight = world
        badNight.sounds?.ambiences[0].night = 7
        #expect(throws: WorldFile.ReadError.badSound(7)) { try WorldFile.read(badNight.data()) }
        // A file from before sounds has none.
        #expect(try WorldFile.read(WorldFile(name: "w", props: [], placements: []).data()).sounds == nil)
        // Only the files are required.
        let bare = try JSONDecoder().decode(WorldFile.Sounds.self, from: Data(#"{"files":["a.wav"]}"#.utf8))
        #expect(bare.files == ["a.wav"] && bare.points.isEmpty && bare.music == nil)

        var bad = world
        bad.sounds?.music = .init(tracks: [9])
        #expect(throws: WorldFile.ReadError.badSound(9)) { try WorldFile.read(bad.data()) }
        var outside = world
        outside.sounds?.files[0] = "../../wind.caf"
        #expect(throws: WorldFile.ReadError.unsafePath("../../wind.caf")) { try WorldFile.read(outside.data()) }
    }

    @Test("A playlist plays its tracks in turn and comes round again; one track loops")
    func playlist() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("we-playlist-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Silence: a test never sounds through the speakers.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        var tracks: [URL] = []
        for name in ["one", "two"] {
            let url = folder.appendingPathComponent("\(name).caf")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 13_230))
            buffer.frameLength = 13_230   // 0.3 s
            do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
            tracks.append(url)
        }
        let music = MusicPlayer(volume: 0.01)
        music.fadeIn = 0
        music.playsInBackground = true
        music.play(playlist: tracks)
        await music.settle()
        #expect(music.playlist == tracks)
        // Read from the deck's own record: this test's main actor can be held up for longer than a track lasts.
        var started: [String] = []
        for _ in 0..<200 where started.count < 3 {
            try await Task.sleep(for: .milliseconds(50))
            started = await music.startedTracks().map(\.lastPathComponent)
        }
        #expect(Array(started.prefix(3)) == ["one.caf", "two.caf", "one.caf"], "the tracks started in the order \(started)")
        music.stop(fade: 0)
        await music.settle()
        #expect(await music.current() == nil)
    }
}

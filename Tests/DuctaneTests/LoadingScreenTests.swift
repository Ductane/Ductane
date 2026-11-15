//
//  LoadingScreenTests.swift
//  DuctaneTests
//

import Testing
@testable import Ductane

@Suite("The loading screen")
struct LoadingScreenTests {

    @Test("It is up and opaque from the first frame, with an empty bar")
    func upFromTheStart() {
        let screen = LoadingScreen()
        #expect(screen.opacity == 1 && screen.shownProgress == 0 && !screen.isLifting && !screen.isFinished)
    }

    @Test("The bar follows what is reported, no faster than its climb, never past it")
    func climbs() {
        var screen = LoadingScreen()
        screen.report(0.6)
        screen.advance(by: 0.1)
        #expect(abs(screen.shownProgress - screen.climbRate * 0.1) < 1e-5, "after 0.1 s it shows \(screen.shownProgress)")
        screen.advance(by: 5)
        #expect(screen.shownProgress == 0.6, "it ran to \(screen.shownProgress), past the 0.6 reported")
    }

    @Test("A smaller share than before is ignored, and the bar never goes back")
    func neverBack() {
        var screen = LoadingScreen()
        screen.report(0.5)
        screen.advance(by: 2)
        screen.report(0.2)
        screen.advance(by: 2)
        #expect(screen.progress == 0.5 && screen.shownProgress == 0.5)
        screen.report(7)
        #expect(screen.progress == 1, "a share past the whole is the whole")
    }

    /// **Not ready is not finished, however full the bar.** A game that reports everything it counts and then still has
    /// one thing to wait for must not see the screen lift on its own.
    @Test("A full bar without finish() holds")
    func holdsUntilReady() {
        var screen = LoadingScreen()
        screen.report(1)
        screen.advance(by: 10)
        #expect(screen.opacity == 1 && !screen.isLifting && screen.sinceFull == nil)
    }

    @Test("Once ready it fills, holds for the settle, fades, and lifts as the fade begins")
    func theEnd() {
        var screen = LoadingScreen()
        screen.report(0.4)
        screen.advance(by: 1)
        screen.finish()
        // 0.6 to climb at 1.5 a second: 0.4 s.
        screen.advance(by: 0.2)
        #expect(screen.sinceFull == nil && screen.opacity == 1, "not full yet at \(screen.shownProgress)")
        screen.advance(by: 0.2)
        #expect(screen.shownProgress == 1 && (screen.sinceFull ?? 1) < 1e-4)
        screen.advance(by: screen.settle / 2)
        #expect(screen.opacity == 1 && !screen.isLifting, "the settle is held at full strength")
        screen.advance(by: screen.settle / 2 + screen.fadeOut / 2)
        #expect(screen.isLifting && abs(screen.opacity - 0.5) < 1e-4, "half way down it is \(screen.opacity)")
        screen.advance(by: screen.fadeOut / 2)
        #expect(screen.opacity == 0 && screen.isFinished && screen.isLifting)
        screen.report(0.1)
        #expect(screen.progress == 1, "nothing reported after the end changes it")
    }

    /// The same picture at the same moment, however often the game steps — the fades are ramps, as the splash's are.
    @Test("Its opacity at a moment is the same at any step rate", arguments: [Float(30), 60, 144, 240])
    func sameAtAnyRate(rate: Float) {
        func run(_ seconds: Float, at rate: Float) -> LoadingScreen {
            var screen = LoadingScreen()
            screen.finish()
            let dt = 1 / rate
            var t: Float = 0
            while t < seconds - dt / 2 { screen.advance(by: dt); t += dt }
            return screen
        }
        for moment in [Float(0.5), 0.9, 1.1, 1.3, 2] {
            let mine = run(moment, at: rate).opacity, reference = run(moment, at: 2000).opacity
            #expect(abs(mine - reference) < 0.03, "at \(rate) a second, \(moment) s in it was \(mine) where it is \(reference)")
        }
    }

    @Test("The percentage is what the bar shows, rounded down: 100 only when full")
    func percent() {
        var screen = LoadingScreen()
        screen.report(0.999)
        screen.advance(by: 10)
        #expect(screen.percent == 99)
        screen.finish()
        screen.advance(by: 1)
        #expect(screen.percent == 100)
    }
}

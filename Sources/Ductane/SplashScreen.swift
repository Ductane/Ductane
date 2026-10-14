//
//  SplashScreen.swift
//  Ductane
//

import simd

/// The engine saying its own name: a lockup of ``EngineMark`` and the name over a ground, for as long
/// as a game wants and no longer.
///
/// ### What the engine owes here, and what it does not
///
/// The engine owes the **surface** — a thing that can be shown, timed, skipped and drawn with no art,
/// no texture and no pipeline of its own, so that a game which wants to credit the engine has nothing
/// to build. It does not owe the decision: nothing here runs unless a game runs it, and
/// ``SplashScreen`` does not install itself in the frame loop.
///
/// ### What goes on it, and what does not
///
/// **The tile, and one line under it**: a black ground, EngineMark centered, and *Made with Ductane* beneath. It reads
/// in one glance.
///
/// - **No version.** No engine shows one in a shipped game: a version belongs to an editor's splash, an about box and a
///   log. showsVersion is there for development builds and is off.
/// - **The lead is worth its two words here.** A splash showing only a logo works for an engine every player already
///   recognizes; nobody recognizes this one yet, and "Made with" says what they are looking at.
///
/// The line is set in the host's own interface font.
///
/// ### It does not stop the game, and it must not swallow the key that skips it
///
/// **Advance it from your simulation step, draw it from your HUD.** It is an overlay and a clock, not
/// a mode: the game goes on stepping behind it, which is what a game is usually *for* during a splash
/// — loading. Two things follow:
///
/// - A game that suspends its step while this is up makes its own first second unrepeatable.
/// - **``skip()`` must be a side effect of a press, never a consumer of it.** A splash that eats the
///   first keystroke eats the first keystroke of whatever the player was already doing — in the
///   sample's case the first press of a scripted walk, which then ends 1.2 m short. There is a check
///   for exactly that (a recorded walk, "crate behind the splash").
///
/// ### The fades are ramps, so the picture is the same at any step rate
///
/// Everything here is linear in ``elapsed``, and ``elapsed`` is a sum of step lengths. A game at 30
/// steps a second and one at 240 show the same opacity at the same moment.
public nonisolated struct SplashScreen: Sendable {

    /// Seconds fading up from nothing.
    public var fadeIn: Float = 0.4
    /// Seconds at full strength.
    public var hold: Float = 1.6
    /// Seconds fading away.
    public var fadeOut: Float = 0.5

    /// Seconds from going up before a press can skip it.
    ///
    /// **A splash that can be skipped on the frame it appears is one nobody ever sees**: the key or
    /// the click that launched the game is often still down when the first frame goes up, and the
    /// splash is gone before it has drawn once.
    public var skipDelay: Float = 0.25

    /// What is behind the lockup.
    public var background = EngineMark.ground

    /// The engine's name under the tile.
    public var foreground = EngineMark.letter

    /// The lead, in a quieter tone.
    public var leadColor = InterfaceColor(hex: 0xC9C9D0)

    /// Words set before the engine's name on the line under the tile: `"Made with"` is the usual lead. Nil sets the name
    /// alone.
    public var lead: String?

    /// The mark's size — it is square — as a share of the viewport's width. Everything else in the
    /// lockup is sized from the mark.
    public var markScale: Float = 0.12

    /// Whether ``Engine/version`` is drawn under the name. **Off**: no shipped game shows its engine's
    /// version, and a recorded frame that could see it would fail on every release.
    public var showsVersion = false

    /// Seconds since it went up.
    public private(set) var elapsed: Float = 0

    /// Whether ``skip()`` has been taken.
    public private(set) var isSkipped = false

    public init(lead: String? = nil) {
        self.lead = lead
    }

    /// How long it lasts if nobody skips it.
    public var duration: Float { fadeIn + hold + fadeOut }

    /// Nothing left to draw. **Drop it when this is true** — an overlay at zero opacity still costs
    /// its vertices.
    public var isFinished: Bool { elapsed >= duration }

    /// 0…1, up the ramp, flat, and down again.
    public var opacity: Float {
        if elapsed <= 0 { return 0 }
        if elapsed < fadeIn { return fadeIn > 0 ? elapsed / fadeIn : 1 }
        if elapsed < fadeIn + hold { return 1 }
        if elapsed < duration { return fadeOut > 0 ? (duration - elapsed) / fadeOut : 0 }
        return 0
    }

    /// Call once per simulation step.
    public mutating func advance(by seconds: Float) {
        elapsed = min(duration, elapsed + max(0, seconds))
    }

    /// Cut it short — **by running it to the start of its fade, not by ending it.**
    ///
    /// A splash that vanishes on the frame a key goes down looks like a dropped frame; one that fades
    /// out over its own fade looks like it was always going to. Ignored until ``skipDelay`` has
    /// passed, and ignored again once it is already fading, so leaning on a key does not shorten
    /// the fade twice.
    public mutating func skip() {
        guard elapsed >= skipDelay, elapsed < fadeIn + hold else { return }
        elapsed = fadeIn + hold
        isSkipped = true
    }

    /// Draws it over the whole viewport. Call from `encodeHUD`, after everything else.
    ///
    /// - Parameter viewportSize: the size the HUD was begun with, in the same units.
    @MainActor
    public func draw(into hud: HUDRenderer, viewportSize viewport: SIMD2<Float>) {
        let alpha = opacity
        guard alpha > 0, viewport.x > 0, viewport.y > 0 else { return }

        hud.fillRect(origin: .zero, size: viewport,
                     color: background.withAlpha(background.srgb.w * alpha))

        let mark = viewport.x * markScale
        let point = mark * 0.2, gap = mark * 0.3
        let leadWords = lead.map { $0 + " " } ?? ""
        let leadWidth = hud.width(of: leadWords, pointSize: point)
        let lineWidth = leadWidth + hud.width(of: Engine.name, pointSize: point)

        // The tile and its line, centered together.
        let top = (viewport.y - (mark + gap + point)) / 2
        EngineMark.draw(into: hud, origin: SIMD2((viewport.x - mark) / 2, top), height: mark, opacity: alpha)

        let baseline = top + mark + gap + point * 0.72
        let x = (viewport.x - lineWidth) / 2
        _ = hud.text(leadWords, atBaseline: SIMD2(x, baseline), pointSize: point,
                     color: leadColor.withAlpha(leadColor.srgb.w * alpha))
        // The HUD has one weight, so the name is struck twice, a hair apart, to stand heavier than its lead.
        let ink = foreground.withAlpha(foreground.srgb.w * alpha)
        for strike in [Float(0), point * 0.035] {
            _ = hud.text(Engine.name, atBaseline: SIMD2(x + leadWidth + strike, baseline), pointSize: point, color: ink)
        }

        if showsVersion {
            _ = hud.text(Engine.version, atBaseline: SIMD2(x, baseline + point * 1.5), pointSize: point * 0.8,
                         color: ink.withAlpha(ink.srgb.w * 0.45))
        }
    }
}

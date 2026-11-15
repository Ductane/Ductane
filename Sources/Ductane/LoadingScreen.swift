//
//  LoadingScreen.swift
//  Ductane
//

import simd

/// What stands in front of a world while it loads, so a player is never put into one that is half there.
///
/// ### Why a game wants one, even when its loading is fast
///
/// A world drawn while it streams in shows its ground first, then everything standing on it arriving at once, with the
/// player already in it — and, for as long as the walls are not solid, standing in a place they cannot yet walk. A
/// loading screen hides all of that, and its **settle** hides one more thing: the first frames of the finished world,
/// drawn behind it while it is still opaque, are the frames where every pipeline is first used and every texture first
/// read — the hitch a player would otherwise feel in their first step.
///
/// ### What the engine owes here, and what it does not
///
/// The **state**: progress that only goes forward and climbs smoothly however lumpy the stages reporting it are, the
/// moment the world is ready, the hold, the fade, and the moment to hand the player control (``isLifting``). And a plain
/// **look** (``draw(into:viewportSize:)``), with no art, so a game has a working loading screen before it has a designed
/// one. A game with its own art draws its own from ``shownProgress`` and ``opacity``. What *counts* as loaded is the
/// game's to say — ``report(_:)`` as it goes, ``finish()`` when the world is whole.
///
/// ### It does not stop the game
///
/// **Advance it from your simulation step, draw it from your HUD, last.** It is an overlay and a clock, as
/// ``SplashScreen`` is: the frame loop keeps running behind it — that is what draws the settle's frames — and a game
/// decides for itself what it holds back until ``isLifting`` (the player's controls, a mission's clock).
///
/// ### The fades are ramps, so the picture is the same at any step rate
///
/// Everything here is linear in step lengths, as ``SplashScreen``'s is.
public nonisolated struct LoadingScreen: Sendable {

    /// Seconds held at full strength once the world is ready and the bar is full: the finished world's first frames, drawn
    /// out of sight.
    public var settle: Float = 0.35
    /// Seconds fading away.
    public var fadeOut: Float = 0.6
    /// **How fast the bar may climb**, in shares of the whole a second. A stage that lands at once — a quarter of the work
    /// done in one step — still reads as filling rather than jumping; the bar never runs ahead of what was reported.
    public var climbRate: Float = 1.5

    /// What is behind it. Near-black rather than black, so it reads as a surface.
    public var background = InterfaceColor(hex: 0x0B0D10)
    /// The lettering and the bar in the plain look.
    public var foreground = InterfaceColor(srgb: SIMD4(0.92, 0.93, 0.95, 1))
    /// The world's name, large, in the plain look. Nil draws none.
    public var title: String?
    /// A line under it — what the player is about to do. Nil draws none.
    public var subtitle: String?

    /// The share of the work done, as last reported: 0 … 1, never less than before.
    public private(set) var progress: Float = 0
    /// **What the bar shows**: following ``progress`` at ``climbRate`` at most, never past it, never back.
    public private(set) var shownProgress: Float = 0
    /// Whether ``finish()`` has been called.
    public private(set) var isReady = false
    /// Seconds since it went up.
    public private(set) var elapsed: Float = 0
    /// Seconds since the world was ready and the bar full; nil until then.
    public private(set) var sinceFull: Float?

    public init(title: String? = nil, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    /// The share of the work done so far, 0 … 1. A smaller share than before is ignored: a bar that goes backwards reads
    /// as something gone wrong.
    public mutating func report(_ share: Float) {
        guard !isReady, share.isFinite else { return }
        progress = max(progress, min(max(share, 0), 1))
    }

    /// The world is whole: the bar runs to the end, holds for ``settle``, and fades.
    public mutating func finish() {
        isReady = true
        progress = 1
    }

    /// Call once per simulation step.
    public mutating func advance(by seconds: Float) {
        let dt = max(0, seconds)
        elapsed += dt
        let before = shownProgress
        shownProgress = min(progress, shownProgress + climbRate * dt)
        if let since = sinceFull {
            sinceFull = min(since + dt, settle + fadeOut)
        } else if isReady, shownProgress >= 1 {
            // Counted from the moment in this step the bar filled, not from the step's end — so the fade is the same at
            // any step rate.
            let filling = climbRate > 0 ? (1 - before) / climbRate : 0
            sinceFull = min(max(dt - filling, 0), settle + fadeOut)
        }
    }

    /// 1 until the settle is over, then down a ramp to 0.
    public var opacity: Float {
        guard let since = sinceFull, since > settle else { return 1 }
        return fadeOut > 0 ? max(0, 1 - (since - settle) / fadeOut) : 0
    }

    /// **The fade has begun: the moment to hand the player their controls.** Before it the screen is opaque, and a press
    /// would move someone nobody can see.
    public var isLifting: Bool { (sinceFull ?? 0) > settle || isFinished }

    /// Nothing left to draw. **Drop it when this is true.**
    public var isFinished: Bool { (sinceFull ?? 0) >= settle + fadeOut }

    /// The whole share as a percentage, as a bar's label reads it: `0` … `100`.
    public var percent: Int { Int((shownProgress * 100).rounded(.down)) }

    // MARK: The plain look

    /// **The plain look**, over the whole viewport: the ground, the title and its line low on the left, and a thin bar
    /// across the foot with the percentage over its right end. Call from `encodeHUD`, after everything else.
    @MainActor
    public func draw(into hud: HUDRenderer, viewportSize viewport: SIMD2<Float>) {
        let alpha = opacity
        guard alpha > 0, viewport.x > 0, viewport.y > 0 else { return }
        hud.fillRect(origin: .zero, size: viewport, color: background.withAlpha(background.srgb.w * alpha))

        let unit = viewport.y / 1080
        let margin = 72 * unit
        let ink = foreground.withAlpha(foreground.srgb.w * alpha)
        let barHeight = max(3 * unit, 1), barY = viewport.y - margin
        let barWidth = viewport.x - 2 * margin
        hud.fillRect(origin: SIMD2(margin, barY), size: SIMD2(barWidth, barHeight), color: ink.withAlpha(ink.srgb.w * 0.18))
        hud.fillRect(origin: SIMD2(margin, barY), size: SIMD2(barWidth * shownProgress, barHeight), color: ink)

        let label = "\(percent)%", labelPoint = 20 * unit
        _ = hud.text(label, atBaseline: SIMD2(margin + barWidth - hud.width(of: label, pointSize: labelPoint), barY - 18 * unit),
                     pointSize: labelPoint, color: ink.withAlpha(ink.srgb.w * 0.7))

        var baseline = barY - 60 * unit
        if let subtitle {
            _ = hud.text(subtitle, atBaseline: SIMD2(margin, baseline), pointSize: 26 * unit, color: ink.withAlpha(ink.srgb.w * 0.75))
            baseline -= 52 * unit
        }
        if let title {
            _ = hud.text(title.uppercased(), atBaseline: SIMD2(margin, baseline), pointSize: 64 * unit, color: ink)
        }
    }
}

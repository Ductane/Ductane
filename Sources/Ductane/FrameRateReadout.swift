//
//  FrameRateReadout.swift
//  Ductane
//

/// **A frame rate a person can read**: the average frame time and the worst frame since the last reading, put out a few
/// times a second.
///
/// **An average and a worst, not one number.** A mean of 16.7 ms with a worst of 17 ms is a smooth game; the same mean
/// with a worst of 90 ms is a game that hitches, and the hitch is what a player notices. One number cannot tell those
/// apart.
///
/// **The worst since the last reading, not the worst ever.** A single hitch while a level loaded would otherwise sit on
/// screen for the rest of the session, and the question the number answers is whether it is hitching now.
///
/// **A reading every ``framesPerReading`` frames**: a number that changes sixty times a second cannot be read.
///
/// Feed it each frame's interval (``FrameTimes/interval``, from ``FrameRenderer/lastFrameTimes``) and draw ``reading``.
public nonisolated struct FrameRateReadout: Sendable, Equatable {

    public struct Reading: Sendable, Equatable {
        /// Frames a second, from the average.
        public var framesPerSecond: Double
        /// The average frame time, in milliseconds.
        public var average: Double
        /// The longest frame since the reading before, in milliseconds.
        public var worst: Double

        public init(framesPerSecond: Double, average: Double, worst: Double) {
            self.framesPerSecond = framesPerSecond
            self.average = average
            self.worst = worst
        }
    }

    /// How far each frame pulls the average toward itself: about the last twenty frames count.
    public var smoothing: Double
    public var framesPerReading: Int
    /// Frames longer than this count as this long: a window hidden for a minute reports one enormous gap, and it is only
    /// a number shown.
    public var longest: Double

    /// The latest reading; nil until the first.
    public private(set) var reading: Reading?

    private var average: Double = 0
    private var worst: Double = 0
    private var frames = 0

    public init(smoothing: Double = 0.05, framesPerReading: Int = 10, longest: Double = 250) {
        self.smoothing = smoothing
        self.framesPerReading = max(framesPerReading, 1)
        self.longest = longest
    }

    /// Adds one frame's interval, in milliseconds; true when it put out a new ``reading``. A frame of 0 — the first, with
    /// nothing before it — is skipped.
    @discardableResult
    public mutating func add(_ milliseconds: Double) -> Bool {
        guard milliseconds > 0, milliseconds.isFinite else { return false }
        let frame = min(milliseconds, longest)
        average = average == 0 ? frame : average + (frame - average) * smoothing
        worst = max(worst, frame)
        frames += 1
        guard frames >= framesPerReading else { return false }
        reading = Reading(framesPerSecond: 1000 / average, average: average, worst: worst)
        frames = 0
        worst = 0
        return true
    }
}

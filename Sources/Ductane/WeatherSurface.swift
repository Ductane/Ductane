import simd

/// **The frame's weather, as a game's own shaders read it** — `DUWeatherSurface` in `DuctaneWeather.h`, field for field.
///
/// The engine draws the sky, the clouds, rain and snow falling and the fog volume itself; a game's props and ground are
/// drawn by its own shaders, and those call `DuctaneWeather.h` for what the weather does to them — snow lying, dust
/// settled, wet ground and puddles, footprints, leaves turning and falling, swaying in the wind, the clouds' shadows and
/// the fog. This block is what those functions read: write one each frame from the frame's weather and put it in the game's
/// own frame uniforms (a stored property of its uniforms struct, mirrored by a `DUWeatherSurface` member on the Metal side).
///
/// **All `SIMD4<Float>` and `simd_float4x4`**, so Swift and Metal lay it out the same with no padding to disagree about.
public nonisolated struct WeatherSurface: Sendable, Equatable {
    /// Lying snow: x how much (`Weather.lyingSnow`), y how deep on the ground in metres (0 for the layer alone), z 1 when
    /// the cover is drawn, w the cover's texels a side.
    public var snow: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    /// What is overhead (``WeatherCover``): world to its clip space.
    public var cover: simd_float4x4 = matrix_identity_float4x4
    /// x the cover's top, y its depth range (``WeatherCover/depthRange``).
    public var coverTop: SIMD4<Float> = SIMD4(0, WeatherCover.depthRange, 0, 0)
    /// Footprints (``FootprintGrid``): x, y the grid's corner; z a cell's size.
    public var prints: SIMD4<Float> = SIMD4(0, 0, FootprintGrid.cellSize, 0)
    /// x 1 when there are prints to look for, y cells a side.
    public var printGrid: SIMD4<Float> = SIMD4(0, Float(FootprintGrid.cellsPerSide), 0, 0)
    /// Wet ground: x how wet surfaces are (`Weather.wetness`), y how full the puddles are (`Weather.puddles`), z how hard it
    /// rains now (0 in snow), w the weather's clock, seconds, wrapped every ten minutes.
    public var wet: SIMD4<Float> = .zero
    /// Fall colors (``FallColors/colours``): the three colours trees turn to, linear.
    public var fallColour0: SIMD4<Float> = .zero
    public var fallColour1: SIMD4<Float> = .zero
    public var fallColour2: SIMD4<Float> = .zero
    /// x how thick fallen leaves lie under turning trees (``FallColors/litter(phase:)``), y 1 when the field of where they
    /// lie is bound, z how far the litter has gone brown (``FallColors/litterBrown(phase:)``).
    public var fallLitter: SIMD4<Float> = .zero
    /// The clouds (``CloudLayer``), for their shadows: x coverage, y darkness, z base, w thickness. Coverage 0 for none.
    public var clouds: SIMD4<Float> = .zero
    /// Where the clouds are on their pattern (``CloudLayer/motion``).
    public var cloudMotion: SIMD4<Float> = SIMD4(0, -1, 0, 0)
    /// Dust settled in a dust storm: rgb its colour (``Weather/dustColour``), a how much.
    public var dust: SIMD4<Float> = .zero
    /// The fog volume (``VolumetricFog/Lookup/parameters``), for `duFogApply`.
    public var fogVolume: SIMD4<Float> = .zero

    /// No weather: nothing lies, nothing is wet, no clouds, no fog volume — what a clear day draws.
    public init() {}

    /// **The weather on a frame's surfaces.**
    ///
    /// - Parameters:
    ///   - weather: the weather this frame — ``Weather/current(at:)`` at the world's clock, for a world with a schedule.
    ///   - snowDepth: whether the player's graphics settings raise the ground by lying snow (``GraphicsSettings/snowDepth``);
    ///     the weather itself says whether it has depth (``Weather/snowDepth``).
    ///   - cover: what is overhead, and whether it was drawn this frame — nothing lies or is wet under cover only when it was.
    ///   - footprints: the prints near the eye, and whether this frame has any to look for.
    ///   - time: the weather's clock, seconds — what rain's rings and running water move by.
    ///   - clouds: the frame's clouds (``Weather/clouds(at:)``), nil for none.
    ///   - fall: the world's fall colors and where foliage is in its year (``FallColors/phase(yearPosition:southern:)``),
    ///     nil when foliage stays as drawn; `litterBound`, whether the game binds a field of where leaves lie.
    ///   - fog: the fog volume's lookup this frame (``VolumetricFog/Drawn/lookup``).
    @MainActor
    public init(weather: Weather, snowDepth: Bool = true, cover: WeatherCover? = nil, coverDrawn: Bool = false,
                footprints: FootprintGrid? = nil, printsDrawn: Bool = false, time: Double = 0, clouds: CloudLayer? = nil,
                fall: (colors: FallColors, phase: Float)? = nil, litterBound: Bool = false,
                fog: VolumetricFog.Lookup = .none) {
        let lying = weather.lyingSnow
        let depth = weather.snowDepth && snowDepth ? lying * Weather.deepestSnow : 0
        snow = SIMD4(lying, depth, coverDrawn ? 1 : 0, Float(cover?.resolution ?? 1))
        self.cover = coverDrawn ? (cover?.viewProjection ?? matrix_identity_float4x4) : matrix_identity_float4x4
        coverTop = SIMD4(cover?.top ?? 0, WeatherCover.depthRange, 0, 0)
        prints = SIMD4(footprints?.origin.x ?? 0, footprints?.origin.y ?? 0, FootprintGrid.cellSize, 0)
        printGrid = SIMD4(printsDrawn ? 1 : 0, Float(FootprintGrid.cellsPerSide), 0, 0)
        wet = SIMD4(weather.wetness, weather.puddles, weather.settings.snow ? 0 : weather.settings.precipitation,
                    Float(time.truncatingRemainder(dividingBy: 600)))
        let dusty = weather.settings.dust
        if dusty > 0 { dust = SIMD4(weather.dustColour, dusty * 0.7) }
        if let clouds {
            self.clouds = SIMD4(clouds.coverage, clouds.darkness, clouds.base, clouds.thickness)
            cloudMotion = clouds.motion
        }
        if let fall {
            let c = fall.colors.colours
            fallColour0 = SIMD4(c[0], 0)
            fallColour1 = SIMD4(c[1], 0)
            fallColour2 = SIMD4(c[2], 0)
            fallLitter = SIMD4(fall.colors.litter(phase: fall.phase), litterBound ? 1 : 0,
                               FallColors.litterBrown(phase: fall.phase), 0)
        }
        fogVolume = fog.parameters
    }
}

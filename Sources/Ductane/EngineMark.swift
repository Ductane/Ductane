//
//  EngineMark.swift
//  Ductane
//

import simd

/// The engine's own mark: **a tile from the periodic table**, the element Du.
///
/// ### Why the engine has one at all
///
/// An engine is a thing other people ship with, and every engine that is says so somewhere: a splash, a credit, a
/// logo in a corner. **Nothing in `LICENSE` requires it**, which makes this a choice about what the engine is rather
/// than an obligation to encode. SplashScreen is the surface that shows it; this is the drawing.
///
/// ### What it is a picture of
///
/// Ductane is named for ductile metal, so it is drawn as a metal: a square cobalt tile with its symbol in white.
/// **The corners are square, never rounded.** The tile is a cell of a table, and a rounded one is an app icon.
///
/// ### Two cuts of the letters
///
/// Letters that are right at 64 points close up at 16, so a tile under smallBelow points sets them larger:
///
/// | cut | where | size on a 64 grid | baseline |
/// |---|---|---|---|
/// | Cut/plain | 24 points and up | 36 | 45 |
/// | Cut/small | under 24 points | 42 | 47 |
///
/// Both are centred, with the letters drawn 1.5 closer than the type sets them.
///
/// ### The letters are outlines, so there is one drawing of them
///
/// The tables below are Inter Tight ExtraBold's **D** and **u** (SIL Open Font License), traced once in the font's
/// own units and kept as data. Nothing here needs the font, and no host can substitute another. The D is two shapes
/// that overlap, a stem and a bowl, as the type's own drawing is; filled in one color they read as one. letters(_:)
/// is the only description of the mark: draw(into:origin:height:opacity:) fills it, every file in `Brand/` is
/// written from it, and `EngineMarkTests` fails if a file and this disagree.
public nonisolated enum EngineMark {

    /// Which drawing of the letters a tile uses.
    public enum Cut: Sendable, CaseIterable {
        /// Tiles of 24 points and up.
        case plain
        /// Tiles under 24 points, where the letters are set larger to stay open.
        case small

        /// The type size on the tile's 64 grid.
        var size: Float { self == .plain ? 36 : 42 }
        /// The baseline on the tile's 64 grid, down from the top.
        var baseline: Float { self == .plain ? 45 : 47 }
    }

    /// The tile height, in points, under which Cut/small is drawn.
    public static let smallBelow: Float = 24

    /// The cut a tile of this height uses.
    public static func cut(forHeight height: Float) -> Cut { height < smallBelow ? .small : .plain }

    /// The mark is square.
    static let aspect: Float = 1

    /// The mark's width at a given height.
    public static func width(forHeight height: Float) -> Float { height * aspect }

    /// The tile: cobalt.
    public static let tile = InterfaceColor(hex: 0x1C3FE0)

    /// The letters on the tile: white.
    public static let letter = InterfaceColor(hex: 0xFFFFFF)

    /// The ground the mark is shown on when it has the screen to itself, as SplashScreen does: black.
    public static let ground = InterfaceColor(hex: 0x0B0B0C)

    /// The font units the tables below are written in.
    private static let unitsPerEm: Float = 2048
    /// Where the type sets the **u**, in font units from the start of the **D**.
    private static let tailOrigin: Float = 1437
    /// How much closer the letters are drawn than the type sets them, on the 64 grid.
    private static let tracking: Float = -1.5

    // Inter Tight ExtraBold, in font units, y upward from the baseline. Each list is x, y, x, y, in order round the shape.
    private static let stem: [Int16] = [
        443, 1490, 443, 0, 84, 0, 84, 1490,
    ]

    private static let bowl: [Int16] = [
        635, 0, 237, 0, 237, 307, 620, 307, 681, 310, 709, 313, 762, 324, 787, 331, 811, 340, 854, 361, 874, 374,
        892, 389, 910, 405, 940, 443, 965, 488, 976, 513, 985, 540, 999, 600, 1004, 633, 1007, 669, 1010, 745, 1009,
        784, 1004, 857, 999, 890, 985, 950, 976, 977, 965, 1002, 953, 1025, 940, 1047, 909, 1085, 892, 1101, 873,
        1116, 853, 1129, 832, 1140, 785, 1159, 733, 1172, 705, 1177, 646, 1182, 614, 1183, 231, 1183, 231, 1490,
        634, 1490, 690, 1489, 744, 1484, 796, 1477, 846, 1468, 894, 1455, 940, 1440, 984, 1421, 1026, 1400, 1066,
        1377, 1104, 1351, 1139, 1322, 1172, 1292, 1203, 1258, 1231, 1223, 1257, 1185, 1280, 1144, 1301, 1101, 1319,
        1056, 1334, 1010, 1347, 961, 1356, 910, 1363, 857, 1368, 802, 1369, 745, 1368, 688, 1363, 633, 1356, 580,
        1347, 529, 1334, 480, 1319, 433, 1301, 388, 1280, 346, 1257, 305, 1231, 267, 1203, 231, 1172, 198, 1139,
        167, 1104, 138, 1066, 112, 1026, 89, 984, 68, 940, 50, 894, 35, 846, 22, 796, 13, 745, 6, 691, 1,
    ]

    private static let tail: [Int16] = [
        804, 482, 804, 1118, 1160, 1118, 1160, 0, 820, 0, 820, 208, 808, 208, 798, 183, 787, 160, 774, 137, 759,
        116, 724, 78, 704, 61, 683, 46, 660, 31, 636, 19, 585, 0, 529, -11, 468, -14, 413, -11, 386, -7, 336, 6,
        312, 15, 290, 26, 268, 38, 246, 52, 208, 83, 190, 101, 159, 140, 132, 184, 111, 234, 96, 287, 91, 315, 87,
        344, 84, 405, 84, 1118, 440, 1118, 440, 474, 441, 452, 443, 431, 447, 412, 452, 393, 459, 376, 476, 345,
        500, 319, 513, 309, 544, 292, 578, 283, 597, 281, 617, 280, 643, 281, 679, 289, 701, 298, 722, 310, 750,
        332, 758, 341, 779, 372, 790, 396, 798, 422, 804, 466,
    ]

    /// The letters of a cut as filled shapes, **in a unit square with its origin at the top left**: y downward, the same
    /// as HUDRenderer. Stem, bowl, then the **u**.
    public static func letters(_ cut: Cut) -> [[SIMD2<Float>]] {
        let scale = cut.size / unitsPerEm
        let tailX = tailOrigin * scale + tracking
        let shapes: [(table: [Int16], x: Float)] = [(stem, 0), (bowl, 0), (tail, tailX)]
        let placed = shapes.map { shape in
            stride(from: 0, to: shape.table.count, by: 2).map { index in
                SIMD2(Float(shape.table[index]) * scale + shape.x, cut.baseline - Float(shape.table[index + 1]) * scale)
            }
        }
        // Centred by what is drawn, so the space either side of the letters is equal.
        let xs = placed.joined().map(\.x)
        let shift = 32 - ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        return placed.map { shape in shape.map { SIMD2($0.x + shift, $0.y) / 64 } }
    }

    /// Fills the tile with its top-left corner at `origin` and the given height.
    ///
    /// - Parameter opacity: 0…1 over the whole mark, for a fade.
    @MainActor
    public static func draw(into hud: HUDRenderer, origin: SIMD2<Float>, height: Float, opacity: Float = 1) {
        guard height > 0, opacity > 0 else { return }
        hud.fillRect(origin: origin, size: SIMD2(repeating: height), color: tile.withAlpha(tile.srgb.w * opacity))
        let ink = letter.withAlpha(letter.srgb.w * opacity)
        for shape in letters(cut(forHeight: height)) {
            hud.fillPolygon(shape.map { origin + $0 * height }, color: ink)
        }
    }
}

//
//  EngineMarkTests.swift
//  DuctaneTests
//

import Foundation
import Testing
import simd
@testable import Ductane

/// **The mark in `Brand/` and the mark on screen are one drawing.**
///
/// Every file in `Brand/` that shows the mark is written from ``EngineMark/letters(_:)`` by the functions below, and
/// this suite fails if a file on disk and the letters disagree. Redraw the mark by changing `EngineMark` and
/// re-recording:
///
/// ```
/// DUCTANE_RECORD_MARK=1 swift test --filter EngineMarkTests
/// ```
///
/// The PNG exports in `Brand/exports` are rasterised from these files.
@Suite("The engine's mark")
struct EngineMarkTests {

    static var brand: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/DuctaneTests/EngineMarkTests.swift
            .deletingLastPathComponent()          // …/Tests/DuctaneTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/
            .appendingPathComponent("Brand")
    }

    /// A number as short as it can be written without changing it, so a re-recording diffs as a moved
    /// point and not as a reformatted file.
    static func number(_ value: Float) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func hex(_ color: InterfaceColor) -> String {
        let c = SIMD3(color.srgb.x, color.srgb.y, color.srgb.z) * 255
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    /// The tile and its letters, filling a square of `side` units placed at `inset`.
    static func tile(_ cut: EngineMark.Cut, side: Float, inset: Float = 0) -> String {
        let square = "  <rect x=\"\(number(inset))\" y=\"\(number(inset))\" width=\"\(number(side))\" height=\"\(number(side))\""
            + " fill=\"\(hex(EngineMark.tile))\"/>\n"
        let shapes = EngineMark.letters(cut).map { shape in
            let points = shape.map { "\(number(inset + $0.x * side)),\(number(inset + $0.y * side))" }.joined(separator: " ")
            return "  <polygon fill=\"\(hex(EngineMark.letter))\" points=\"\(points)\"/>\n"
        }
        return square + shapes.joined()
    }

    static func file(_ side: Int, _ description: String, _ body: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(side) \(side)\" width=\"\(side)\" height=\"\(side)\""
            + " role=\"img\" aria-label=\"\(Engine.name)\">\n"
            + "  <title>\(Engine.name)</title>\n"
            + "  <desc>\(description) Generated from EngineMark.letters — see Brand/README.md.</desc>\n"
            + body + "</svg>\n"
    }

    static let files: [(name: String, contents: String)] = [
        ("ductane.svg", file(64, "The tile.", tile(.plain, side: 64))),
        // The app icon on Apple's 1024 grid: an 824 tile, inset 100.
        ("ductane-icon.svg", file(1024, "App icon on the 1024 grid.", tile(.plain, side: 824, inset: 100))),
        // A browser tab: the small cut, full bleed.
        ("favicon.svg", file(64, "Favicon.", tile(.small, side: 64))),
    ]

    @Test("Every mark in Brand/ is the mark in the code", arguments: files.map(\.name))
    func fileMatchesTheLetters(name: String) throws {
        let wanted = try #require(Self.files.first { $0.name == name }).contents
        let url = Self.brand.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["DUCTANE_RECORD_MARK"] != nil {
            try FileManager.default.createDirectory(at: Self.brand, withIntermediateDirectories: true)
            try wanted.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let complaint = "\(name) is not what EngineMark.letters draws. Re-record it: "
            + "DUCTANE_RECORD_MARK=1 swift test --filter EngineMarkTests"
        #expect(onDisk == wanted, "\(complaint)")
    }

    @Test("The letters stay inside the tile", arguments: EngineMark.Cut.allCases)
    func insideTheTile(cut: EngineMark.Cut) {
        for point in EngineMark.letters(cut).joined() {
            #expect(point.x > 0 && point.x < 1 && point.y > 0 && point.y < 1, "a point is at \(point)")
        }
    }

    @Test("The letters are centered across the tile", arguments: EngineMark.Cut.allCases)
    func centered(cut: EngineMark.Cut) {
        let xs = EngineMark.letters(cut).joined().map(\.x)
        #expect(abs((xs.min()! + xs.max()!) / 2 - 0.5) < 1e-5)
    }

    /// The baseline is where the specification puts it: the flat foot of the stem.
    @Test("The stem stands on the cut's baseline", arguments: EngineMark.Cut.allCases)
    func baseline(cut: EngineMark.Cut) throws {
        let stem = try #require(EngineMark.letters(cut).first)
        #expect(abs(stem.map(\.y).max()! * 64 - cut.baseline) < 1e-4)
    }

    /// What the small cut is for: it has to stand taller than the plain one, or there is no reason to have it.
    @Test("The small cut sets the letters larger")
    func smallIsLarger() {
        func height(_ cut: EngineMark.Cut) -> Float {
            let ys = EngineMark.letters(cut).joined().map(\.y)
            return ys.max()! - ys.min()!
        }
        #expect(height(.small) > height(.plain))
    }

    @Test("Tiles under 24 points use the small cut")
    func cutBySize() {
        #expect(EngineMark.cut(forHeight: 23.9) == .small)
        #expect(EngineMark.cut(forHeight: 24) == .plain)
    }

    /// The fill rule depends on it: an outline that crosses itself triangulates short.
    @Test("No shape crosses itself", arguments: EngineMark.letters(.plain).indices)
    func simple(index: Int) {
        let o = EngineMark.letters(.plain)[index], n = o.count
        func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
            func turn(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            return turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0
        }
        for i in 0..<n {
            for j in 0..<n where j != i && (j + 1) % n != i && (i + 1) % n != j {
                #expect(!crosses(o[i], o[(i + 1) % n], o[j], o[(j + 1) % n]), "edge \(i) crosses edge \(j)")
            }
        }
    }

    /// Filled, each shape covers exactly its outline: the triangles' areas add up to the polygon's.
    @Test("Its triangles cover exactly its outlines", arguments: EngineMark.letters(.plain).indices)
    func trianglesCoverIt(index: Int) {
        let o = EngineMark.letters(.plain)[index]
        let indices = HUDRenderer.triangulate(o)
        #expect(indices.count == (o.count - 2) * 3)
        #expect(abs(HUDTriangulationTests.area(of: indices, in: o) - HUDTriangulationTests.area(of: o)) < 1e-5)
    }

    /// Cobalt and white, and a square tile: the corners are never rounded.
    @Test("Each file is a square cobalt tile with white letters", arguments: files.map(\.contents))
    func tones(contents: String) {
        #expect(contents.contains("fill=\"#1C3FE0\""))
        #expect(contents.contains("fill=\"#FFFFFF\""))
        #expect(!contents.contains("rx="))
    }
}

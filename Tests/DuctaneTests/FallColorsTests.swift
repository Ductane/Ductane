//
//  FallColorsTests.swift
//  DuctaneTests
//

import Foundation
import Testing
import simd
@testable import Ductane

@Suite("Fall colors: foliage through the year")
struct FallColorsTests {

    @Test("The phase runs from midsummer, half a year on in the south")
    func phase() {
        // The clock's year: 0 midwinter, 1 spring, 2 summer, 3 autumn (northern).
        #expect(abs(FallColors.phase(yearPosition: 2, southern: false)) < 1e-6)
        #expect(abs(FallColors.phase(yearPosition: 3, southern: false) - 1) < 1e-6)
        #expect(abs(FallColors.phase(yearPosition: 0, southern: false) - 2) < 1e-6)
        #expect(abs(FallColors.phase(yearPosition: 1, southern: false) - 3) < 1e-6)
        // Southern midsummer is the northern midwinter.
        #expect(abs(FallColors.phase(yearPosition: 0, southern: true)) < 1e-6)
    }

    @Test("Green in summer, turned in autumn, bare in winter, green again in spring")
    func theYear() {
        let fall = FallColors()
        #expect(fall.turn(phase: 0, timing: 0.5) == 0)
        #expect(fall.leaves(phase: 0, timing: 0.5) == 1)
        #expect(fall.turn(phase: 1.15, timing: 0.5) > 0.99)
        #expect(fall.leaves(phase: 1.0, timing: 0.5) == 1)
        #expect(fall.leaves(phase: 2, timing: 0.5) == 0)
        #expect(fall.litter(phase: 1.9) > 0.9)
        #expect(fall.litter(phase: 3.5) == 0)
        #expect(fall.leaves(phase: 3.3, timing: 0.5) == 1)
        #expect(fall.turn(phase: 3.3, timing: 0.5) == 0)
        #expect(fall.straw(phase: 2, timing: 0.5) > 0.99)
        #expect(fall.straw(phase: 0, timing: 0.5) == 0)
    }

    @Test("Each tree turns at its own pace; trees that keep their leaves go brown instead of bare")
    func treesDiffer() {
        let fall = FallColors()
        #expect(fall.turn(phase: 0.75, timing: 1) > fall.turn(phase: 0.75, timing: 0) + 0.2)
        let kept = FallColors(bareInWinter: false)
        #expect(kept.leaves(phase: 2, timing: 0.5) == 1)
        #expect(kept.brown(phase: 2, timing: 0.5) > 0.99)
        #expect(kept.litter(phase: 1.9) < fall.litter(phase: 1.9))
    }

    @Test("Turning none keeps leaves green; colours come from the palette")
    func extentAndPalette() {
        #expect(FallColors(extent: 0).turn(phase: 1, timing: 0.5) == 0)
        let fiery = FallColors(palette: .fiery)
        #expect(fiery.colour(pick: 0) == FallColors.Palette.fiery.colours[0])
        #expect(simd_distance(fiery.colour(pick: 1), FallColors.Palette.fiery.colours[2]) < 1e-5)
        let own = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        #expect(FallColors(palette: .custom, custom: own).colour(pick: 0.5) == SIMD3(0, 1, 0))
    }

    @Test("A tree's seed is fixed by where it stands, and spread over 0…1")
    func seeds() {
        let a = FallColors.seed(x: 12.3, z: -40.1)
        #expect(a.timing == FallColors.seed(x: 12.3, z: -40.1).timing)
        let picks = (0..<400).map { FallColors.seed(x: Float($0) * 1.7, z: Float($0 % 13) * 3.1).pick }
        #expect(picks.min()! < 0.1 && picks.max()! > 0.9)
    }

    @Test("Saved and read back; a file missing values reads as the defaults")
    func coding() throws {
        let fall = FallColors(palette: .custom, custom: [SIMD3(0.5, 0.2, 0.1), SIMD3(0.4, 0.3, 0.2), SIMD3(0.1, 0.1, 0.1)],
                              extent: 0.6, bareInWinter: false)
        let back = try JSONDecoder().decode(FallColors.self, from: JSONEncoder().encode(fall))
        #expect(back == fall)
        #expect(try JSONDecoder().decode(FallColors.self, from: Data("{}".utf8)) == FallColors())
        let clock = WorldClock(foliage: fall)
        #expect(try JSONDecoder().decode(WorldClock.self, from: JSONEncoder().encode(clock)).foliage == fall)
    }

    @Test("Foliage is guessed from a prop's name")
    func guesses() {
        #expect(Foliage.guess(name: "SM_Env_Tree_Pine_01") == .evergreen)
        #expect(Foliage.guess(name: "PineTree01") == .evergreen)
        #expect(Foliage.guess(name: "SM_Env_Tree_Meadow_02") == .turns)
        #expect(Foliage.guess(name: "SM_Env_Bush_01") == .turns)
        #expect(Foliage.guess(name: "SM_Env_Grass_Tall_01") == .grass)
        #expect(Foliage.guess(name: "SM_Env_Reeds_03") == .grass)
        #expect(Foliage.guess(name: "SM_Env_Tree_Dead_01") == .unchanged)
        #expect(Foliage.guess(name: "SM_Prop_Crate_01") == .unchanged)
        #expect(Foliage.guess(name: "SM_Env_Palm_Tree_02") == .evergreen)
        #expect(Foliage.words("SM_Env_TreeBirch02") == ["sm", "env", "tree", "birch"])
    }

    @Test("A world file carries foliage by prop, and refuses one naming a prop it does not have")
    func worldFile() throws {
        var file = WorldFile(name: "Wood", props: ["a.usda", "b.usda"], foliage: [1: .turns], placements: [])
        let back = try WorldFile.read(JSONEncoder().encode(file))
        #expect(back.foliage == [1: .turns])
        file.foliage = [5: .grass]
        #expect(throws: WorldFile.ReadError.self) { try WorldFile.read(JSONEncoder().encode(file)) }
    }
}

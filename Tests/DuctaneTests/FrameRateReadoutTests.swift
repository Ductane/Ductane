//
//  FrameRateReadoutTests.swift
//  DuctaneTests
//

import Testing
@testable import Ductane

struct FrameRateReadoutTests {

    @Test("A reading every tenth frame: the average and the frames a second it makes")
    func readings() {
        var readout = FrameRateReadout()
        for _ in 0..<9 {
            let out = readout.add(16.667)
            #expect(!out)
        }
        #expect(readout.reading == nil)
        let tenth = readout.add(16.667)
        #expect(tenth)
        let reading = try! #require(readout.reading)
        #expect(abs(reading.average - 16.667) < 1e-6)
        #expect(abs(reading.framesPerSecond - 60) < 0.01)
        #expect(abs(reading.worst - 16.667) < 1e-6)
    }

    @Test("A hitch shows as the worst for one reading and is gone from the next; the average barely moves")
    func hitch() {
        var readout = FrameRateReadout()
        for _ in 0..<10 { readout.add(16.667) }
        for k in 0..<10 { readout.add(k == 4 ? 90 : 16.667) }
        let hitched = try! #require(readout.reading)
        #expect(hitched.worst == 90)
        #expect(hitched.average < 21)
        for _ in 0..<10 { readout.add(16.667) }
        #expect(abs(try! #require(readout.reading).worst - 16.667) < 1e-6)
    }

    @Test("The first frame's zero is skipped, and a window hidden for a minute counts as a quarter of a second")
    func edges() {
        var readout = FrameRateReadout(framesPerReading: 1)
        let first = readout.add(0)
        #expect(!first)
        let hidden = readout.add(60_000)
        #expect(hidden)
        #expect(readout.reading?.worst == 250)
    }

    @Test("The average follows a change of pace within a second or so")
    func follows() {
        var readout = FrameRateReadout()
        for _ in 0..<60 { readout.add(16.667) }
        for _ in 0..<60 { readout.add(33.333) }
        #expect(abs(try! #require(readout.reading).average - 33.333) < 1.5)
    }
}

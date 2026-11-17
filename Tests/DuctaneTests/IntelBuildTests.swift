//
//  IntelBuildTests.swift
//  DuctaneTests
//

import Foundation
import Testing

/// **The engine compiles for Intel**, because a universal Release build compiles every architecture even though Metal 4
/// runs only on Apple silicon. Swift has no `Float16` on Intel, and a test run here builds for this Mac's architecture
/// alone, so a `Float16` in the engine passes every test and breaks only a universal build. Half floats are written as
/// bits through `EnvironmentMap.halfBits`, the one place `Float16` is used, behind `#if arch(arm64)`.
@Suite("The engine compiles for Intel")
struct IntelBuildTests {

    @Test("No Float16 in the engine's Swift outside EnvironmentMap.halfBits")
    func noFloat16() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DuctaneTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // the repository root
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "EnvironmentMap.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("Float16") { found.append("\(url.lastPathComponent):\(n + 1)") }
            }
        }
        #expect(found.isEmpty, "Float16 is unavailable on Intel; use EnvironmentMap.halfBits: \(found)")
    }
}

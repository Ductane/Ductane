import Foundation
import Testing
import Metal
@testable import Ductane

@Suite("Frame renderer lifetime")
struct FrameRendererLifetimeTests {
    /// **A `CAMetalLayer` keeps the command queue that last presented to it**, and a queue keeps every residency set added
    /// to it — so a renderer freed while its layer lived on kept everything it had made resident. Here the test keeps the
    /// queue, as the layer would.
    @Test("A freed renderer lets go of what it made resident, though its queue lives on")
    @MainActor
    func freedRendererReleasesItsAllocations() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        var renderer: FrameRenderer? = try FrameRenderer(device: device)
        let queue = try #require(renderer?.commandQueue)
        weak var buffer: (any MTLBuffer)?
        do {
            let made = try #require(device.makeBuffer(length: 4096, options: .storageModeShared))
            renderer?.residencySet.addAllocation(made)
            renderer?.commitResidency()
            buffer = made
        }
        #expect(buffer != nil)
        renderer = nil
        // Metal lets go of a residency set's allocations on its own time, so a busy machine is given a moment.
        for _ in 0..<200 where buffer != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(buffer == nil)
        withExtendedLifetime(queue) {}
    }
}

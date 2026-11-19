//
//  SurfaceHitTests.swift
//  DuctaneTests
//

import Testing
import simd
@testable import Ductane

/// **A surface hit is the same hit, with the face it landed on.** The distance and the thing struck must be what the
/// distance-only tests give, or a mark lands somewhere the shot did not; the normal must be the face entered, facing
/// the shooter, or the mark stands up out of the wall.
struct SurfaceHitTests {

    private let crate = BoundingBox(minimum: SIMD3(-1, 0, -1), maximum: SIMD3(1, 2, 1))

    @Test func aBoxIsEnteredThroughTheFaceTheRayCrossesLast() throws {
        // Straight in from +x: the +x face.
        let side = try #require(crate.hit(ofRayFrom: SIMD3(5, 1, 0), direction: SIMD3(-1, 0, 0)))
        #expect(side.distance == 4)
        #expect(side.normal == SIMD3(1, 0, 0))
        // Down from above, a little to one side: the top.
        let top = try #require(crate.hit(ofRayFrom: SIMD3(0.3, 6, 0.2), direction: SIMD3(0, -1, 0)))
        #expect(abs(top.distance - 4) < 1e-5)
        #expect(top.normal == SIMD3(0, 1, 0))
        // Slanting in from below-left: whichever slab it enters last, which here is −x.
        let slant = try #require(crate.hit(ofRayFrom: SIMD3(-4, 0.5, 0), direction: simd_normalize(SIMD3(1, 0.1, 0))))
        #expect(slant.normal == SIMD3(-1, 0, 0))
    }

    @Test func theDistanceIsAlwaysTheDistanceOnlyAnswer() {
        var seed: UInt64 = 7
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 2 - 1
        }
        for _ in 0..<500 {
            let origin = SIMD3(random(), random(), random()) * 6
            let direction = simd_normalize(SIMD3(random(), random(), random()) + SIMD3(0, 0.001, 0))
            let distance = crate.hitDistance(ofRayFrom: origin, direction: direction, maxDistance: 20)
            let hit = crate.hit(ofRayFrom: origin, direction: direction, maxDistance: 20)
            #expect(hit?.distance == distance)
            if let hit, hit.distance > 0 {
                // The normal faces the shooter, and the point it gives lies on that face.
                #expect(simd_dot(hit.normal, direction) < 0)
                let point = origin + direction * hit.distance
                let axis = hit.normal.x != 0 ? 0 : (hit.normal.y != 0 ? 1 : 2)
                let plane = hit.normal[axis] > 0 ? crate.maximum[axis] : crate.minimum[axis]
                #expect(abs(point[axis] - plane) < 1e-4)
            }
        }
    }

    @Test func aRayFromInsideFacesBackAlongItself() throws {
        let hit = try #require(crate.hit(ofRayFrom: SIMD3(0, 1, 0), direction: SIMD3(0, 0, 2)))
        #expect(hit.distance == 0)
        #expect(hit.normal == SIMD3(0, 0, -1))
    }

    @Test func volumesGiveTheSameThingStruckAsFirstHit() throws {
        let near = Volume(localBounds: crate, transform: float4x4(translation: SIMD3(0, 0, -10)))
        let far = Volume(localBounds: crate, transform: float4x4(translation: SIMD3(0, 0, -20)))
        let volumes = [far, near]
        let start = SIMD3<Float>(0, 1, 0), end = SIMD3<Float>(0, 1, -30)
        let plain = try #require(Volume.firstHit(segmentFrom: start, to: end, against: volumes))
        let surface = try #require(Volume.firstSurfaceHit(segmentFrom: start, to: end, against: volumes))
        #expect(surface.index == plain.index && surface.index == 1)
        #expect(surface.distance == plain.distance)
        #expect(surface.point == SIMD3(0, 1, -9))
        #expect(surface.normal == SIMD3(0, 0, 1))
        #expect(Volume.firstSurfaceHit(segmentFrom: start, to: start, against: volumes) == nil)
    }

    @Test func staticVolumesAgreeWithTestingEveryVolume() throws {
        let volumes = (0..<40).map { i in
            Volume(localBounds: crate, transform: float4x4(translation: SIMD3(Float(i % 8) * 9 - 30, 0, Float(i / 8) * 9 - 20)))
        }
        let grid = StaticVolumes(volumes, cell: 16)
        for angle in stride(from: Float(0), to: 2 * .pi, by: 0.37) {
            let origin = SIMD3<Float>(1.5, 1, 2.5)
            let direction = SIMD3(cos(angle), -0.02, sin(angle))
            let each = Volume.firstSurfaceHit(origin: origin, direction: direction, against: volumes, maxDistance: 80)
            let filed = grid.firstSurfaceHit(origin: origin, direction: direction, maxDistance: 80)
            #expect(each == filed)
            let segment = grid.firstSurfaceHit(segmentFrom: origin, to: origin + direction * 80)
            #expect(segment?.index == each?.index)
        }
    }

    @Test func aTriangleFacesTheShooterWhicheverWayItIsWound() throws {
        // A wall across z = −5, wound one way, and a copy across z = −8 wound the other.
        let wall: [SIMD3<Float>] = [SIMD3(-4, 0, -5), SIMD3(4, 0, -5), SIMD3(0, 6, -5)]
        let rear: [SIMD3<Float>] = [SIMD3(-4, 0, -8), SIMD3(0, 6, -8), SIMD3(4, 0, -8)]
        let mesh = CollisionMesh(triangles: wall + rear)
        let origin = SIMD3<Float>(0, 2, 0), forward = SIMD3<Float>(0, 0, -1)
        let first = try #require(mesh.firstSurfaceHit(from: origin, direction: forward, limit: 20))
        #expect(first.distance == mesh.firstHit(from: origin, direction: forward, limit: 20))
        #expect(abs(first.distance - 5) < 1e-5)
        #expect(simd_distance(first.normal, SIMD3(0, 0, 1)) < 1e-5)
        #expect(first.index == 0)
        // From behind both, the other wall is struck first, and it too faces the shooter.
        let behind = try #require(mesh.firstSurfaceHit(from: SIMD3(0, 2, -12), direction: -forward, limit: 20))
        #expect(behind.index == 1)
        #expect(simd_distance(behind.normal, SIMD3(0, 0, -1)) < 1e-5)
        // Between them, facing the first wall's back: its normal turns round to face this shooter instead.
        let back = try #require(mesh.firstSurfaceHit(from: SIMD3(0, 2, -6.5), direction: forward * -1, limit: 20))
        #expect(back.index == 0)
        #expect(simd_distance(back.normal, SIMD3(0, 0, -1)) < 1e-5)
        #expect(mesh.firstSurfaceHit(from: origin, direction: SIMD3(1, 0, 0), limit: 20) == nil)
    }
}

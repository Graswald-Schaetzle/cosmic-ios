import Foundation
import Testing
import simd
@testable import CosmicCapture

@Suite("Door geometry")
struct CaptureDoorGeometryTests {
    /// A 4 m × 4 m floor at y = -1.4 and a wall at z = -2 facing +Z, both
    /// built from a grid of small faces like a LiDAR mesh.
    private static func roomMesh(classified: Bool = true, wallYaw: Float = 0) -> CaptureLidarMesh {
        var floor = CaptureLidarMesh.Group(name: classified ? "floor" : "unclassified", positions: [], indices: [])
        var wall = CaptureLidarMesh.Group(name: classified ? "wall" : "unclassified", positions: [], indices: [])
        func addQuad(_ group: inout CaptureLidarMesh.Group, _ corners: [SIMD3<Float>]) {
            let base = UInt32(group.positions.count)
            group.positions.append(contentsOf: corners)
            group.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        let step: Float = 0.25
        let rotation = simd_quatf(angle: wallYaw, axis: SIMD3(0, 1, 0))
        for i in 0..<16 {
            for j in 0..<16 {
                let x = -2 + Float(i) * step
                let z = -2 + Float(j) * step
                addQuad(&floor, [
                    SIMD3(x, -1.4, z), SIMD3(x + step, -1.4, z),
                    SIMD3(x + step, -1.4, z + step), SIMD3(x, -1.4, z + step),
                ])
            }
            for k in 0..<10 {
                let x = -2 + Float(i) * step
                let y = -1.4 + Float(k) * step
                // The wall turns about the vertical axis through (0, _, -2).
                let pivot = SIMD3<Float>(0, 0, -2)
                let corners = [
                    SIMD3<Float>(x, y, -2), SIMD3(x + step, y, -2),
                    SIMD3(x + step, y + step, -2), SIMD3(x, y + step, -2),
                ].map { rotation.act($0 - pivot) + pivot }
                addQuad(&wall, corners)
            }
        }
        let groups = classified ? [floor, wall] : [
            CaptureLidarMesh.Group(
                name: "unclassified",
                positions: floor.positions + wall.positions,
                indices: floor.indices + wall.indices.map { $0 + UInt32(floor.positions.count) }
            )
        ]
        return CaptureLidarMesh(groups: groups, anchorCount: 1, hasClassification: classified)
    }

    private func expectClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-3) {
        #expect(simd_distance(a, b) < tolerance, "\(a) is not close to \(b)")
    }

    private func cameraTransform(position: SIMD3<Float>, forward: SIMD3<Float>) -> simd_float4x4 {
        let z = -simd_normalize(forward)
        let x = simd_normalize(simd_cross(SIMD3(0, 1, 0), z))
        let y = simd_cross(z, x)
        return simd_float4x4(
            SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1)
        )
    }

    @Test("Horizontal unit vector drops the vertical part and normalises")
    func horizontalUnit() throws {
        let unit = try #require(CaptureDoorGeometry.horizontalUnit(SIMD3(3, 7, -4)))
        expectClose(unit, SIMD3(0.6, 0, -0.8))
        #expect(unit.y == 0)
        #expect(abs(simd_length(unit) - 1) < 1e-6)
    }

    @Test("A vertical vector has no horizontal direction")
    func horizontalUnitDegenerate() {
        #expect(CaptureDoorGeometry.horizontalUnit(SIMD3(0, -1, 0)) == nil)
        #expect(CaptureDoorGeometry.horizontalUnit(SIMD3(0.01, -1, 0.01)) == nil)
        #expect(CaptureDoorGeometry.horizontalUnit(.zero) == nil)
    }

    @Test("Projecting to the floor keeps x and z")
    func projectToFloor() {
        #expect(CaptureDoorGeometry.projectToFloor(SIMD3(1, 0.9, -2), floorY: -1.4) == SIMD3(1, -1.4, -2))
    }

    @Test("Camera forward is the negative Z axis of the transform")
    func cameraForward() {
        let transform = cameraTransform(position: SIMD3(1, 2, 3), forward: SIMD3(1, 0, 0))
        let camera = CaptureDoorGeometry.cameraPositionAndForward(transform)
        expectClose(camera.position, SIMD3(1, 2, 3))
        expectClose(camera.forward, SIMD3(1, 0, 0))
    }

    @Test("Ray cast returns the closest face")
    func raycastClosest() throws {
        let mesh = Self.roomMesh()
        let hit = try #require(
            CaptureDoorGeometry.raycast(origin: SIMD3(0.1, 0, 0.1), direction: SIMD3(0, 0, -1), mesh: mesh)
        )
        expectClose(hit.point, SIMD3(0.1, 0, -2))
        #expect(abs(hit.distanceM - 2.1) < 1e-3)
        #expect(hit.groupName == "wall")

        let down = try #require(
            CaptureDoorGeometry.raycast(origin: SIMD3(0.1, 0, 0.1), direction: SIMD3(0, -2, 0), mesh: mesh)
        )
        expectClose(down.point, SIMD3(0.1, -1.4, 0.1))
        #expect(down.groupName == "floor")
    }

    @Test("Ray cast misses when nothing is in the way or it is too far")
    func raycastMiss() {
        let mesh = Self.roomMesh()
        #expect(CaptureDoorGeometry.raycast(origin: .zero, direction: SIMD3(0, 1, 0), mesh: mesh) == nil)
        #expect(
            CaptureDoorGeometry.raycast(
                origin: .zero, direction: SIMD3(0, 0, -1), mesh: mesh, maximumDistanceM: 1
            ) == nil
        )
        #expect(CaptureDoorGeometry.raycast(origin: .zero, direction: .zero, mesh: mesh) == nil)
    }

    @Test("Floor height prefers faces classified as floor")
    func floorHeightClassified() throws {
        let estimate = try #require(
            CaptureDoorGeometry.floorHeight(in: Self.roomMesh(), near: SIMD3(0, 0, -1.9), below: -0.3)
        )
        #expect(abs(estimate.y - -1.4) < 1e-4)
        #expect(estimate.source == .meshFloor)
    }

    @Test("An unclassified mesh uses its lowest part")
    func floorHeightUnclassified() throws {
        let estimate = try #require(
            CaptureDoorGeometry.floorHeight(
                in: Self.roomMesh(classified: false), near: SIMD3(0, 0, -1.9), below: -0.3
            )
        )
        #expect(abs(estimate.y - -1.4) < 1e-4)
        #expect(estimate.source == .meshLowest)
    }

    @Test("No floor is found far away from the mesh or above the limit")
    func floorHeightMissing() {
        let mesh = Self.roomMesh()
        #expect(CaptureDoorGeometry.floorHeight(in: mesh, near: SIMD3(20, 0, 20), below: -0.3) == nil)
        #expect(CaptureDoorGeometry.floorHeight(in: mesh, near: SIMD3(0, 0, 0), below: -2) == nil)
    }

    @Test("Exit door sits on the floor under the hit and points through the wall")
    func exitDoorStraight() throws {
        let mesh = Self.roomMesh()
        let camera = SIMD3<Float>(0.3, 0, 0.5)
        let ray = simd_normalize(SIMD3<Float>(0, -0.2, -1))
        let hit = try #require(CaptureDoorGeometry.raycast(origin: camera, direction: ray, mesh: mesh))
        let door = try #require(
            CaptureDoorGeometry.exitDoor(cameraPosition: camera, rayDirection: ray, hitPoint: hit.point, mesh: mesh)
        )
        expectClose(door.position, SIMD3(0.3, -1.4, -2))
        expectClose(door.normal, SIMD3(0, 0, -1))
        #expect(door.floorSource == .meshFloor)
    }

    @Test("Seen at an angle, the normal follows the wall and not the viewing direction")
    func exitDoorOblique() throws {
        let mesh = Self.roomMesh()
        let camera = SIMD3<Float>(-1.2, 0, 0)
        let ray = simd_normalize(SIMD3<Float>(1, 0, -2))
        let hit = try #require(CaptureDoorGeometry.raycast(origin: camera, direction: ray, mesh: mesh))
        let door = try #require(
            CaptureDoorGeometry.exitDoor(cameraPosition: camera, rayDirection: ray, hitPoint: hit.point, mesh: mesh)
        )
        expectClose(door.normal, SIMD3(0, 0, -1))
        #expect(door.normal.y == 0)
    }

    @Test("A turned wall gives a turned normal of unit length")
    func exitDoorTurnedWall() throws {
        let yaw: Float = .pi / 6
        let mesh = Self.roomMesh(wallYaw: yaw)
        let camera = SIMD3<Float>(0, 0, 0)
        let ray = SIMD3<Float>(0, 0, -1)
        let hit = try #require(CaptureDoorGeometry.raycast(origin: camera, direction: ray, mesh: mesh))
        let door = try #require(
            CaptureDoorGeometry.exitDoor(cameraPosition: camera, rayDirection: ray, hitPoint: hit.point, mesh: mesh)
        )
        let expected = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(SIMD3<Float>(0, 0, -1))
        expectClose(door.normal, expected)
        #expect(abs(simd_length(door.normal) - 1) < 1e-5)
    }

    @Test("Without a mesh the door uses the viewing direction and a measured or assumed floor")
    func exitDoorWithoutMesh() throws {
        let camera = SIMD3<Float>(0, 0.2, 0)
        let hit = SIMD3<Float>(3, 0.4, -4)
        let measured = try #require(
            CaptureDoorGeometry.exitDoor(
                cameraPosition: camera, rayDirection: hit - camera, hitPoint: hit, mesh: nil, measuredFloorY: -1.1
            )
        )
        expectClose(measured.position, SIMD3(3, -1.1, -4))
        expectClose(measured.normal, SIMD3(0.6, 0, -0.8))
        #expect(measured.floorSource == .raycast)

        let assumed = try #require(
            CaptureDoorGeometry.exitDoor(cameraPosition: camera, rayDirection: hit - camera, hitPoint: hit, mesh: nil)
        )
        #expect(abs(assumed.position.y - (0.2 - CaptureDoorGeometry.assumedDeviceHeightM)) < 1e-5)
        #expect(assumed.floorSource == .assumedHeight)
    }

    @Test("A measured floor above the device is not believed")
    func implausibleMeasuredFloor() {
        let estimate = CaptureDoorGeometry.floorEstimate(
            mesh: nil, near: .zero, cameraY: 0, measuredFloorY: 0.5
        )
        #expect(estimate.source == .assumedHeight)
    }

    @Test("Entry door is the device position on the floor and the horizontal viewing direction")
    func entryDoor() throws {
        let transform = cameraTransform(
            position: SIMD3(1, 0.1, 1.5), forward: simd_normalize(SIMD3(-1, -0.5, 0))
        )
        let door = try #require(
            CaptureDoorGeometry.entryDoor(worldFromCamera: transform, mesh: Self.roomMesh())
        )
        expectClose(door.position, SIMD3(1, -1.4, 1.5))
        expectClose(door.normal, SIMD3(-1, 0, 0))
        #expect(door.floorSource == .meshFloor)
    }

    @Test("Looking straight down gives no entry door")
    func entryDoorDegenerate() {
        var transform = matrix_identity_float4x4
        // Camera -Z points along world -Y.
        transform.columns.2 = SIMD4(0, 1, 0, 0)
        transform.columns.1 = SIMD4(0, 0, -1, 0)
        #expect(CaptureDoorGeometry.entryDoor(worldFromCamera: transform, mesh: nil) == nil)
    }
}

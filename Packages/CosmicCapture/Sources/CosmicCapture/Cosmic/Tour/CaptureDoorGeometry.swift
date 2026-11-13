import Foundation
import simd

/// Geometry behind the door markings that link two room captures. Pure
/// functions on the capture's ARKit world coordinates (+Y up, metres), so
/// they run in unit tests without a camera.
enum CaptureDoorGeometry {
    /// Used when nothing measured the floor: a phone held in front of the chest.
    static let assumedDeviceHeightM: Float = 1.4
    /// A floor has to be at least this far below the device to be believed.
    static let minimumDeviceHeightM: Float = 0.3
    static let floorSearchRadiusM: Float = 1.5
    static let wallNormalRadiusM: Float = 0.35
    static let maximumRayDistanceM: Float = 10

    struct MeshHit: Equatable, Sendable {
        var point: SIMD3<Float>
        var distanceM: Float
        /// Name of the mesh group that was hit ("wall", "door", "floor", ...).
        var groupName: String
    }

    struct FloorEstimate: Equatable, Sendable {
        var y: Float
        var source: CaptureDoor.FloorSource
    }

    // MARK: - Vectors

    /// The horizontal part of `vector` as a unit vector (`y = 0`), or nil
    /// when the vector is too close to vertical to have a direction.
    static func horizontalUnit(_ vector: SIMD3<Float>, minimumLength: Float = 0.05) -> SIMD3<Float>? {
        let flat = SIMD3<Float>(vector.x, 0, vector.z)
        let length = simd_length(flat)
        guard length.isFinite, length >= minimumLength else { return nil }
        return flat / length
    }

    static func projectToFloor(_ point: SIMD3<Float>, floorY: Float) -> SIMD3<Float> {
        SIMD3(point.x, floorY, point.z)
    }

    /// Position and viewing direction (ARKit cameras look along -Z).
    static func cameraPositionAndForward(_ worldFromCamera: simd_float4x4) -> (position: SIMD3<Float>, forward: SIMD3<Float>) {
        let position = SIMD3<Float>(
            worldFromCamera.columns.3.x, worldFromCamera.columns.3.y, worldFromCamera.columns.3.z
        )
        let forward = -SIMD3<Float>(
            worldFromCamera.columns.2.x, worldFromCamera.columns.2.y, worldFromCamera.columns.2.z
        )
        return (position, forward)
    }

    // MARK: - Mesh queries

    /// Closest intersection of a ray with the LiDAR mesh (both face sides count).
    static func raycast(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        mesh: CaptureLidarMesh,
        maximumDistanceM: Float = maximumRayDistanceM
    ) -> MeshHit? {
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let ray = direction / length
        var best: MeshHit?
        var bestDistance = maximumDistanceM

        for group in mesh.groups {
            let positions = group.positions
            let indices = group.indices
            var cursor = 0
            while cursor + 2 < indices.count {
                let a = positions[Int(indices[cursor])]
                let b = positions[Int(indices[cursor + 1])]
                let c = positions[Int(indices[cursor + 2])]
                cursor += 3

                // Möller–Trumbore.
                let edge1 = b - a
                let edge2 = c - a
                let p = simd_cross(ray, edge2)
                let determinant = simd_dot(edge1, p)
                guard abs(determinant) > 1e-9 else { continue }
                let inverse = 1 / determinant
                let t = origin - a
                let u = simd_dot(t, p) * inverse
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(t, edge1)
                let v = simd_dot(ray, q) * inverse
                guard v >= 0, u + v <= 1 else { continue }
                let distance = simd_dot(edge2, q) * inverse
                guard distance > 0.05, distance < bestDistance else { continue }
                bestDistance = distance
                best = MeshHit(point: origin + ray * distance, distanceM: distance, groupName: group.name)
            }
        }
        return best
    }

    /// Floor height around a point. Prefers faces ARKit classified as floor;
    /// an unclassified mesh falls back to its lowest part. `below` rejects
    /// anything that is not clearly under the device (tables, the ceiling).
    static func floorHeight(
        in mesh: CaptureLidarMesh,
        near point: SIMD3<Float>,
        below maximumY: Float,
        radiusM: Float = floorSearchRadiusM
    ) -> FloorEstimate? {
        let radiusSquared = radiusM * radiusM
        func heights(of group: CaptureLidarMesh.Group) -> [Float] {
            group.positions.compactMap { vertex in
                let dx = vertex.x - point.x
                let dz = vertex.z - point.z
                guard dx * dx + dz * dz <= radiusSquared, vertex.y < maximumY else { return nil }
                return vertex.y
            }
        }

        if let floor = mesh.groups.first(where: { $0.name == "floor" }) {
            let values = heights(of: floor).sorted()
            if values.count >= 3 {
                return FloorEstimate(y: values[values.count / 2], source: .meshFloor)
            }
        }

        let all = mesh.groups.flatMap(heights(of:)).sorted()
        guard all.count >= 20 else { return nil }
        // The 5th percentile ignores the few vertices LiDAR noise puts under the floor.
        return FloorEstimate(y: all[all.count / 20], source: .meshLowest)
    }

    /// Direction a wall (or closed door) faces around a hit point, as a
    /// horizontal unit vector pointing away from the camera. Averages the
    /// upright faces near the hit by area, which smooths LiDAR noise.
    static func wallNormal(
        in mesh: CaptureLidarMesh,
        around point: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        radiusM: Float = wallNormalRadiusM
    ) -> SIMD3<Float>? {
        let radiusSquared = radiusM * radiusM
        var sum = SIMD3<Float>.zero
        for group in mesh.groups {
            let positions = group.positions
            let indices = group.indices
            var cursor = 0
            while cursor + 2 < indices.count {
                let a = positions[Int(indices[cursor])]
                let b = positions[Int(indices[cursor + 1])]
                let c = positions[Int(indices[cursor + 2])]
                cursor += 3
                let centroid = (a + b + c) / 3
                guard simd_length_squared(centroid - point) <= radiusSquared else { continue }
                // Length of the cross product is twice the face area.
                var weighted = simd_cross(b - a, c - a)
                let doubleArea = simd_length(weighted)
                guard doubleArea > 1e-8 else { continue }
                // Skip floors, ceilings and sloped faces.
                guard abs(weighted.y / doubleArea) < 0.35 else { continue }
                if simd_dot(weighted, rayDirection) < 0 { weighted = -weighted }
                sum += weighted
            }
        }
        // Less than about 25 cm² of upright surface is not a wall.
        guard simd_length(sum) > 0.005 else { return nil }
        return horizontalUnit(sum, minimumLength: 1e-4)
    }

    // MARK: - Doors

    /// The door the user points at when leaving a room (`from_door`).
    ///
    /// `hitPoint` is where the ray from the device met the door. The normal
    /// is the direction the door faces, away from the device; when the mesh
    /// around the hit gives no clear answer (or disagrees with the viewing
    /// direction by more than 60°), the horizontal viewing direction is used.
    static func exitDoor(
        cameraPosition: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        hitPoint: SIMD3<Float>,
        mesh: CaptureLidarMesh?,
        measuredFloorY: Float? = nil
    ) -> CaptureDoor? {
        let toDoor = hitPoint - cameraPosition
        guard let viewDirection = horizontalUnit(toDoor) ?? horizontalUnit(rayDirection) else {
            return nil
        }
        var normal = viewDirection
        if let mesh,
           let wall = wallNormal(in: mesh, around: hitPoint, rayDirection: rayDirection),
           simd_dot(wall, viewDirection) >= 0.5 {
            normal = wall
        }
        let floor = floorEstimate(
            mesh: mesh, near: hitPoint, cameraY: cameraPosition.y, measuredFloorY: measuredFloorY
        )
        return CaptureDoor(
            position: projectToFloor(hitPoint, floorY: floor.y),
            normal: normal,
            floorSource: floor.source
        )
    }

    /// The door behind the user when a capture starts (`to_door`): the device
    /// position on the floor and the horizontal viewing direction. Nil when
    /// the device looks straight up or down.
    static func entryDoor(
        worldFromCamera: simd_float4x4,
        mesh: CaptureLidarMesh?,
        measuredFloorY: Float? = nil
    ) -> CaptureDoor? {
        let camera = cameraPositionAndForward(worldFromCamera)
        guard let normal = horizontalUnit(camera.forward) else { return nil }
        let floor = floorEstimate(
            mesh: mesh, near: camera.position, cameraY: camera.position.y, measuredFloorY: measuredFloorY
        )
        return CaptureDoor(
            position: projectToFloor(camera.position, floorY: floor.y),
            normal: normal,
            floorSource: floor.source
        )
    }

    /// Mesh first, then a ray cast result, then the assumed device height.
    static func floorEstimate(
        mesh: CaptureLidarMesh?,
        near point: SIMD3<Float>,
        cameraY: Float,
        measuredFloorY: Float?
    ) -> FloorEstimate {
        let maximumY = cameraY - minimumDeviceHeightM
        if let mesh, let estimate = floorHeight(in: mesh, near: point, below: maximumY) {
            return estimate
        }
        if let measuredFloorY, measuredFloorY < maximumY {
            return FloorEstimate(y: measuredFloorY, source: .raycast)
        }
        return FloorEstimate(y: cameraY - assumedDeviceHeightM, source: .assumedHeight)
    }
}

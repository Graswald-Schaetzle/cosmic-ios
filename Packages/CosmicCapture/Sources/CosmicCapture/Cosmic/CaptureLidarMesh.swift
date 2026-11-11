import ARKit
import Foundation
import simd

/// A Sendable copy of the room's LiDAR mesh in the ARKit world frame
/// (gravity-aligned, +Y up, metres): the same frame the bundle's camera poses
/// are derived from. Faces are grouped by ARKit's mesh classification.
struct CaptureLidarMesh: Sendable, Equatable {
    struct Group: Sendable, Equatable {
        var name: String
        var positions: [SIMD3<Float>]
        var indices: [UInt32]

        var faceCount: Int { indices.count / 3 }
    }

    var groups: [Group]
    var anchorCount: Int
    var hasClassification: Bool

    var vertexCount: Int { groups.reduce(0) { $0 + $1.positions.count } }
    var faceCount: Int { groups.reduce(0) { $0 + $1.faceCount } }
    var isEmpty: Bool { faceCount == 0 }

    static let unclassifiedGroupName = "unclassified"

    static func groupName(for classification: ARMeshClassification) -> String {
        switch classification {
        case .none: unclassifiedGroupName
        case .wall: "wall"
        case .floor: "floor"
        case .ceiling: "ceiling"
        case .table: "table"
        case .seat: "seat"
        case .window: "window"
        case .door: "door"
        @unknown default: unclassifiedGroupName
        }
    }
}

extension CaptureLidarMesh {
    /// Copies the geometry out of the live anchors. Call on the main actor
    /// while the anchors are still current; the result can leave it.
    @MainActor
    init(anchors: [ARMeshAnchor]) {
        var builders: [String: GroupBuilder] = [:]
        var hasClassification = false

        for anchor in anchors {
            let geometry = anchor.geometry
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3, faces.count > 0 else { continue }

            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let transform = anchor.transform
            var world = [SIMD3<Float>](repeating: .zero, count: vertices.count)
            for index in 0..<vertices.count {
                let local = vertexBase
                    .advanced(by: vertices.stride * index)
                    .assumingMemoryBound(to: (Float, Float, Float).self)
                    .pointee
                let point = transform * SIMD4<Float>(local.0, local.1, local.2, 1)
                world[index] = SIMD3<Float>(point.x, point.y, point.z)
            }

            let faceBase = faces.buffer.contents()
            let bytesPerIndex = faces.bytesPerIndex
            let classification = geometry.classification
            let classBase = classification.map { $0.buffer.contents().advanced(by: $0.offset) }
            if classification != nil { hasClassification = true }

            // Local vertex index → index inside each group, for this anchor.
            var remaps: [String: [Int32]] = [:]

            for faceIndex in 0..<faces.count {
                let name: String
                if let classification, let classBase {
                    let raw = classBase
                        .advanced(by: classification.stride * faceIndex)
                        .assumingMemoryBound(to: UInt8.self)
                        .pointee
                    name = CaptureLidarMesh.groupName(
                        for: ARMeshClassification(rawValue: Int(raw)) ?? .none
                    )
                } else {
                    name = CaptureLidarMesh.unclassifiedGroupName
                }

                var builder = builders[name] ?? GroupBuilder()
                var remap = remaps[name] ?? [Int32](repeating: -1, count: world.count)
                var isValid = true
                var corners: [UInt32] = []
                corners.reserveCapacity(3)
                for corner in 0..<3 {
                    let pointer = faceBase.advanced(by: (faceIndex * 3 + corner) * bytesPerIndex)
                    let local: Int = bytesPerIndex == 2
                        ? Int(pointer.assumingMemoryBound(to: UInt16.self).pointee)
                        : Int(pointer.assumingMemoryBound(to: UInt32.self).pointee)
                    guard local < world.count else {
                        isValid = false
                        break
                    }
                    if remap[local] < 0 {
                        remap[local] = Int32(builder.positions.count)
                        builder.positions.append(world[local])
                    }
                    corners.append(UInt32(remap[local]))
                }
                if isValid { builder.indices.append(contentsOf: corners) }
                builders[name] = builder
                remaps[name] = remap
            }
        }

        self.groups = builders
            .filter { !$0.value.indices.isEmpty }
            .map { Group(name: $0.key, positions: $0.value.positions, indices: $0.value.indices) }
            .sorted { $0.name < $1.name }
        self.anchorCount = anchors.count
        self.hasClassification = hasClassification
    }

    private struct GroupBuilder {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
    }
}

/// Serializes a `CaptureLidarMesh` as binary glTF 2.0 (`.glb`): one node and
/// mesh per classification group, positions and 32-bit indices only. glTF is
/// right-handed, +Y up and in metres, like the ARKit world, so no axis
/// conversion is applied.
enum CaptureLidarMeshGLBEncoder {
    enum EncodingError: Error, LocalizedError {
        case emptyMesh

        var errorDescription: String? { "The LiDAR mesh has no faces." }
    }

    static func encode(_ mesh: CaptureLidarMesh) throws -> Data {
        let groups = mesh.groups.filter { !$0.indices.isEmpty && !$0.positions.isEmpty }
        guard !groups.isEmpty else { throw EncodingError.emptyMesh }

        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []

        for group in groups {
            var minimum = group.positions[0]
            var maximum = group.positions[0]
            for position in group.positions {
                minimum = simd_min(minimum, position)
                maximum = simd_max(maximum, position)
            }

            let positionOffset = bin.count
            var floats = [Float](repeating: 0, count: group.positions.count * 3)
            for (index, position) in group.positions.enumerated() {
                floats[index * 3] = position.x
                floats[index * 3 + 1] = position.y
                floats[index * 3 + 2] = position.z
            }
            floats.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append([
                "buffer": 0,
                "byteOffset": positionOffset,
                "byteLength": bin.count - positionOffset,
                "target": 34962,
            ])
            accessors.append([
                "bufferView": bufferViews.count - 1,
                "componentType": 5126,
                "count": group.positions.count,
                "type": "VEC3",
                "min": [Double(minimum.x), Double(minimum.y), Double(minimum.z)],
                "max": [Double(maximum.x), Double(maximum.y), Double(maximum.z)],
            ])
            let positionAccessor = accessors.count - 1

            let indexOffset = bin.count
            group.indices.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append([
                "buffer": 0,
                "byteOffset": indexOffset,
                "byteLength": bin.count - indexOffset,
                "target": 34963,
            ])
            accessors.append([
                "bufferView": bufferViews.count - 1,
                "componentType": 5125,
                "count": group.indices.count,
                "type": "SCALAR",
            ])

            meshes.append([
                "name": group.name,
                "primitives": [[
                    "attributes": ["POSITION": positionAccessor],
                    "indices": accessors.count - 1,
                    "mode": 4,
                ]],
            ])
            nodes.append(["name": group.name, "mesh": meshes.count - 1])
        }

        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Cosmic iOS LiDAR capture"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes,
            "meshes": meshes,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
        ]
        var json = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        // Chunks are 4-byte aligned: JSON pads with spaces, BIN with zeros.
        while json.count % 4 != 0 { json.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0x00) }

        var glb = Data(capacity: 12 + 8 + json.count + 8 + bin.count)
        glb.appendLittleEndian(UInt32(0x4654_6C67)) // "glTF"
        glb.appendLittleEndian(UInt32(2))
        glb.appendLittleEndian(UInt32(12 + 8 + json.count + 8 + bin.count))
        glb.appendLittleEndian(UInt32(json.count))
        glb.appendLittleEndian(UInt32(0x4E4F_534A)) // "JSON"
        glb.append(json)
        glb.appendLittleEndian(UInt32(bin.count))
        glb.appendLittleEndian(UInt32(0x004E_4942)) // "BIN\0"
        glb.append(bin)
        return glb
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

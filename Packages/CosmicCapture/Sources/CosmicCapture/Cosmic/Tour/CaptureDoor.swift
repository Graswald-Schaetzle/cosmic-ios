import Foundation
import simd

/// A door between two rooms, in the ARKit world coordinates of one capture
/// (right-handed, +Y up, metres). Matches the `Door` object of the backend
/// contract (cosmic-backend/docs/multi-room-spaces.md).
public struct CaptureDoor: Codable, Sendable, Equatable {
    /// Where the floor height under the door came from. Local bookkeeping
    /// only; it is not part of the backend contract.
    public enum FloorSource: String, Codable, Sendable {
        /// Median of the LiDAR mesh faces classified as floor near the door.
        case meshFloor = "mesh_floor"
        /// Lowest part of an unclassified LiDAR mesh near the door.
        case meshLowest = "mesh_lowest"
        /// ARKit ray cast straight down from the device.
        case raycast
        /// No measurement: the device is assumed to be held at a fixed height.
        case assumedHeight = "assumed_height"
    }

    /// Centre of the door threshold on the floor.
    public var position: SIMD3<Float>
    /// Horizontal unit vector in the direction of travel, from the room the
    /// user leaves into the room they enter.
    public var normal: SIMD3<Float>
    public var widthM: Float?
    public var floorSource: FloorSource

    public init(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        widthM: Float? = nil,
        floorSource: FloorSource
    ) {
        self.position = position
        self.normal = normal
        self.widthM = widthM
        self.floorSource = floorSource
    }

    enum CodingKeys: String, CodingKey {
        case position
        case normal
        case widthM = "width_m"
        case floorSource = "floor_source"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try Self.vector(container.decode([Double].self, forKey: .position), in: container, key: .position)
        normal = try Self.vector(container.decode([Double].self, forKey: .normal), in: container, key: .normal)
        widthM = try container.decodeIfPresent(Double.self, forKey: .widthM).map(Float.init)
        floorSource = try container.decodeIfPresent(FloorSource.self, forKey: .floorSource) ?? .assumedHeight
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.rounded(position), forKey: .position)
        try container.encode(Self.rounded(normal), forKey: .normal)
        try container.encodeIfPresent(widthM.map { Self.rounded($0) }, forKey: .widthM)
        try container.encode(floorSource, forKey: .floorSource)
    }

    private static func vector(
        _ values: [Double],
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> SIMD3<Float> {
        guard values.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Expected three numbers."
            )
        }
        return SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
    }

    /// Tenths of a millimetre: enough for a door, and it keeps the JSON free
    /// of float-to-double noise such as 1.2000000476837158.
    static func rounded(_ value: Float) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    static func rounded(_ vector: SIMD3<Float>) -> [Double] {
        [rounded(vector.x), rounded(vector.y), rounded(vector.z)]
    }
}

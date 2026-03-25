import Foundation
import RoomPlan

// MARK: - API Payload: Request

struct SpatialScanPayload: Encodable {
    let spaceId: Int
    let floorId: Int?
    let roomId: Int?
    let scanSessionId: String
    let objects: [SpatialObjectPayload]
    let surfaces: [RoomSurfacePayload]

    enum CodingKeys: String, CodingKey {
        case spaceId = "space_id"
        case floorId = "floor_id"
        case roomId = "room_id"
        case scanSessionId = "scan_session_id"
        case objects
        case surfaces
    }
}

struct SpatialObjectPayload: Encodable {
    let category: String
    let posX: Double
    let posY: Double
    let posZ: Double
    let dimWidth: Double
    let dimHeight: Double
    let dimDepth: Double
    let rotX: Double
    let rotY: Double
    let rotZ: Double
    let rotW: Double
    let confidence: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case category
        case posX = "pos_x"
        case posY = "pos_y"
        case posZ = "pos_z"
        case dimWidth = "dim_width"
        case dimHeight = "dim_height"
        case dimDepth = "dim_depth"
        case rotX = "rot_x"
        case rotY = "rot_y"
        case rotZ = "rot_z"
        case rotW = "rot_w"
        case confidence
        case source
    }
}

struct RoomSurfacePayload: Encodable {
    let surfaceType: String
    let posX: Double
    let posY: Double
    let posZ: Double
    let dimWidth: Double
    let dimHeight: Double
    let dimDepth: Double
    let rotX: Double
    let rotY: Double
    let rotZ: Double
    let rotW: Double
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case surfaceType = "surface_type"
        case posX = "pos_x"
        case posY = "pos_y"
        case posZ = "pos_z"
        case dimWidth = "dim_width"
        case dimHeight = "dim_height"
        case dimDepth = "dim_depth"
        case rotX = "rot_x"
        case rotY = "rot_y"
        case rotZ = "rot_z"
        case rotW = "rot_w"
        case confidence
    }
}

// MARK: - API Payload: Response

struct SpatialScanResponse: Decodable {
    struct SpatialScanData: Decodable {
        let scanSessionId: String
        let objectsCount: Int
        let surfacesCount: Int

        enum CodingKeys: String, CodingKey {
            case scanSessionId = "scan_session_id"
            case objectsCount = "objects_count"
            case surfacesCount = "surfaces_count"
        }
    }
    let data: SpatialScanData?
    let error: String?
}

// MARK: - RoomPlan Category → String

extension CapturedRoom.Object.Category {
    var apiString: String {
        switch self {
        case .bathtub:    return "bathtub"
        case .bed:        return "bed"
        case .chair:      return "chair"
        case .dishwasher: return "dishwasher"
        case .fireplace:  return "fireplace"
        case .oven:       return "oven"
        case .refrigerator: return "refrigerator"
        case .sink:       return "sink"
        case .sofa:       return "sofa"
        case .storage:    return "storage"
        case .stove:      return "stove"
        case .table:      return "table"
        case .toilet:     return "toilet"
        case .washerDryer: return "washer_dryer"
        case .television: return "television"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - RoomPlan Confidence → String

extension CapturedRoom.Confidence {
    var apiString: String {
        switch self {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        @unknown default: return "medium"
        }
    }
}

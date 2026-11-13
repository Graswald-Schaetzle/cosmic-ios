import Foundation

struct SpaceListResponse: Decodable {
    let data: [BackendSpace]
}

struct BackendSpace: Decodable, Identifiable, Equatable {
    let spaceId: Int
    let name: String
    let description: String?
    let matterportModelID: String?
    let matterportShowcaseURLString: String?
    let rooms: [BackendSpaceRoom]
    let locations: [BackendSpaceLocation]
    let latestJob: BackendReconstructionJob?

    var id: Int { spaceId }
    var roomCount: Int { rooms.count }
    var locationCount: Int { locations.count }

    enum CodingKeys: String, CodingKey {
        case spaceId = "space_id"
        case name
        case description
        case matterportModelID = "matterport_model_id"
        case matterportShowcaseURLString = "matterport_showcase_url"
        case rooms
        case locations
        case latestJob = "latest_job"
    }
}

struct BackendSpaceRoom: Decodable, Equatable {
    let roomId: Int
    let name: String?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case name
    }
}

struct BackendSpaceLocation: Decodable, Equatable {
    let locationId: Int
    let locationName: String?

    enum CodingKeys: String, CodingKey {
        case locationId = "location_id"
        case locationName = "location_name"
    }
}

struct BackendReconstructionJob: Decodable, Equatable {
    let status: String
    let outputSplatPath: String?
    let outputSpzPath: String?

    enum CodingKeys: String, CodingKey {
        case status
        case outputSplatPath = "output_splat_path"
        case outputSpzPath = "output_spz_path"
    }
}

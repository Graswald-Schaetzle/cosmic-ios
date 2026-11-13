import Foundation

// Request bodies and status mapping for the backend endpoints the tour
// uploads to (cosmic-backend/docs/multi-room-spaces.md and room-captures.md).
// They live in the package so the encoding is covered by unit tests.

/// Body of `POST /room-captures`. Encode dates as ISO 8601.
public struct RoomCaptureRegistrationBody: Encodable, Sendable, Equatable {
    public var spaceID: Int
    public var title: String
    public var frameCount: Int
    /// An existing room to update. Without it `roomName` creates the room.
    public var roomID: Int?
    public var roomName: String?
    /// Reuses the space's floor with this name or creates it.
    public var floorName: String?
    /// When the capture's first frame was taken.
    public var capturedAt: Date?
    /// Equal for captures recorded in one uninterrupted ARKit session.
    public var captureSessionID: String?
    public var hasLidarMesh: Bool

    public init(
        spaceID: Int,
        title: String,
        frameCount: Int,
        roomID: Int? = nil,
        roomName: String? = nil,
        floorName: String? = nil,
        capturedAt: Date? = nil,
        captureSessionID: String? = nil,
        hasLidarMesh: Bool
    ) {
        self.spaceID = spaceID
        self.title = title
        self.frameCount = frameCount
        self.roomID = roomID
        // The backend takes the name only to create a room.
        self.roomName = roomID == nil ? roomName : nil
        self.floorName = floorName
        self.capturedAt = capturedAt
        self.captureSessionID = captureSessionID
        self.hasLidarMesh = hasLidarMesh
    }

    enum CodingKeys: String, CodingKey {
        case spaceID = "space_id"
        case title
        case frameCount = "frame_count"
        case roomID = "room_id"
        case roomName = "room_name"
        case floorName = "floor_name"
        case capturedAt = "captured_at"
        case captureSessionID = "capture_session_id"
        case hasLidarMesh = "has_lidar_mesh"
    }
}

/// The `Door` object of the contract: position on the floor and the
/// horizontal direction of travel, in capture coordinates.
public struct RoomDoorBody: Codable, Sendable, Equatable {
    public var position: [Double]
    public var normal: [Double]
    public var widthM: Double?

    public init(_ door: CaptureDoor) {
        position = CaptureDoor.rounded(door.position)
        normal = CaptureDoor.rounded(door.normal)
        widthM = door.widthM.map { CaptureDoor.rounded($0) }
    }

    enum CodingKeys: String, CodingKey {
        case position
        case normal
        case widthM = "width_m"
    }
}

/// Body of `POST /room-connections` and `PATCH /room-connections/:id`.
/// Fields that are nil are left out, so a PATCH only names what changes.
public struct RoomConnectionBody: Encodable, Sendable, Equatable {
    public var spaceID: Int?
    public var fromRoomID: Int?
    public var fromJobID: Int?
    public var fromDoor: RoomDoorBody?
    public var toRoomID: Int?
    public var toJobID: Int?
    public var toDoor: RoomDoorBody?

    public init(
        spaceID: Int? = nil,
        fromRoomID: Int? = nil,
        fromJobID: Int? = nil,
        fromDoor: RoomDoorBody? = nil,
        toRoomID: Int? = nil,
        toJobID: Int? = nil,
        toDoor: RoomDoorBody? = nil
    ) {
        self.spaceID = spaceID
        self.fromRoomID = fromRoomID
        self.fromJobID = fromJobID
        self.fromDoor = fromDoor
        self.toRoomID = toRoomID
        self.toJobID = toJobID
        self.toDoor = toDoor
    }

    /// The same change as a PATCH of an existing connection, which does not
    /// take the space or the room the link leaves from.
    public var asUpdate: RoomConnectionBody {
        var body = self
        body.spaceID = nil
        body.fromRoomID = nil
        return body
    }

    enum CodingKeys: String, CodingKey {
        case spaceID = "space_id"
        case fromRoomID = "from_room_id"
        case fromJobID = "from_job_id"
        case fromDoor = "from_door"
        case toRoomID = "to_room_id"
        case toJobID = "to_job_id"
        case toDoor = "to_door"
    }
}

/// Price and duration of processing one capture with Echo-3
/// (`GET /room-captures/quote`).
public struct RoomCaptureQuote: Decodable, Sendable, Equatable {
    public var requiredCredits: Int
    public var availableCredits: Int
    public var hasEnough: Bool
    public var estimatedDurationSeconds: Double?

    public init(
        requiredCredits: Int,
        availableCredits: Int,
        hasEnough: Bool,
        estimatedDurationSeconds: Double?
    ) {
        self.requiredCredits = requiredCredits
        self.availableCredits = availableCredits
        self.hasEnough = hasEnough
        self.estimatedDurationSeconds = estimatedDurationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case requiredCredits = "required_credits"
        case availableCredits = "available_credits"
        case hasEnough = "has_enough"
        case estimatedDurationSeconds = "estimated_duration_seconds"
    }

    /// The price of processing several captures: costs add up and are paid
    /// from the same balance. Rooms are processed side by side, so the
    /// duration is that of the slowest one. Nil for an empty list.
    public static func total(of quotes: [RoomCaptureQuote]) -> RoomCaptureQuote? {
        guard !quotes.isEmpty else { return nil }
        let required = quotes.reduce(0) { $0 + $1.requiredCredits }
        let available = quotes.map(\.availableCredits).min() ?? 0
        return RoomCaptureQuote(
            requiredCredits: required,
            availableCredits: available,
            hasEnough: required <= available,
            estimatedDurationSeconds: quotes.compactMap(\.estimatedDurationSeconds).max()
        )
    }
}

/// Where a local capture stands on its way to a finished splat.
public enum RoomCaptureUploadPhase: String, Codable, Sendable {
    /// The ZIP is being built or uploaded from this device.
    case uploading
    /// Echo-3 is working on it.
    case processing
    case completed
    case failed

    /// Maps the job status the backend reports (`reconstruction_jobs.status`).
    /// Everything between upload and the result counts as processing.
    public init(backendStatus: String) {
        switch backendStatus {
        case "completed": self = .completed
        case "failed", "cancelled": self = .failed
        case "uploading": self = .uploading
        default: self = .processing
        }
    }
}

/// What the tour overview shows for a room.
public enum CaptureTourRoomStatus: Sendable, Equatable {
    case onDevice
    case uploading
    case processing
    case inSpace
    case failed
    /// The capture is neither on this device nor known to be uploaded.
    case missing

    public init(hasLocalCapture: Bool, phase: RoomCaptureUploadPhase?) {
        switch phase {
        case .uploading: self = .uploading
        case .processing: self = .processing
        case .completed: self = .inSpace
        case .failed: self = hasLocalCapture ? .failed : .missing
        case nil: self = hasLocalCapture ? .onDevice : .missing
        }
    }

    public var title: String {
        switch self {
        case .onDevice: "On device"
        case .uploading: "Uploading"
        case .processing: "Processing"
        case .inSpace: "In space"
        case .failed: "Failed"
        case .missing: "Capture missing"
        }
    }

    /// Whether the room's capture can be sent (or sent again) now.
    public var canUpload: Bool {
        self == .onDevice || self == .failed
    }
}

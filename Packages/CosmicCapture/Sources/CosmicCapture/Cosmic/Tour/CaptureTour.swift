import Foundation

/// What the backend knows about a door link, kept so a retry or a new
/// capture updates the same connection instead of creating a second one.
public struct CaptureTourConnectionRecord: Codable, Sendable, Equatable {
    public var connectionID: Int
    /// The job whose coordinates the synced `from_door` is in.
    public var fromJobID: Int
    /// The job whose coordinates the synced `to_door` is in, if one was sent.
    public var toJobID: Int?

    public init(connectionID: Int, fromJobID: Int, toJobID: Int?) {
        self.connectionID = connectionID
        self.fromJobID = fromJobID
        self.toJobID = toJobID
    }
}

/// What a finished capture contributes to a tour room.
public struct CaptureTourCaptureInfo: Sendable, Equatable {
    public var captureID: UUID
    /// When the capture started recording, as close as the app gets to the
    /// time of the first frame.
    public var capturedAt: Date
    /// Equal for captures recorded in one uninterrupted ARKit session.
    public var captureSessionID: String
    /// The door behind the user at the start, when they came in through a
    /// marked door.
    public var entryDoor: CaptureDoor?

    public init(captureID: UUID, capturedAt: Date, captureSessionID: String, entryDoor: CaptureDoor?) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.captureSessionID = captureSessionID
        self.entryDoor = entryDoor
    }
}

/// One room of a capture tour. Doors are in the coordinates of the room's
/// current capture; replacing the capture drops them.
public struct CaptureTourRoom: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var floorName: String
    public var captureID: UUID
    public var capturedAt: Date
    public var captureSessionID: String
    /// Recorded at the start of the capture (`to_door` of the link into this room).
    public var entryDoor: CaptureDoor?
    /// Marked at the end of the capture (`from_door` of the link out of this room).
    public var exitDoor: CaptureDoor?
    /// The room the exit door leads to.
    public var nextRoomID: UUID?
    /// The room in the backend, kept so a new capture updates that room.
    public var backendRoomID: Int?
    /// The backend connection for the link out of this room.
    public var exitConnection: CaptureTourConnectionRecord?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case floorName = "floor_name"
        case captureID = "capture_id"
        case capturedAt = "captured_at"
        case captureSessionID = "capture_session_id"
        case entryDoor = "entry_door"
        case exitDoor = "exit_door"
        case nextRoomID = "next_room_id"
        case backendRoomID = "backend_room_id"
        case exitConnection = "exit_connection"
    }
}

/// The rooms of one space in the order they were captured, with the door
/// links between them. Lives on the device until everything is uploaded.
public struct CaptureTour: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let defaultFloorName = "Ground floor"

    public var schemaVersion: Int
    public let spaceID: Int
    public private(set) var rooms: [CaptureTourRoom]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case spaceID = "space_id"
        case rooms
    }

    public init(spaceID: Int) {
        schemaVersion = Self.currentSchemaVersion
        self.spaceID = spaceID
        rooms = []
    }

    // MARK: - Reading

    public func room(id: UUID) -> CaptureTourRoom? {
        rooms.first { $0.id == id }
    }

    public func room(forCapture captureID: UUID) -> CaptureTourRoom? {
        rooms.first { $0.captureID == captureID }
    }

    /// The room whose exit door leads into `roomID`.
    public func previousRoom(of roomID: UUID) -> CaptureTourRoom? {
        rooms.first { $0.nextRoomID == roomID }
    }

    /// Floors in the order they first appear, without duplicates that only
    /// differ in case or surrounding spaces.
    public var floorNames: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for room in rooms where seen.insert(Self.floorKey(room.floorName)).inserted {
            result.append(room.floorName)
        }
        return result
    }

    public struct Floor: Identifiable, Sendable, Equatable {
        public var name: String
        public var rooms: [CaptureTourRoom]
        public var id: String { CaptureTour.floorKey(name) }
    }

    public var floors: [Floor] {
        floorNames.map { name in
            Floor(name: name, rooms: rooms.filter { Self.floorKey($0.floorName) == Self.floorKey(name) })
        }
    }

    /// The floor offered for the next room: the one the user was on last.
    public var suggestedFloorName: String {
        rooms.last?.floorName ?? Self.defaultFloorName
    }

    public var suggestedRoomName: String {
        let taken = Set(rooms.map { $0.name.lowercased() })
        var number = rooms.count + 1
        while taken.contains("room \(number)") { number += 1 }
        return "Room \(number)"
    }

    /// The most recent room whose exit door is marked but leads nowhere yet:
    /// the user marked a door and has not captured the room behind it.
    public var roomWithOpenExit: CaptureTourRoom? {
        rooms.last { $0.exitDoor != nil && $0.nextRoomID == nil }
    }

    // MARK: - Editing

    /// Appends a room for a new capture. With `arrivingFrom`, the exit door
    /// of that room is linked to the new room.
    @discardableResult
    public mutating func addRoom(
        name: String,
        floorName: String,
        capture: CaptureTourCaptureInfo,
        arrivingFrom previousRoomID: UUID? = nil
    ) -> CaptureTourRoom {
        let room = CaptureTourRoom(
            id: UUID(),
            name: Self.cleaned(name, fallback: suggestedRoomName),
            floorName: resolvedFloorName(floorName),
            captureID: capture.captureID,
            capturedAt: capture.capturedAt,
            captureSessionID: capture.captureSessionID,
            entryDoor: previousRoomID == nil ? nil : capture.entryDoor
        )
        if let previousRoomID,
           let index = rooms.firstIndex(where: { $0.id == previousRoomID }),
           rooms[index].exitDoor != nil {
            rooms[index].nextRoomID = room.id
            rooms[index].exitConnection = nil
        }
        rooms.append(room)
        return room
    }

    /// Puts a new capture into an existing room. Name, floor, backend room
    /// and links stay; both doors of the old capture are dropped because
    /// they are in the old capture's coordinates. Returns the capture that
    /// was replaced.
    @discardableResult
    public mutating func replaceCapture(roomID: UUID, with capture: CaptureTourCaptureInfo) -> UUID? {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        let replaced = rooms[index].captureID
        let hasPreviousRoom = previousRoom(of: roomID) != nil
        rooms[index].captureID = capture.captureID
        rooms[index].capturedAt = capture.capturedAt
        rooms[index].captureSessionID = capture.captureSessionID
        rooms[index].entryDoor = hasPreviousRoom ? capture.entryDoor : nil
        rooms[index].exitDoor = nil
        return replaced == capture.captureID ? nil : replaced
    }

    public mutating func setExitDoor(_ door: CaptureDoor?, roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].exitDoor = door
    }

    public mutating func setBackendRoomID(_ backendRoomID: Int, roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].backendRoomID = backendRoomID
    }

    public mutating func setExitConnection(_ record: CaptureTourConnectionRecord?, roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].exitConnection = record
    }

    /// Removes a room and the link into it. Returns the removed room.
    @discardableResult
    public mutating func removeRoom(id: UUID) -> CaptureTourRoom? {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = rooms.remove(at: index)
        for other in rooms.indices where rooms[other].nextRoomID == id {
            rooms[other].nextRoomID = nil
            rooms[other].exitDoor = nil
            rooms[other].exitConnection = nil
        }
        return removed
    }

    // MARK: - Helpers

    static func floorKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func cleaned(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Reuses the spelling of an existing floor so "ground floor" and
    /// "Ground floor" stay one floor.
    func resolvedFloorName(_ name: String) -> String {
        let cleaned = Self.cleaned(name, fallback: suggestedFloorName)
        return floorNames.first { Self.floorKey($0) == Self.floorKey(cleaned) } ?? cleaned
    }
}

// MARK: - Door links

/// One request that brings a door link in the backend up to date.
public struct CaptureTourConnectionAction: Sendable, Equatable {
    /// The tour room the link leaves from.
    public var fromRoomID: UUID
    /// Nil: the connection does not exist yet (`POST /room-connections`).
    public var connectionID: Int?
    public var body: RoomConnectionBody
    /// The job ids the connection holds once the request succeeded.
    public var fromJobID: Int
    public var toJobID: Int?
}

extension CaptureTour {
    /// The requests still needed so every door link exists in the backend
    /// with the doors of the current captures.
    ///
    /// `jobIDs` maps a local capture id to the backend job it was uploaded
    /// as. A link is created once both of its rooms have a backend room and
    /// a job. After a room was captured again, only the side whose door was
    /// measured again is updated: a door of the old capture must never be
    /// attached to the new job.
    public func connectionActions(jobIDs: [UUID: Int]) -> [CaptureTourConnectionAction] {
        var actions: [CaptureTourConnectionAction] = []
        for from in rooms {
            guard let nextRoomID = from.nextRoomID,
                  let to = room(id: nextRoomID),
                  let fromBackendRoomID = from.backendRoomID,
                  let toBackendRoomID = to.backendRoomID
            else { continue }
            let fromJobID = jobIDs[from.captureID]
            let toJobID = jobIDs[to.captureID]

            guard let record = from.exitConnection else {
                guard let fromJobID, let toJobID, let exitDoor = from.exitDoor else { continue }
                actions.append(
                    CaptureTourConnectionAction(
                        fromRoomID: from.id,
                        connectionID: nil,
                        body: RoomConnectionBody(
                            spaceID: spaceID,
                            fromRoomID: fromBackendRoomID,
                            fromJobID: fromJobID,
                            fromDoor: RoomDoorBody(exitDoor),
                            toRoomID: toBackendRoomID,
                            toJobID: toJobID,
                            toDoor: to.entryDoor.map(RoomDoorBody.init)
                        ),
                        fromJobID: fromJobID,
                        toJobID: toJobID
                    )
                )
                continue
            }

            var body = RoomConnectionBody()
            var updated = record
            if let fromJobID, fromJobID != record.fromJobID, let exitDoor = from.exitDoor {
                body.fromJobID = fromJobID
                body.fromDoor = RoomDoorBody(exitDoor)
                updated.fromJobID = fromJobID
            }
            if let toJobID, toJobID != record.toJobID, let entryDoor = to.entryDoor {
                body.toRoomID = toBackendRoomID
                body.toJobID = toJobID
                body.toDoor = RoomDoorBody(entryDoor)
                updated.toJobID = toJobID
            }
            guard updated != record else { continue }
            actions.append(
                CaptureTourConnectionAction(
                    fromRoomID: from.id,
                    connectionID: record.connectionID,
                    body: body,
                    fromJobID: updated.fromJobID,
                    toJobID: updated.toJobID
                )
            )
        }
        return actions
    }
}

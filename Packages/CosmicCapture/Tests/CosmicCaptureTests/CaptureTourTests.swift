import Foundation
import Testing
import simd
@testable import CosmicCapture

private func door(_ x: Float, normal: SIMD3<Float> = SIMD3(0, 0, -1)) -> CaptureDoor {
    CaptureDoor(position: SIMD3(x, -1.4, -2), normal: normal, floorSource: .meshFloor)
}

private func info(
    _ captureID: UUID = UUID(),
    session: String = "s1",
    entry: CaptureDoor? = nil,
    at seconds: TimeInterval = 0
) -> CaptureTourCaptureInfo {
    CaptureTourCaptureInfo(
        captureID: captureID,
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
        captureSessionID: session,
        entryDoor: entry
    )
}

private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Capture tour")
struct CaptureTourTests {
    /// Hall → Kitchen through a marked door, both on the ground floor.
    private func linkedTour() -> (tour: CaptureTour, hall: CaptureTourRoom, kitchen: CaptureTourRoom) {
        var tour = CaptureTour(spaceID: 12)
        let hall = tour.addRoom(name: "Hall", floorName: "Ground floor", capture: info())
        tour.setExitDoor(door(1), roomID: hall.id)
        let kitchen = tour.addRoom(
            name: "Kitchen", floorName: "ground floor ", capture: info(entry: door(0)), arrivingFrom: hall.id
        )
        return (tour, tour.room(id: hall.id)!, tour.room(id: kitchen.id)!)
    }

    @Test("Rooms keep their capture order and are grouped by floor")
    func floors() {
        var tour = CaptureTour(spaceID: 1)
        tour.addRoom(name: "Hall", floorName: "Ground floor", capture: info())
        tour.addRoom(name: "Bedroom", floorName: "Upper floor", capture: info())
        tour.addRoom(name: "Kitchen", floorName: " ground FLOOR", capture: info())

        #expect(tour.rooms.map(\.name) == ["Hall", "Bedroom", "Kitchen"])
        #expect(tour.floorNames == ["Ground floor", "Upper floor"])
        #expect(tour.floors.map { $0.rooms.map(\.name) } == [["Hall", "Kitchen"], ["Bedroom"]])
        // The spelling of the first use wins.
        #expect(tour.rooms[2].floorName == "Ground floor")
        #expect(tour.suggestedFloorName == "Ground floor")
    }

    @Test("Empty names fall back to suggestions")
    func suggestions() {
        var tour = CaptureTour(spaceID: 1)
        #expect(tour.suggestedRoomName == "Room 1")
        #expect(tour.suggestedFloorName == CaptureTour.defaultFloorName)
        let room = tour.addRoom(name: "  ", floorName: "", capture: info())
        #expect(room.name == "Room 1")
        #expect(room.floorName == CaptureTour.defaultFloorName)
        tour.addRoom(name: "Room 3", floorName: "", capture: info())
        #expect(tour.suggestedRoomName == "Room 4")
    }

    @Test("Arriving through a marked door links the rooms and keeps the entry door")
    func linking() {
        let (tour, hall, kitchen) = linkedTour()
        #expect(hall.nextRoomID == kitchen.id)
        #expect(kitchen.entryDoor == door(0))
        #expect(tour.previousRoom(of: kitchen.id)?.id == hall.id)
        #expect(tour.roomWithOpenExit == nil)
    }

    @Test("Without a marked door there is no link and no entry door")
    func noLinkWithoutDoor() {
        var tour = CaptureTour(spaceID: 1)
        let hall = tour.addRoom(name: "Hall", floorName: "G", capture: info())
        let unlinked = tour.addRoom(name: "A", floorName: "G", capture: info(entry: door(0)))
        #expect(unlinked.entryDoor == nil)
        // The previous room has no exit door, so nothing can be linked.
        let other = tour.addRoom(name: "B", floorName: "G", capture: info(entry: door(0)), arrivingFrom: hall.id)
        #expect(tour.room(id: hall.id)?.nextRoomID == nil)
        #expect(tour.previousRoom(of: other.id) == nil)
    }

    @Test("A marked door without a room behind it stays open")
    func openExit() {
        var tour = CaptureTour(spaceID: 1)
        let hall = tour.addRoom(name: "Hall", floorName: "G", capture: info())
        #expect(tour.roomWithOpenExit == nil)
        tour.setExitDoor(door(1), roomID: hall.id)
        #expect(tour.roomWithOpenExit?.id == hall.id)
    }

    @Test("Re-capture keeps name, floor, backend room and links, and drops both doors")
    func recapture() {
        var (tour, hall, kitchen) = linkedTour()
        tour.setBackendRoomID(41, roomID: hall.id)
        tour.setBackendRoomID(42, roomID: kitchen.id)
        tour.setExitDoor(door(5), roomID: kitchen.id)
        let newCapture = UUID()

        let replaced = tour.replaceCapture(roomID: kitchen.id, with: info(newCapture, session: "s2", entry: door(9)))
        kitchen = tour.room(id: kitchen.id)!

        #expect(replaced != nil && replaced != newCapture)
        #expect(tour.rooms.count == 2)
        #expect(kitchen.name == "Kitchen")
        #expect(kitchen.floorName == "Ground floor")
        #expect(kitchen.backendRoomID == 42)
        #expect(kitchen.captureID == newCapture)
        #expect(kitchen.captureSessionID == "s2")
        #expect(kitchen.entryDoor == door(9))
        #expect(kitchen.exitDoor == nil)
        #expect(tour.room(id: hall.id)?.nextRoomID == kitchen.id)

        // A room nothing leads into has no entry door, whatever the capture says.
        tour.replaceCapture(roomID: hall.id, with: info(entry: door(3)))
        #expect(tour.room(id: hall.id)?.entryDoor == nil)
        #expect(tour.room(id: hall.id)?.nextRoomID == kitchen.id)
    }

    @Test("Removing a room removes the link into it")
    func removeRoom() {
        var (tour, hall, kitchen) = linkedTour()
        tour.setExitConnection(.init(connectionID: 5, fromJobID: 1, toJobID: 2), roomID: hall.id)
        #expect(tour.removeRoom(id: kitchen.id)?.id == kitchen.id)
        hall = tour.room(id: hall.id)!
        #expect(hall.nextRoomID == nil)
        #expect(hall.exitDoor == nil)
        #expect(hall.exitConnection == nil)
        #expect(tour.removeRoom(id: kitchen.id) == nil)
    }

    @Test("Tour survives a JSON round trip")
    func codable() throws {
        var (tour, hall, _) = linkedTour()
        tour.setBackendRoomID(41, roomID: hall.id)
        tour.setExitConnection(.init(connectionID: 5, fromJobID: 77, toJobID: nil), roomID: hall.id)
        let data = try CosmicTourStore.makeEncoder().encode(tour)
        let decoded = try CosmicTourStore.makeDecoder().decode(CaptureTour.self, from: data)
        #expect(decoded == tour)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"capture_session_id\""))
        #expect(text.contains("\"exit_door\""))
    }

    // MARK: - Door links in the backend

    @Test("A connection is created once both rooms are uploaded")
    func connectionCreate() throws {
        var (tour, hall, kitchen) = linkedTour()
        #expect(tour.connectionActions(jobIDs: [hall.captureID: 77, kitchen.captureID: 78]).isEmpty)

        tour.setBackendRoomID(41, roomID: hall.id)
        #expect(tour.connectionActions(jobIDs: [hall.captureID: 77, kitchen.captureID: 78]).isEmpty)
        tour.setBackendRoomID(42, roomID: kitchen.id)
        #expect(tour.connectionActions(jobIDs: [hall.captureID: 77]).isEmpty)

        let actions = tour.connectionActions(jobIDs: [hall.captureID: 77, kitchen.captureID: 78])
        let action = try #require(actions.first)
        #expect(actions.count == 1)
        #expect(action.fromRoomID == hall.id)
        #expect(action.connectionID == nil)
        #expect(action.fromJobID == 77)
        #expect(action.toJobID == 78)
        #expect(
            action.body == RoomConnectionBody(
                spaceID: 12, fromRoomID: 41, fromJobID: 77, fromDoor: RoomDoorBody(door(1)),
                toRoomID: 42, toJobID: 78, toDoor: RoomDoorBody(door(0))
            )
        )
    }

    @Test("A synced connection needs nothing more")
    func connectionIdempotent() {
        var (tour, hall, kitchen) = linkedTour()
        tour.setBackendRoomID(41, roomID: hall.id)
        tour.setBackendRoomID(42, roomID: kitchen.id)
        tour.setExitConnection(.init(connectionID: 5, fromJobID: 77, toJobID: 78), roomID: hall.id)
        #expect(tour.connectionActions(jobIDs: [hall.captureID: 77, kitchen.captureID: 78]).isEmpty)
    }

    @Test("After re-capturing the entered room, only its side is patched")
    func connectionUpdateToSide() throws {
        var (tour, hall, kitchen) = linkedTour()
        tour.setBackendRoomID(41, roomID: hall.id)
        tour.setBackendRoomID(42, roomID: kitchen.id)
        tour.setExitConnection(.init(connectionID: 5, fromJobID: 77, toJobID: 78), roomID: hall.id)
        let newCapture = UUID()
        tour.replaceCapture(roomID: kitchen.id, with: info(newCapture, entry: door(9)))

        let action = try #require(
            tour.connectionActions(jobIDs: [hall.captureID: 77, newCapture: 90]).first
        )
        #expect(action.connectionID == 5)
        #expect(action.body == RoomConnectionBody(toRoomID: 42, toJobID: 90, toDoor: RoomDoorBody(door(9))))
        #expect(action.fromJobID == 77)
        #expect(action.toJobID == 90)
    }

    @Test("A re-capture without a new door marking never moves an old door to the new job")
    func connectionNoStaleDoor() {
        var (tour, hall, kitchen) = linkedTour()
        tour.setBackendRoomID(41, roomID: hall.id)
        tour.setBackendRoomID(42, roomID: kitchen.id)
        tour.setExitConnection(.init(connectionID: 5, fromJobID: 77, toJobID: 78), roomID: hall.id)

        // Kitchen again, not started behind the door.
        let newKitchen = UUID()
        tour.replaceCapture(roomID: kitchen.id, with: info(newKitchen, entry: nil))
        #expect(tour.connectionActions(jobIDs: [hall.captureID: 77, newKitchen: 90]).isEmpty)

        // Hall again, exit door not marked again.
        let newHall = UUID()
        tour.replaceCapture(roomID: hall.id, with: info(newHall))
        #expect(tour.connectionActions(jobIDs: [newHall: 91, newKitchen: 90]).isEmpty)

        // Marking it again patches the from side only.
        tour.setExitDoor(door(7), roomID: hall.id)
        let actions = tour.connectionActions(jobIDs: [newHall: 91, newKitchen: 90])
        #expect(actions.count == 1)
        #expect(actions.first?.body == RoomConnectionBody(fromJobID: 91, fromDoor: RoomDoorBody(door(7))))
        #expect(actions.first?.toJobID == 78)
    }

    @Test("A link without an entry door is created without to_door")
    func connectionWithoutEntryDoor() throws {
        var tour = CaptureTour(spaceID: 3)
        let hall = tour.addRoom(name: "Hall", floorName: "G", capture: info())
        tour.setExitDoor(door(1), roomID: hall.id)
        let next = tour.addRoom(name: "Bath", floorName: "G", capture: info(entry: nil), arrivingFrom: hall.id)
        tour.setBackendRoomID(1, roomID: hall.id)
        tour.setBackendRoomID(2, roomID: next.id)
        let action = try #require(
            tour.connectionActions(jobIDs: [hall.captureID: 10, next.captureID: 11]).first
        )
        #expect(action.body.toRoomID == 2)
        #expect(action.body.toJobID == 11)
        #expect(action.body.toDoor == nil)
    }
}

@Suite("Tour store")
@MainActor
struct CosmicTourStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tour-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Tours are written per space and read back by a new store")
    func persistence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureID = UUID()

        let store = CosmicTourStore(directory: directory)
        #expect(store.tour(for: 7).rooms.isEmpty)
        store.update(spaceID: 7) { tour in
            let room = tour.addRoom(name: "Hall", floorName: "Ground floor", capture: info(captureID))
            tour.setExitDoor(door(1), roomID: room.id)
        }
        store.update(spaceID: 8) { $0.addRoom(name: "Attic", floorName: "Top", capture: info()) }
        #expect(store.lastSaveError == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("space-7.json").path))

        let reopened = CosmicTourStore(directory: directory)
        #expect(reopened.tour(for: 7) == store.tour(for: 7))
        #expect(reopened.tour(for: 8).rooms.map(\.name) == ["Attic"])
        #expect(reopened.room(forCapture: captureID)?.spaceID == 7)
        #expect(reopened.room(forCapture: captureID)?.room.exitDoor == door(1))
        #expect(reopened.room(forCapture: UUID()) == nil)
    }

    @Test("A damaged file does not break the other tours")
    func damagedFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CosmicTourStore(directory: directory)
        store.update(spaceID: 1) { $0.addRoom(name: "Hall", floorName: "G", capture: info()) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("space-2.json"))

        let reopened = CosmicTourStore(directory: directory)
        #expect(reopened.tours.keys.sorted() == [1])
    }
}

@Suite("Room capture API bodies")
struct RoomCaptureAPITests {
    @Test("Registration of a new room sends name, floor, time and session")
    func registrationNewRoom() throws {
        let body = RoomCaptureRegistrationBody(
            spaceID: 12,
            title: "Kitchen",
            frameCount: 640,
            roomName: "Kitchen",
            floorName: "Ground floor",
            capturedAt: Date(timeIntervalSince1970: 1_794_564_131),
            captureSessionID: "A1B2",
            hasLidarMesh: true
        )
        let json = try jsonObject(body)
        #expect(json["space_id"] as? Int == 12)
        #expect(json["title"] as? String == "Kitchen")
        #expect(json["frame_count"] as? Int == 640)
        #expect(json["room_name"] as? String == "Kitchen")
        #expect(json["floor_name"] as? String == "Ground floor")
        #expect(json["captured_at"] as? String == "2026-11-13T10:02:11Z")
        #expect(json["capture_session_id"] as? String == "A1B2")
        #expect(json["has_lidar_mesh"] as? Bool == true)
        #expect(json["room_id"] == nil)
    }

    @Test("Registration for an existing room sends room_id and no room_name")
    func registrationExistingRoom() throws {
        let body = RoomCaptureRegistrationBody(
            spaceID: 12, title: "Kitchen", frameCount: 10, roomID: 42, roomName: "Kitchen", hasLidarMesh: false
        )
        let json = try jsonObject(body)
        #expect(json["room_id"] as? Int == 42)
        #expect(json["room_name"] == nil)
        #expect(json["floor_name"] == nil)
        #expect(json["captured_at"] == nil)
        #expect(json["capture_session_id"] == nil)
    }

    @Test("Door body matches the contract: position, horizontal normal, no local fields")
    func doorBody() throws {
        let captureDoor = CaptureDoor(
            position: SIMD3(1.2, -1.4, -3), normal: SIMD3(0, 0, -1), floorSource: .meshFloor
        )
        let json = try jsonObject(RoomDoorBody(captureDoor))
        #expect(json["position"] as? [Double] == [1.2, -1.4, -3])
        #expect(json["normal"] as? [Double] == [0, 0, -1])
        #expect(json.keys.sorted() == ["normal", "position"])

        var wide = captureDoor
        wide.widthM = 0.9
        #expect(try jsonObject(RoomDoorBody(wide))["width_m"] as? Double == 0.9)
    }

    @Test("Connection body uses the contract's keys and leaves out what is nil")
    func connectionBody() throws {
        let full = RoomConnectionBody(
            spaceID: 12, fromRoomID: 41, fromJobID: 77, fromDoor: RoomDoorBody(door(1)),
            toRoomID: 42, toJobID: 78, toDoor: RoomDoorBody(door(0, normal: SIMD3(1, 0, 0)))
        )
        let json = try jsonObject(full)
        #expect(
            json.keys.sorted() == [
                "from_door", "from_job_id", "from_room_id", "space_id", "to_door", "to_job_id", "to_room_id",
            ]
        )
        #expect((json["to_door"] as? [String: Any])?["normal"] as? [Double] == [1, 0, 0])

        let patch = try jsonObject(full.asUpdate)
        #expect(patch["space_id"] == nil)
        #expect(patch["from_room_id"] == nil)
        #expect(patch["from_job_id"] as? Int == 77)

        let partial = try jsonObject(RoomConnectionBody(toRoomID: 42, toJobID: 90))
        #expect(partial.keys.sorted() == ["to_job_id", "to_room_id"])
    }

    @Test("A stored door keeps its floor source and tolerates files without one")
    func captureDoorCodable() throws {
        let original = CaptureDoor(
            position: SIMD3(0.12345, -1.4, 2), normal: SIMD3(0.6, 0, -0.8), widthM: 0.9, floorSource: .raycast
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureDoor.self, from: data)
        #expect(simd_distance(decoded.position, original.position) < 1e-4)
        #expect(decoded.floorSource == .raycast)
        #expect(decoded.widthM == 0.9)

        let contract = Data(#"{"position":[1,2,3],"normal":[0,0,-1]}"#.utf8)
        #expect(try JSONDecoder().decode(CaptureDoor.self, from: contract).floorSource == .assumedHeight)
        let broken = Data(#"{"position":[1,2],"normal":[0,0,-1]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CaptureDoor.self, from: broken) }
    }

    @Test("Backend job status maps to an upload phase")
    func phaseMapping() {
        #expect(RoomCaptureUploadPhase(backendStatus: "completed") == .completed)
        #expect(RoomCaptureUploadPhase(backendStatus: "failed") == .failed)
        #expect(RoomCaptureUploadPhase(backendStatus: "cancelled") == .failed)
        #expect(RoomCaptureUploadPhase(backendStatus: "uploading") == .uploading)
        for status in ["queued", "training_splat", "exporting", "something_new"] {
            #expect(RoomCaptureUploadPhase(backendStatus: status) == .processing)
        }
    }

    @Test("Room status follows the upload phase")
    func roomStatus() {
        #expect(CaptureTourRoomStatus(hasLocalCapture: true, phase: nil) == .onDevice)
        #expect(CaptureTourRoomStatus(hasLocalCapture: true, phase: .uploading) == .uploading)
        #expect(CaptureTourRoomStatus(hasLocalCapture: true, phase: .processing) == .processing)
        #expect(CaptureTourRoomStatus(hasLocalCapture: true, phase: .completed) == .inSpace)
        #expect(CaptureTourRoomStatus(hasLocalCapture: true, phase: .failed) == .failed)
        #expect(CaptureTourRoomStatus(hasLocalCapture: false, phase: .completed) == .inSpace)
        #expect(CaptureTourRoomStatus(hasLocalCapture: false, phase: nil) == .missing)
        #expect(CaptureTourRoomStatus(hasLocalCapture: false, phase: .failed) == .missing)
        #expect(CaptureTourRoomStatus.onDevice.canUpload)
        #expect(CaptureTourRoomStatus.failed.canUpload)
        #expect(!CaptureTourRoomStatus.processing.canUpload)
        #expect(!CaptureTourRoomStatus.missing.canUpload)
    }

    @Test("Quotes of several rooms add up against one balance")
    func quoteTotal() throws {
        let quotes = [
            RoomCaptureQuote(requiredCredits: 1500, availableCredits: 4000, hasEnough: true, estimatedDurationSeconds: 1800),
            RoomCaptureQuote(requiredCredits: 1300, availableCredits: 4000, hasEnough: true, estimatedDurationSeconds: 2400),
            RoomCaptureQuote(requiredCredits: 1400, availableCredits: 4000, hasEnough: true, estimatedDurationSeconds: nil),
        ]
        let total = try #require(RoomCaptureQuote.total(of: quotes))
        #expect(total.requiredCredits == 4200)
        #expect(total.availableCredits == 4000)
        #expect(!total.hasEnough)
        #expect(total.estimatedDurationSeconds == 2400)
        #expect(RoomCaptureQuote.total(of: Array(quotes.prefix(2)))?.hasEnough == true)
        #expect(RoomCaptureQuote.total(of: []) == nil)
    }

    @Test("Quote decodes the backend's keys")
    func quoteDecoding() throws {
        let data = Data(
            #"{"required_credits":1540,"available_credits":7906,"has_enough":true,"estimated_duration_seconds":1860}"#.utf8
        )
        let quote = try JSONDecoder().decode(RoomCaptureQuote.self, from: data)
        #expect(quote.requiredCredits == 1540)
        #expect(quote.hasEnough)
    }
}

@Suite("Capture session continuity")
struct CaptureSessionContinuityTests {
    private func makeContinuity() -> CaptureSessionContinuity {
        let counter = Counter()
        return CaptureSessionContinuity(makeID: { "session-\(counter.next())" })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    @Test("Captures in an intact session share one id")
    func shared() {
        var continuity = makeContinuity()
        continuity.observe(.initializing, at: 0)
        continuity.observe(.normal, at: 1)
        let first = continuity.sessionIDForCaptureStart()
        continuity.observe(.normal, at: 60)
        continuity.observe(.degraded, at: 61)
        continuity.observe(.normal, at: 62)
        #expect(continuity.sessionIDForCaptureStart() == first)
    }

    @Test("Losing the world starts a new id", arguments: [
        CaptureSessionContinuity.Tracking.relocalizing, .notAvailable, .initializing,
    ])
    func broken(by tracking: CaptureSessionContinuity.Tracking) {
        var continuity = makeContinuity()
        continuity.observe(.normal, at: 1)
        let first = continuity.sessionIDForCaptureStart()
        continuity.observe(tracking, at: 2)
        continuity.observe(.normal, at: 3)
        let second = continuity.sessionIDForCaptureStart()
        #expect(second != first)
        #expect(continuity.sessionIDForCaptureStart() == second)
    }

    @Test("Short degraded tracking is tolerated, long is not")
    func degraded() {
        var continuity = makeContinuity()
        continuity.observe(.normal, at: 0)
        let first = continuity.sessionIDForCaptureStart()
        continuity.observe(.degraded, at: 10)
        continuity.observe(.degraded, at: 12.9)
        continuity.observe(.normal, at: 13)
        // A second short stretch starts counting again.
        continuity.observe(.degraded, at: 14)
        continuity.observe(.degraded, at: 16.5)
        #expect(continuity.sessionIDForCaptureStart() == first)

        continuity.observe(.degraded, at: 20)
        continuity.observe(.degraded, at: 23.5)
        continuity.observe(.normal, at: 24)
        #expect(continuity.sessionIDForCaptureStart() != first)
    }

    @Test("A pause or leaving the foreground starts a new id")
    func markedBroken() {
        var continuity = makeContinuity()
        let first = continuity.sessionIDForCaptureStart()
        continuity.markBroken()
        #expect(continuity.isBroken)
        #expect(continuity.sessionIDForCaptureStart() != first)
        #expect(!continuity.isBroken)
    }
}

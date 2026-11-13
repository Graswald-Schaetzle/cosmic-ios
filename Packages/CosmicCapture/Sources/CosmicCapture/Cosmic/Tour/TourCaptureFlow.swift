import ARKit
import Foundation
import Observation
import simd

/// How a tour capture session begins.
public enum CosmicTourCaptureStart: Sendable, Equatable {
    /// Capture a room that is not in the tour yet.
    case nextRoom
    /// Capture an existing room again. Name, floor and the room in the
    /// backend stay; the room's capture is replaced.
    case recapture(roomID: UUID)
}

/// Drives the room-by-room capture of a tour on top of one
/// `CaptureFlowModel`, and so on one AR session: room card → capture →
/// "Where does it continue?" → door marking → next room card.
///
/// The AR session keeps running between rooms without saving frames. While
/// it stays intact (see `CaptureSessionContinuity`) the captures share a
/// `capture_session_id`; otherwise the door pair is the only link.
@MainActor
@Observable
final class TourCaptureFlow {
    enum DoorStage: Equatable {
        /// "Where does it continue?"
        case choose
        /// The camera is up and the user aims at the door.
        case aim
        /// A door was measured and waits for confirmation.
        case marked(CaptureDoor, distanceM: Float)
    }

    let model: CaptureFlowModel
    let spaceID: Int

    // Room card
    var roomName = ""
    var floorName = ""
    /// The room whose marked door leads into the room about to be captured.
    private(set) var arrivalRoom: CaptureTourRoom?
    /// The user confirms that they really came through that door.
    var cameThroughMarkedDoor = false
    private(set) var recaptureRoomID: UUID?

    // After the save
    private(set) var savedRoom: CaptureTourRoom?
    private(set) var doorStage: DoorStage = .choose
    private(set) var doorError: String?
    private(set) var isMeasuringDoor = false
    /// How many rooms this session added or replaced.
    private(set) var savedRoomCount = 0

    @ObservationIgnored private let tourStore: CosmicTourStore
    @ObservationIgnored private let library: CaptureLibrary
    @ObservationIgnored private let onRoomSaved: (CosmicCaptureSummary) -> Void
    @ObservationIgnored private let onCaptureReplaced: (UUID) -> Void
    @ObservationIgnored private var continuity = CaptureSessionContinuity()
    @ObservationIgnored private var startPose: simd_float4x4?
    @ObservationIgnored private var startFloorY: Float?
    @ObservationIgnored private var startSessionID: String?
    @ObservationIgnored private var handledCaptureID: UUID?

    init(
        captureStore: CosmicCaptureStore,
        tourStore: CosmicTourStore,
        spaceID: Int,
        start: CosmicTourCaptureStart,
        onRoomSaved: @escaping (CosmicCaptureSummary) -> Void,
        onCaptureReplaced: @escaping (UUID) -> Void
    ) {
        self.tourStore = tourStore
        self.spaceID = spaceID
        self.onRoomSaved = onRoomSaved
        self.onCaptureReplaced = onCaptureReplaced
        library = captureStore.library
        model = CaptureFlowModel(
            library: captureStore.library,
            experience: CaptureGuidanceSetup.makeExperience()
        )
        model.coordinator.keepsSessionRunningAfterFinish = true
        model.coordinator.onTrackingStateObserved = { [weak self] state, timestamp in
            self?.continuity.observe(Self.tracking(state), at: timestamp)
        }

        switch start {
        case .nextRoom:
            configureCard(arrivingFrom: tour.roomWithOpenExit)
        case .recapture(let roomID):
            configureCard(recapturing: roomID)
        }
    }

    var tour: CaptureTour { tourStore.tour(for: spaceID) }
    var isRecapture: Bool { recaptureRoomID != nil }
    var existingFloorNames: [String] { tour.floorNames }

    /// For a re-capture: the room the old exit door led to.
    var linkedNextRoom: CaptureTourRoom? {
        guard isRecapture, let nextID = savedRoom?.nextRoomID else { return nil }
        return tour.room(id: nextID)
    }

    var canStart: Bool {
        model.canStart
            && !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !floorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isTrackingReady: Bool { model.isTrackingReady }

    // MARK: - Room card

    private func configureCard(arrivingFrom room: CaptureTourRoom?) {
        recaptureRoomID = nil
        roomName = tour.suggestedRoomName
        floorName = tour.suggestedFloorName
        arrivalRoom = room
        cameThroughMarkedDoor = room != nil
        syncCaptureName()
    }

    private func configureCard(recapturing roomID: UUID) {
        guard let room = tour.room(id: roomID) else {
            configureCard(arrivingFrom: nil)
            return
        }
        recaptureRoomID = roomID
        roomName = room.name
        floorName = room.floorName
        arrivalRoom = tour.previousRoom(of: roomID)
        cameThroughMarkedDoor = arrivalRoom != nil
        syncCaptureName()
    }

    /// The capture on disk carries the room's name.
    func syncCaptureName() {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            model.updateCaptureNameFromUser(name)
        }
    }

    func startCapture() {
        guard canStart else { return }
        syncCaptureName()
        model.startCapture()
    }

    // MARK: - Capture lifecycle (called when the model changes step)

    /// Recording just began: remember where the user stands. Behind a
    /// marked door this becomes the entry door of the room.
    func captureDidStart() {
        let session = model.coordinator.session
        startSessionID = continuity.sessionIDForCaptureStart()
        startPose = session.currentFrame?.camera.transform
        startFloorY = startPose.flatMap { pose in
            Self.floorBelow(CaptureDoorGeometry.cameraPositionAndForward(pose).position, in: session)
        }
    }

    /// The capture is on disk: put it into the tour.
    func captureDidSave() {
        guard let record = model.savedRecord, handledCaptureID != record.id else { return }
        handledCaptureID = record.id

        let mesh = lastMesh
        var entryDoor: CaptureDoor?
        if cameThroughMarkedDoor, arrivalRoom != nil, let startPose {
            entryDoor = CaptureDoorGeometry.entryDoor(
                worldFromCamera: startPose, mesh: mesh, measuredFloorY: startFloorY
            )
        }
        let info = CaptureTourCaptureInfo(
            captureID: record.id,
            capturedAt: record.createdAt,
            captureSessionID: startSessionID ?? UUID().uuidString,
            entryDoor: entryDoor
        )

        var replacedCaptureID: UUID?
        var roomID: UUID?
        let arrivalID = cameThroughMarkedDoor ? arrivalRoom?.id : nil
        let name = roomName
        let floor = floorName
        let recaptureRoomID = recaptureRoomID
        tourStore.update(spaceID: spaceID) { tour in
            if let recaptureRoomID {
                replacedCaptureID = tour.replaceCapture(roomID: recaptureRoomID, with: info)
                roomID = recaptureRoomID
            } else {
                roomID = tour.addRoom(
                    name: name, floorName: floor, capture: info, arrivingFrom: arrivalID
                ).id
            }
        }
        if let replacedCaptureID {
            try? library.delete(id: replacedCaptureID)
            onCaptureReplaced(replacedCaptureID)
        }
        savedRoom = roomID.flatMap { tour.room(id: $0) }
        savedRoomCount += 1
        onRoomSaved(CosmicCaptureSummary(record: record))

        // A capture that hit the frame limit or was saved from the
        // background paused the session; wake it without a reset so the
        // door can still be marked in this capture's world.
        if model.hasReachedFrameLimit {
            continuity.markBroken()
        }
        resumeSessionKeepingWorld()
        doorStage = .choose
        doorError = nil
    }

    /// The app left the foreground: ARKit may lose the world.
    func appDidLeaveForeground() {
        continuity.markBroken()
    }

    func appDidBecomeActive() {
        if model.step == .saved {
            resumeSessionKeepingWorld()
        }
    }

    private func resumeSessionKeepingWorld() {
        let session = model.coordinator.session
        if let configuration = session.configuration {
            session.run(configuration, options: [])
        }
    }

    // MARK: - Door to the next room

    func beginAimingAtDoor() {
        doorError = nil
        doorStage = .aim
    }

    func cancelAiming() {
        doorError = nil
        doorStage = .choose
    }

    /// Measures the door in the centre of the camera image: ray cast onto
    /// the room's LiDAR mesh, or onto ARKit's scene estimate without one.
    func markDoor() async {
        guard !isMeasuringDoor else { return }
        let session = model.coordinator.session
        guard let frame = session.currentFrame, frame.camera.trackingState == .normal else {
            doorError = "Hold still for a moment. Tracking is recovering."
            return
        }
        isMeasuringDoor = true
        defer { isMeasuringDoor = false }

        let camera = CaptureDoorGeometry.cameraPositionAndForward(frame.camera.transform)
        let mesh = lastMesh
        var hitPoint: SIMD3<Float>?
        if let mesh {
            hitPoint = await Task.detached(priority: .userInitiated) {
                CaptureDoorGeometry.raycast(
                    origin: camera.position, direction: camera.forward, mesh: mesh
                )?.point
            }.value
        }
        if hitPoint == nil {
            hitPoint = Self.sceneHit(from: camera.position, direction: camera.forward, in: session)
        }
        guard let hitPoint else {
            doorError = "Couldn't measure the door. Step closer and aim at the middle of it."
            return
        }
        let door = CaptureDoorGeometry.exitDoor(
            cameraPosition: camera.position,
            rayDirection: camera.forward,
            hitPoint: hitPoint,
            mesh: mesh,
            measuredFloorY: Self.floorBelow(camera.position, in: session)
        )
        guard let door else {
            doorError = "Hold the phone upright and aim at the door."
            return
        }
        doorError = nil
        doorStage = .marked(door, distanceM: simd_distance(camera.position, hitPoint))
    }

    /// Stores the marked door. For a new room the flow moves on to the room
    /// behind it; for a re-capture it returns true and the flow ends.
    func confirmDoor() -> Bool {
        guard case .marked(let door, _) = doorStage, let room = savedRoom else { return false }
        tourStore.update(spaceID: spaceID) { $0.setExitDoor(door, roomID: room.id) }
        if isRecapture { return true }
        prepareNextRoom(arrivingFrom: tour.room(id: room.id))
        return false
    }

    /// The next room is not behind a door of this room (for example it is
    /// reached through a hallway captured earlier).
    func continueWithoutDoor() {
        prepareNextRoom(arrivingFrom: nil)
    }

    private func prepareNextRoom(arrivingFrom room: CaptureTourRoom?) {
        // Start the next room with an empty LiDAR mesh. Tracking is not
        // reset, so the world origin stays where it is.
        let session = model.coordinator.session
        if let configuration = session.configuration {
            session.run(configuration, options: [.resetSceneReconstruction])
        }
        startPose = nil
        startFloorY = nil
        startSessionID = nil
        savedRoom = nil
        doorStage = .choose
        doorError = nil
        model.prepareForNextCapture(name: "")
        configureCard(arrivingFrom: room)
    }

    // MARK: - ARKit helpers

    private var lastMesh: CaptureLidarMesh? {
        (model.experience as? CoverageGuidanceExperience)?.lastFinalizedMesh
    }

    private static func tracking(_ state: ARCamera.TrackingState) -> CaptureSessionContinuity.Tracking {
        switch state {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .relocalizing: return .relocalizing
            case .excessiveMotion, .insufficientFeatures: return .degraded
            @unknown default: return .notAvailable
            }
        }
    }

    /// ARKit's own estimate of the floor under a point; nil without one.
    private static func floorBelow(_ point: SIMD3<Float>, in session: ARSession) -> Float? {
        let query = ARRaycastQuery(
            origin: point, direction: SIMD3(0, -1, 0), allowing: .estimatedPlane, alignment: .horizontal
        )
        return session.raycast(query).first?.worldTransform.columns.3.y
    }

    private static func sceneHit(
        from origin: SIMD3<Float>, direction: SIMD3<Float>, in session: ARSession
    ) -> SIMD3<Float>? {
        let query = ARRaycastQuery(
            origin: origin, direction: direction, allowing: .estimatedPlane, alignment: .any
        )
        guard let column = session.raycast(query).first?.worldTransform.columns.3 else { return nil }
        return SIMD3(column.x, column.y, column.z)
    }
}

import Foundation
import Observation
import CosmicCapture

// MARK: - Backend models

/// A room capture as the backend reports it (`/room-captures`, see
/// cosmic-backend/docs/room-captures.md).
struct RoomCaptureJob: Decodable {
    let jobId: Int
    let status: String
    let roomId: Int?
    let errorMessage: String?
    let outputSpzPath: String?
    let uploadURL: String?
    let lidarMeshUploadURL: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case roomId = "room_id"
        case errorMessage = "error_message"
        case outputSpzPath = "output_spz_path"
        case uploadURL = "upload_url"
        case lidarMeshUploadURL = "lidar_mesh_upload_url"
    }
}

private struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

/// A door link as the backend stores it (`/room-connections`, see
/// cosmic-backend/docs/multi-room-spaces.md).
private struct BackendRoomConnection: Decodable {
    let connectionId: Int
    let fromRoomId: Int?
    let toRoomId: Int?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case fromRoomId = "from_room_id"
        case toRoomId = "to_room_id"
    }
}

/// What a tour adds to the upload of a capture: the room it belongs to.
struct RoomCaptureUploadContext {
    /// The room in the backend, once it exists. The capture then updates
    /// that room instead of creating one.
    var roomID: Int?
    var roomName: String
    var floorName: String
    var captureSessionID: String
    /// Called as soon as the backend has assigned the room.
    var onRoomAssigned: (Int) -> Void
}

private struct EmptyBody: Encodable {}

// MARK: - Local upload state

/// Where a local capture stands on its way to a finished splat.
struct RoomCaptureUploadState: Codable, Equatable {
    typealias Phase = RoomCaptureUploadPhase

    var phase: Phase
    var spaceId: Int
    var jobId: Int?
    /// Kept across retries so a second attempt does not create a second room.
    var roomId: Int?
    var errorMessage: String?
    /// The LiDAR mesh did not reach the backend; the splat itself is unaffected.
    var lidarMeshMissing = false
}

enum RoomCaptureUploadError: LocalizedError {
    case storageRejected(statusCode: Int, message: String)
    case missingUploadURL

    var errorDescription: String? {
        switch self {
        case .storageRejected(let statusCode, let message):
            return "The file upload was rejected (HTTP \(statusCode)): \(message)"
        case .missingUploadURL:
            return "The server did not return an upload address."
        }
    }
}

// MARK: - Service

/// Sends local room captures to the backend, which processes them with
/// Echo-3: register the capture, upload the ZIP (and the LiDAR mesh) straight
/// to storage, start processing, then follow the status.
@MainActor
@Observable
final class RoomCaptureUploadService {
    static let shared = RoomCaptureUploadService()

    /// Upload state per local capture id.
    private(set) var states: [UUID: RoomCaptureUploadState] = [:]
    /// Fraction of the ZIP sent so far, only while a capture is uploading.
    private(set) var progress: [UUID: Double] = [:]
    /// Why the door links of a tour could not be sent, if the last attempt failed.
    private(set) var connectionSyncError: String?

    private static let defaultsKey = "roomCaptureUploadStates"
    private let defaults: UserDefaults

    private let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        // A capture ZIP can be several hundred megabytes.
        config.timeoutIntervalForResource = 2 * 60 * 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([UUID: RoomCaptureUploadState].self, from: data) {
            // An upload cannot survive the app being closed; offer it again.
            states = saved.mapValues { state in
                guard state.phase == .uploading else { return state }
                var interrupted = state
                interrupted.phase = .failed
                interrupted.errorMessage = "The upload was interrupted."
                return interrupted
            }
        }
    }

    func state(for captureID: UUID) -> RoomCaptureUploadState? {
        states[captureID]
    }

    func quote(frameCount: Int) async throws -> RoomCaptureQuote {
        let response: DataEnvelope<RoomCaptureQuote> = try await HTTPClient.shared.get(
            "/room-captures/quote?frame_count=\(frameCount)"
        )
        return response.data
    }

    /// Uploads a capture into the given space and starts Echo-3. Errors end
    /// up in the capture's state instead of being thrown. `context` places
    /// the capture in a room of a tour; without it the capture creates a
    /// room named after itself.
    func upload(
        _ capture: CosmicCaptureSummary,
        to spaceID: Int,
        store: CosmicCaptureStore,
        context: RoomCaptureUploadContext? = nil
    ) async {
        if let current = states[capture.id], current.phase != .failed { return }

        // A room created by an earlier attempt is reused, so a retry does
        // not create a second room.
        let retriedRoomID = states[capture.id]?.spaceId == spaceID ? states[capture.id]?.roomId : nil
        let roomID = context?.roomID ?? retriedRoomID
        var state = RoomCaptureUploadState(phase: .uploading, spaceId: spaceID, roomId: roomID)
        set(state, for: capture.id)
        progress[capture.id] = 0
        defer { progress[capture.id] = nil }

        do {
            let zipURL = try await store.makeBundleZip(id: capture.id)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let registered: DataEnvelope<RoomCaptureJob> = try await HTTPClient.shared.post(
                "/room-captures",
                body: RoomCaptureRegistrationBody(
                    spaceID: spaceID,
                    title: capture.name,
                    frameCount: capture.frameCount,
                    roomID: roomID,
                    roomName: context?.roomName ?? capture.name,
                    floorName: context?.floorName,
                    capturedAt: capture.createdAt,
                    captureSessionID: context?.captureSessionID,
                    hasLidarMesh: capture.lidarMeshURL != nil
                )
            )
            let job = registered.data
            state.jobId = job.jobId
            state.roomId = job.roomId ?? roomID
            set(state, for: capture.id)
            if let assignedRoomID = state.roomId {
                context?.onRoomAssigned(assignedRoomID)
            }

            guard let uploadURL = job.uploadURL.flatMap(URL.init(string:)) else {
                throw RoomCaptureUploadError.missingUploadURL
            }
            let captureID = capture.id
            try await put(file: zipURL, to: uploadURL, contentType: "application/zip") { [weak self] fraction in
                self?.progress[captureID] = fraction
            }

            if let meshURL = capture.lidarMeshURL {
                do {
                    guard let target = job.lidarMeshUploadURL.flatMap(URL.init(string:)) else {
                        throw RoomCaptureUploadError.missingUploadURL
                    }
                    try await put(file: meshURL, to: target, contentType: "model/gltf-binary") { _ in }
                } catch {
                    // The mesh is a sidecar: the splat can still be built without it.
                    state.lidarMeshMissing = true
                }
            }

            let started: DataEnvelope<RoomCaptureJob> = try await HTTPClient.shared.post(
                "/room-captures/\(job.jobId)/start",
                body: EmptyBody()
            )
            apply(started.data, to: &state)
            set(state, for: capture.id)
        } catch {
            state.phase = .failed
            state.errorMessage = error.localizedDescription
            set(state, for: capture.id)
        }
    }

    /// Asks the backend how far every capture in processing has come.
    func refreshProcessing() async {
        for (captureID, state) in states where state.phase == .processing {
            guard let jobID = state.jobId else { continue }
            do {
                let response: DataEnvelope<RoomCaptureJob> = try await HTTPClient.shared.get(
                    "/room-captures/\(jobID)"
                )
                var updated = state
                apply(response.data, to: &updated)
                set(updated, for: captureID)
            } catch {
                // Keep the last known state; the next refresh tries again.
            }
        }
    }

    var hasProcessingCaptures: Bool {
        states.values.contains { $0.phase == .processing }
    }

    /// Drops the state of a capture that was deleted from the device.
    func forget(_ captureID: UUID) {
        states[captureID] = nil
        persist()
    }

    // MARK: - Tours

    /// Uploads the capture of a tour room: floor, capture time and session
    /// go along, and a room that already exists in the backend is updated
    /// instead of duplicated. Afterwards the door links are brought up to date.
    func uploadTourRoom(
        _ roomID: UUID,
        spaceID: Int,
        tours: CosmicTourStore,
        captures: CosmicCaptureStore
    ) async {
        guard let room = tours.tour(for: spaceID).room(id: roomID),
              let capture = captures.captures.first(where: { $0.id == room.captureID })
        else { return }
        let context = RoomCaptureUploadContext(
            roomID: room.backendRoomID,
            roomName: room.name,
            floorName: room.floorName,
            captureSessionID: room.captureSessionID,
            onRoomAssigned: { backendRoomID in
                tours.update(spaceID: spaceID) { $0.setBackendRoomID(backendRoomID, roomID: roomID) }
            }
        )
        await upload(capture, to: spaceID, store: captures, context: context)
        await syncTour(spaceID: spaceID, tours: tours)
    }

    /// Creates or updates the door links (`/room-connections`) whose two
    /// rooms are uploaded. Safe to call again at any time: the connection id
    /// is remembered in the tour, and a connection the backend already has
    /// for the same two rooms is updated instead of created twice.
    func syncTour(spaceID: Int, tours: CosmicTourStore) async {
        // Rooms registered by an upload that was cut off before the tour was saved.
        for room in tours.tour(for: spaceID).rooms where room.backendRoomID == nil {
            if let state = states[room.captureID], state.spaceId == spaceID, let backendRoomID = state.roomId {
                tours.update(spaceID: spaceID) { $0.setBackendRoomID(backendRoomID, roomID: room.id) }
            }
        }

        let tour = tours.tour(for: spaceID)
        var jobIDs: [UUID: Int] = [:]
        for room in tour.rooms {
            guard let state = states[room.captureID], state.spaceId == spaceID, let jobID = state.jobId,
                  state.phase == .processing || state.phase == .completed
            else { continue }
            jobIDs[room.captureID] = jobID
        }
        let actions = tour.connectionActions(jobIDs: jobIDs)
        guard !actions.isEmpty else {
            connectionSyncError = nil
            return
        }

        var failure: String?
        var existing: [BackendRoomConnection]?
        for action in actions {
            do {
                var connectionID = action.connectionID
                if connectionID == nil {
                    if existing == nil {
                        let listed: DataEnvelope<[BackendRoomConnection]> = try await HTTPClient.shared.get(
                            "/room-connections?space_id=\(spaceID)"
                        )
                        existing = listed.data
                    }
                    connectionID = existing?.first {
                        $0.fromRoomId == action.body.fromRoomID && $0.toRoomId == action.body.toRoomID
                    }?.connectionId
                }
                if let connectionID {
                    let _: DataEnvelope<BackendRoomConnection> = try await HTTPClient.shared.patch(
                        "/room-connections/\(connectionID)",
                        body: action.body.asUpdate
                    )
                } else {
                    let created: DataEnvelope<BackendRoomConnection> = try await HTTPClient.shared.post(
                        "/room-connections",
                        body: action.body
                    )
                    connectionID = created.data.connectionId
                }
                if let connectionID {
                    let record = CaptureTourConnectionRecord(
                        connectionID: connectionID, fromJobID: action.fromJobID, toJobID: action.toJobID
                    )
                    tours.update(spaceID: spaceID) { $0.setExitConnection(record, roomID: action.fromRoomID) }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        connectionSyncError = failure
    }

    // MARK: - Private

    private func apply(_ job: RoomCaptureJob, to state: inout RoomCaptureUploadState) {
        state.phase = RoomCaptureUploadPhase(backendStatus: job.status)
        switch state.phase {
        case .failed:
            state.errorMessage = job.errorMessage ?? "Processing failed."
        case .completed, .processing:
            state.errorMessage = nil
        case .uploading:
            break
        }
    }

    private func set(_ state: RoomCaptureUploadState, for captureID: UUID) {
        states[captureID] = state
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Sends a file to a signed storage upload URL.
    private func put(
        file: URL,
        to url: URL,
        contentType: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await uploadSession.upload(for: request, fromFile: file, delegate: delegate)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw RoomCaptureUploadError.storageRejected(statusCode: statusCode, message: message)
        }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @MainActor (Double) -> Void

    init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let onProgress = onProgress
        Task { @MainActor in onProgress(fraction) }
    }
}

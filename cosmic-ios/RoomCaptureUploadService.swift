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

/// Price and duration of processing one capture with Echo-3.
struct RoomCaptureQuote: Decodable {
    let requiredCredits: Int
    let availableCredits: Int
    let hasEnough: Bool
    let estimatedDurationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case requiredCredits = "required_credits"
        case availableCredits = "available_credits"
        case hasEnough = "has_enough"
        case estimatedDurationSeconds = "estimated_duration_seconds"
    }
}

private struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct RegisterCaptureBody: Encodable {
    let spaceId: Int
    let title: String
    let frameCount: Int
    let roomId: Int?
    let roomName: String?
    let hasLidarMesh: Bool

    enum CodingKeys: String, CodingKey {
        case spaceId = "space_id"
        case title
        case frameCount = "frame_count"
        case roomId = "room_id"
        case roomName = "room_name"
        case hasLidarMesh = "has_lidar_mesh"
    }
}

private struct EmptyBody: Encodable {}

// MARK: - Local upload state

/// Where a local capture stands on its way to a finished splat.
struct RoomCaptureUploadState: Codable, Equatable {
    enum Phase: String, Codable {
        /// The ZIP is being built or uploaded from this device.
        case uploading
        /// Echo-3 is working on it.
        case processing
        case completed
        case failed
    }

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
    /// up in the capture's state instead of being thrown.
    func upload(_ capture: CosmicCaptureSummary, to spaceID: Int, store: CosmicCaptureStore) async {
        if let current = states[capture.id], current.phase != .failed { return }

        let roomID = states[capture.id]?.spaceId == spaceID ? states[capture.id]?.roomId : nil
        var state = RoomCaptureUploadState(phase: .uploading, spaceId: spaceID, roomId: roomID)
        set(state, for: capture.id)
        progress[capture.id] = 0
        defer { progress[capture.id] = nil }

        do {
            let zipURL = try await store.makeBundleZip(id: capture.id)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let registered: DataEnvelope<RoomCaptureJob> = try await HTTPClient.shared.post(
                "/room-captures",
                body: RegisterCaptureBody(
                    spaceId: spaceID,
                    title: capture.name,
                    frameCount: capture.frameCount,
                    roomId: roomID,
                    roomName: roomID == nil ? capture.name : nil,
                    hasLidarMesh: capture.lidarMeshURL != nil
                )
            )
            let job = registered.data
            state.jobId = job.jobId
            state.roomId = job.roomId
            set(state, for: capture.id)

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

    // MARK: - Private

    private func apply(_ job: RoomCaptureJob, to state: inout RoomCaptureUploadState) {
        switch job.status {
        case "completed":
            state.phase = .completed
            state.errorMessage = nil
        case "failed", "cancelled":
            state.phase = .failed
            state.errorMessage = job.errorMessage ?? "Processing failed."
        case "uploading":
            state.phase = .uploading
        default:
            state.phase = .processing
            state.errorMessage = nil
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

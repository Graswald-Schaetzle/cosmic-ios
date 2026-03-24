import Foundation

// MARK: - Models

struct ReconstructionJob: Decodable {
    let jobId: Int
    let spaceId: Int
    let status: String
    let inputType: String
    let uploadUrl: String?

    enum CodingKeys: String, CodingKey {
        case jobId    = "job_id"
        case spaceId  = "space_id"
        case status
        case inputType = "input_type"
        case uploadUrl = "upload_url"
    }
}

private struct CreateJobResponse: Decodable {
    let data: ReconstructionJob
}

private struct StartJobResponse: Decodable {
    let data: ReconstructionJob
}

// MARK: - Service

/// Manages the 3-step reconstruction job lifecycle:
///  1. Create job → receive signed GCS upload URL
///  2. Upload ZIP directly to GCS (bypassing the Express backend)
///  3. Start GPU processing on RunPod
@MainActor
final class ReconstructionJobService {

    static let shared = ReconstructionJobService()

    /// Upload progress for the GCS direct upload (0.0 – 1.0).
    @Published private(set) var gcsUploadProgress: Double = 0.0

    private init() {}

    // MARK: - Step 1: Create job

    /// Creates a reconstruction job record and returns the job with a signed GCS upload URL.
    func createJob(spaceId: Int, title: String) async throws -> ReconstructionJob {
        struct Body: Encodable {
            let space_id: Int
            let title: String
            let input_type: String
        }

        let response: CreateJobResponse = try await HTTPClient.shared.post(
            "/reconstruction-jobs",
            body: Body(space_id: spaceId, title: title, input_type: "arkit_frames")
        )
        return response.data
    }

    // MARK: - Step 2: Upload ZIP to GCS

    /// Uploads the ZIP file directly to GCS using the signed URL from step 1.
    /// This bypasses the Express backend entirely (no 2GB limit, faster).
    func uploadZipToGCS(zipURL: URL, signedUploadURL: String) async throws {
        guard let url = URL(string: signedUploadURL) else {
            throw ReconstructionError.invalidUploadURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600  // 10 min for large uploads

        // Use background-capable session with progress tracking
        let delegate = UploadProgressDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.gcsUploadProgress = progress
            }
        }

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        gcsUploadProgress = 0.0

        let (_, response) = try await session.upload(for: request, fromFile: zipURL)

        gcsUploadProgress = 1.0

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw ReconstructionError.gcsUploadFailed(http?.statusCode ?? -1)
        }
    }

    // MARK: - Step 3: Start processing

    /// Signals the backend that the upload is complete and triggers the RunPod GPU worker.
    func startProcessing(jobId: Int) async throws -> ReconstructionJob {
        struct EmptyBody: Encodable {}
        let response: StartJobResponse = try await HTTPClient.shared.post(
            "/reconstruction-jobs/\(jobId)/start",
            body: EmptyBody()
        )
        return response.data
    }

    // MARK: - Convenience: full pipeline

    /// Runs all three steps: create → upload → start.
    /// Returns the started job record.
    func submitScan(
        spaceId: Int,
        title: String,
        zipURL: URL
    ) async throws -> ReconstructionJob {
        gcsUploadProgress = 0.0

        // 1. Create
        let job = try await createJob(spaceId: spaceId, title: title)

        guard let uploadURL = job.uploadUrl else {
            throw ReconstructionError.noUploadURL
        }

        // 2. Upload
        try await uploadZipToGCS(zipURL: zipURL, signedUploadURL: uploadURL)

        // 3. Start
        return try await startProcessing(jobId: job.jobId)
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {

    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Errors

enum ReconstructionError: LocalizedError {
    case invalidUploadURL
    case noUploadURL
    case gcsUploadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidUploadURL:       return "Upload-URL ist ungültig."
        case .noUploadURL:            return "Keine Upload-URL vom Server erhalten."
        case .gcsUploadFailed(let c): return "GCS-Upload fehlgeschlagen (HTTP \(c))."
        }
    }
}

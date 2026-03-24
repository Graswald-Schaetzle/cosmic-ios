import Foundation
import Combine

@MainActor
final class UploadService: ObservableObject {

    // MARK: - Singleton

    static let shared = UploadService()

    // MARK: - Published State

    @Published var uploadProgress: Double = 0.0
    @Published var isUploading: Bool = false
    @Published var lastError: UploadError?

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Lädt eine .usdz-Datei ans Backend hoch und legt einen neuen Space-Eintrag an.
    func uploadScan(fileURL: URL, spaceName: String) async throws -> UploadResult {
        guard HTTPClient.shared.authToken != nil else {
            lastError = .notAuthenticated
            throw UploadError.notAuthenticated
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastError = .noFileFound
            throw UploadError.noFileFound
        }

        isUploading = true
        uploadProgress = 0.0
        lastError = nil

        defer { isUploading = false }

        do {
            let space: Space = try await HTTPClient.shared.upload(
                "/spaces/upload",
                fileURL: fileURL,
                fileFieldName: "model",
                additionalFields: ["name": spaceName],
                onProgress: { [weak self] progress in
                    self?.uploadProgress = progress
                }
            )

            uploadProgress = 1.0
            let modelUrl = space.modelUrl ?? fileURL.lastPathComponent
            return UploadResult(space: space, modelUrl: modelUrl)

        } catch let clientError as HTTPClientError {
            let wrapped = mapHTTPClientError(clientError)
            lastError = wrapped
            throw wrapped
        } catch let uploadError as UploadError {
            lastError = uploadError
            throw uploadError
        } catch {
            let wrapped = UploadError.uploadFailed(error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
    }

    // MARK: - Private Helpers

    private func mapHTTPClientError(_ error: HTTPClientError) -> UploadError {
        switch error {
        case .notAuthenticated:
            return .notAuthenticated
        case .invalidURL:
            return .invalidResponse
        case .decodingFailed:
            return .invalidResponse
        case .requestFailed(let statusCode, let message):
            if statusCode >= 500 {
                return .serverError(statusCode)
            } else {
                return .uploadFailed(message)
            }
        case .networkError(let underlyingError):
            return .uploadFailed(underlyingError.localizedDescription)
        }
    }
}

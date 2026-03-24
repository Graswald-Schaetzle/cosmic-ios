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

    // MARK: - Private Properties

    private let baseURL = "https://api.cosmic-app.de"

    private var authToken: String {
        AuthService.shared.backendToken ?? ""
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Lädt eine .usdz-Datei ans Backend hoch und legt einen neuen Space-Eintrag an.
    func uploadScan(fileURL: URL, spaceName: String) async throws -> UploadResult {
        guard !authToken.isEmpty else {
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
            let boundary = UUID().uuidString
            let requestBody = try buildMultipartBody(
                fileURL: fileURL,
                spaceName: spaceName,
                boundary: boundary
            )

            uploadProgress = 0.5

            guard let endpoint = URL(string: "\(baseURL)/spaces/upload") else {
                throw UploadError.invalidResponse
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.upload(for: request, from: requestBody)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let serverMessage = String(data: data, encoding: .utf8) ?? "Kein Detail verfügbar."
                if httpResponse.statusCode >= 500 {
                    throw UploadError.serverError(httpResponse.statusCode)
                } else {
                    throw UploadError.uploadFailed(serverMessage)
                }
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let space: Space
            do {
                space = try decoder.decode(Space.self, from: data)
            } catch {
                throw UploadError.invalidResponse
            }

            uploadProgress = 1.0
            let modelUrl = space.modelUrl ?? fileURL.lastPathComponent
            return UploadResult(space: space, modelUrl: modelUrl)

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

    private func buildMultipartBody(fileURL: URL, spaceName: String, boundary: String) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"name\"\(crlf)")
        body.append(crlf)
        body.append(spaceName)
        body.append(crlf)

        let fileName = fileURL.lastPathComponent
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw UploadError.noFileFound
        }

        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"model\"; filename=\"\(fileName)\"\(crlf)")
        body.append("Content-Type: model/vnd.usdz+zip\(crlf)")
        body.append(crlf)
        body.append(fileData)
        body.append(crlf)
        body.append("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}

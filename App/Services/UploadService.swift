// UploadService.swift
// Handles uploading scanned USDZ models to the Cosmic backend API

import Foundation

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

    // TODO: Replace UserDefaults storage with Keychain to securely persist the auth token.
    private var authToken: String {
        UserDefaults.standard.string(forKey: "cosmic_auth_token") ?? ""
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

    /// Saves the Supabase JWT auth token for use in subsequent requests.
    /// - Parameter token: A valid Supabase JWT string.
    /// - Note: TODO — replace UserDefaults with Keychain storage for production.
    func setAuthToken(_ token: String) {
        // TODO: Store token in Keychain instead of UserDefaults for security.
        UserDefaults.standard.set(token, forKey: "cosmic_auth_token")
    }

    /// Uploads a USDZ scan file to the backend and creates a new Space record.
    ///
    /// - Parameters:
    ///   - fileURL: Local URL of the `.usdz` file to upload.
    ///   - spaceName: Human-readable name for the new Space.
    /// - Returns: An `UploadResult` containing the created `Space` and the remote model URL.
    /// - Throws: `UploadError` on authentication failure, network errors, or unexpected server responses.
    func uploadScan(fileURL: URL, spaceName: String) async throws -> UploadResult {
        // Guard: require a valid auth token before attempting upload.
        guard !authToken.isEmpty else {
            lastError = .notAuthenticated
            throw UploadError.notAuthenticated
        }

        // Guard: ensure the local file actually exists.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastError = .noFileFound
            throw UploadError.noFileFound
        }

        isUploading = true
        uploadProgress = 0.0
        lastError = nil

        defer {
            isUploading = false
        }

        do {
            // Build the multipart/form-data request body.
            let boundary = UUID().uuidString
            let requestBody = try buildMultipartBody(
                fileURL: fileURL,
                spaceName: spaceName,
                boundary: boundary
            )

            // Signal that file data is assembled and we're about to send.
            uploadProgress = 0.5

            // Construct the URLRequest targeting POST /spaces/upload.
            guard let endpoint = URL(string: "\(baseURL)/spaces/upload") else {
                throw UploadError.invalidResponse
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(
                "Bearer \(authToken)",
                forHTTPHeaderField: "Authorization"
            )

            // Perform the upload using async/await.
            let (data, response) = try await session.upload(for: request, from: requestBody)

            // Validate the HTTP status code.
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // Attempt to surface a server-provided message for debugging.
                let serverMessage = String(data: data, encoding: .utf8) ?? "Kein Detail verfügbar."
                if httpResponse.statusCode >= 500 {
                    throw UploadError.serverError(httpResponse.statusCode)
                } else {
                    throw UploadError.uploadFailed(serverMessage)
                }
            }

            // Decode the returned Space JSON.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let space: Space
            do {
                space = try decoder.decode(Space.self, from: data)
            } catch {
                throw UploadError.invalidResponse
            }

            // Upload complete.
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

    /// Builds a multipart/form-data body containing the USDZ binary and the space name.
    private func buildMultipartBody(
        fileURL: URL,
        spaceName: String,
        boundary: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        // -- Append "name" text field --
        body.append("--\(boundary)\(crlf)")
        body.append("Content-Disposition: form-data; name=\"name\"\(crlf)")
        body.append(crlf)
        body.append(spaceName)
        body.append(crlf)

        // -- Append "model" file field --
        let fileName = fileURL.lastPathComponent
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw UploadError.noFileFound
        }

        body.append("--\(boundary)\(crlf)")
        body.append(
            "Content-Disposition: form-data; name=\"model\"; filename=\"\(fileName)\"\(crlf)"
        )
        body.append("Content-Type: model/vnd.usdz+zip\(crlf)")
        body.append(crlf)
        body.append(fileData)
        body.append(crlf)

        // -- Closing boundary --
        body.append("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Data Extension

private extension Data {
    /// Appends a UTF-8 encoded string to the data buffer.
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}

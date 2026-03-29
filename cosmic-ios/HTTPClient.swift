import Foundation

// MARK: - HTTP Method

enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case DELETE
    case PATCH
}

// MARK: - HTTPClientError

enum HTTPClientError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case requestFailed(statusCode: Int, message: String)
    case decodingFailed
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige URL – der Endpunkt konnte nicht aufgerufen werden."
        case .notAuthenticated:
            return "Nicht angemeldet. Bitte zuerst einloggen."
        case .requestFailed(let statusCode, let message):
            return "Anfrage fehlgeschlagen (HTTP \(statusCode)): \(message)"
        case .decodingFailed:
            return "Die Serverantwort konnte nicht verarbeitet werden."
        case .networkError(let error):
            return "Netzwerkfehler: \(error.localizedDescription)"
        }
    }
}

// MARK: - HTTPClient

@MainActor
final class HTTPClient {

    // MARK: - Singleton

    static let shared = HTTPClient()

    // MARK: - Properties

    private let baseURL: String = Config.backendBaseURL

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Auth Token

    var authToken: String? {
        KeychainService.get("cosmic_backend_token")
    }

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Generische GET-Anfrage mit automatischer Dekodierung.
    func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(method: .GET, path: path)
        return try await perform(request)
    }

    /// Generische POST-Anfrage mit Codable-Body und automatischer Dekodierung.
    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = try encoder.encode(body)
        let request = try buildRequest(method: .POST, path: path, body: bodyData, contentType: "application/json")
        return try await perform(request)
    }

    /// Generische PUT-Anfrage mit Codable-Body und automatischer Dekodierung.
    func put<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = try encoder.encode(body)
        let request = try buildRequest(method: .PUT, path: path, body: bodyData, contentType: "application/json")
        return try await perform(request)
    }

    /// Multipart-Upload für Dateien (z. B. USDZ-Modelle) mit optionalem Progress-Callback.
    func upload<Response: Decodable>(
        _ path: String,
        fileURL: URL,
        fileFieldName: String,
        additionalFields: [String: String] = [:],
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Response {
        let boundary = UUID().uuidString
        let bodyData = try buildMultipartBody(
            fileURL: fileURL,
            fileFieldName: fileFieldName,
            additionalFields: additionalFields,
            boundary: boundary
        )

        onProgress?(0.3)

        var request = try buildRequest(
            method: .POST,
            path: path,
            body: bodyData,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        // URLSession.upload(for:from:) erwartet keinen httpBody – wir übergeben ihn als fromData
        request.httpBody = nil

        let result: Response = try await performUpload(request, data: bodyData, onProgress: onProgress)
        return result
    }

    // MARK: - Private Helpers

    /// Erstellt einen konfigurierten URLRequest.
    private func buildRequest(
        method: HTTPMethod,
        path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw HTTPClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let body = body {
            request.httpBody = body
        }

        return request
    }

    /// Führt eine Anfrage durch und dekodiert die Antwort.
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPClientError.networkError(error)
        }

        if shouldRefreshAuth(response: response, data: data) {
            return try await retryAfterRefreshingAuth(originalRequest: request)
        }

        try validate(response: response, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decodingFailed
        }
    }

    /// Führt einen Datei-Upload durch und dekodiert die Antwort.
    private func performUpload<T: Decodable>(
        _ request: URLRequest,
        data: Data,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> T {
        let responseData: Data
        let response: URLResponse

        do {
            (responseData, response) = try await session.upload(for: request, from: data)
        } catch {
            throw HTTPClientError.networkError(error)
        }

        if shouldRefreshAuth(response: response, data: responseData) {
            return try await retryUploadAfterRefreshingAuth(
                originalRequest: request,
                data: data,
                onProgress: onProgress
            )
        }

        onProgress?(1.0)

        try validate(response: response, data: responseData)

        do {
            return try decoder.decode(T.self, from: responseData)
        } catch {
            throw HTTPClientError.decodingFailed
        }
    }

    /// Prüft den HTTP-Statuscode und wirft bei Fehlern eine passende Exception.
    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.requestFailed(statusCode: -1, message: "Ungültige Serverantwort.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Kein Detail verfügbar."
            throw HTTPClientError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func retryAfterRefreshingAuth<T: Decodable>(originalRequest: URLRequest) async throws -> T {
        do {
            try await AuthService.shared.refreshSessionIfNeeded(force: true)
        } catch {
            throw HTTPClientError.notAuthenticated
        }

        let retriedRequest = try rebuildAuthorizedRequest(from: originalRequest)
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: retriedRequest)
        } catch {
            throw HTTPClientError.networkError(error)
        }

        try validate(response: response, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decodingFailed
        }
    }

    private func retryUploadAfterRefreshingAuth<T: Decodable>(
        originalRequest: URLRequest,
        data: Data,
        onProgress: ((Double) -> Void)?
    ) async throws -> T {
        do {
            try await AuthService.shared.refreshSessionIfNeeded(force: true)
        } catch {
            throw HTTPClientError.notAuthenticated
        }

        let retriedRequest = try rebuildAuthorizedRequest(from: originalRequest)
        let (responseData, response): (Data, URLResponse)

        do {
            (responseData, response) = try await session.upload(for: retriedRequest, from: data)
        } catch {
            throw HTTPClientError.networkError(error)
        }

        onProgress?(1.0)
        try validate(response: response, data: responseData)

        do {
            return try decoder.decode(T.self, from: responseData)
        } catch {
            throw HTTPClientError.decodingFailed
        }
    }

    private func rebuildAuthorizedRequest(from request: URLRequest) throws -> URLRequest {
        guard let token = authToken, !token.isEmpty else {
            throw HTTPClientError.notAuthenticated
        }

        var rebuiltRequest = request
        rebuiltRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return rebuiltRequest
    }

    private func shouldRefreshAuth(response: URLResponse, data: Data) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        let statusCode = httpResponse.statusCode
        if statusCode == 401 || statusCode == 403 {
            return true
        }

        guard statusCode == 404 else {
            return false
        }

        let message = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        return message.contains("tokenexpirederror")
            || message.contains("jwt expired")
            || message.contains("expired token")
            || message.contains("expired")
    }

    /// Erstellt den Multipart-Form-Data-Body.
    private func buildMultipartBody(
        fileURL: URL,
        fileFieldName: String,
        additionalFields: [String: String],
        boundary: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        for (key, value) in additionalFields {
            body.appendString("--\(boundary)\(crlf)")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\(crlf)")
            body.appendString(crlf)
            body.appendString(value)
            body.appendString(crlf)
        }

        let fileName = fileURL.lastPathComponent
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw HTTPClientError.networkError(error)
        }

        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(crlf)")
        body.appendString("Content-Type: model/vnd.usdz+zip\(crlf)")
        body.appendString(crlf)
        body.append(fileData)
        body.appendString(crlf)
        body.appendString("--\(boundary)--\(crlf)")

        return body
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func appendString(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}

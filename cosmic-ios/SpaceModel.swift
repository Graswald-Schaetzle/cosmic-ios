import Foundation

struct Space: Codable, Identifiable {
    let id: String
    let userId: String
    let name: String
    let modelUrl: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case modelUrl = "model_url"
        case createdAt = "created_at"
    }
}

struct UploadResult {
    let space: Space
    let modelUrl: String
}

enum UploadError: LocalizedError {
    case noFileFound
    case uploadFailed(String)
    case serverError(Int)
    case invalidResponse
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .noFileFound:
            return "Keine Datei zum Hochladen gefunden."
        case .uploadFailed(let msg):
            return "Upload fehlgeschlagen: \(msg)"
        case .serverError(let code):
            return "Serverfehler (Code \(code))."
        case .invalidResponse:
            return "Ungültige Serverantwort."
        case .notAuthenticated:
            return "Nicht angemeldet. Bitte einloggen."
        }
    }
}

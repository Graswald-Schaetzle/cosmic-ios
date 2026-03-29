// AuthService.swift
// Handles Supabase email/password authentication and backend JWT exchange.
//
// Two-phase flow:
//   1. Sign in via Supabase Auth REST API → get Supabase session (user.id)
//   2. Exchange user.id for a backend JWT via POST /auth/login
//   3. Store backend JWT in Keychain for subsequent API calls

import Foundation
import Combine

// MARK: - Response Models

private struct SupabaseAuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

private struct BackendLoginResponse: Decodable {
    let user: BackendUser
}

private struct BackendUser: Decodable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// MARK: - AuthError

enum AuthError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case backendExchangeFailed
    case notAuthenticated
    case sessionRefreshFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "E-Mail oder Passwort ist falsch."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .backendExchangeFailed:
            return "Backend-Authentifizierung fehlgeschlagen."
        case .notAuthenticated:
            return "Nicht eingeloggt."
        case .sessionRefreshFailed:
            return "Die Sitzung konnte nicht erneuert werden."
        }
    }
}

// MARK: - Keychain Keys

private enum KeychainKey {
    static let backendToken = "cosmic_backend_token"
    static let backendRefreshToken = "cosmic_backend_refresh_token"
    static let supabaseRefreshToken = "cosmic_supabase_refresh_token"
    static let supabaseUserId = "cosmic_supabase_user_id"
}

// MARK: - AuthService

@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var isAuthenticated: Bool = false

    private let session = URLSession.shared
    private var ongoingRefreshTask: Task<Void, Error>?

    private init() {}

    // MARK: - Public API

    func signIn(email: String, password: String) async throws {
        let supabaseSession = try await supabaseSignIn(email: email, password: password)
        try await exchangeWithBackend(supabaseUserId: supabaseSession.user.id)

        KeychainService.set(supabaseSession.refreshToken, for: KeychainKey.supabaseRefreshToken)
        KeychainService.set(supabaseSession.user.id, for: KeychainKey.supabaseUserId)

        isAuthenticated = true
    }

    func signOut() {
        KeychainService.delete(KeychainKey.backendToken)
        KeychainService.delete(KeychainKey.backendRefreshToken)
        KeychainService.delete(KeychainKey.supabaseRefreshToken)
        KeychainService.delete(KeychainKey.supabaseUserId)
        isAuthenticated = false
    }

    /// Called at app start to restore a previous session without requiring re-login.
    func restoreSession() async {
        guard let supabaseUserId = KeychainService.get(KeychainKey.supabaseUserId),
              !supabaseUserId.isEmpty else {
            return
        }

        let hasBackendToken = !(KeychainService.get(KeychainKey.backendToken) ?? "").isEmpty
        let hasRefreshFallback =
            !(KeychainService.get(KeychainKey.backendRefreshToken) ?? "").isEmpty ||
            !(KeychainService.get(KeychainKey.supabaseRefreshToken) ?? "").isEmpty

        guard hasBackendToken || hasRefreshFallback else { return }

        isAuthenticated = true
    }

    /// The backend JWT to use in Authorization headers.
    var backendToken: String? {
        KeychainService.get(KeychainKey.backendToken)
    }

    func refreshSessionIfNeeded(force: Bool = false) async throws {
        if !force, let backendToken, !backendToken.isEmpty {
            isAuthenticated = true
            return
        }

        if let ongoingRefreshTask {
            try await ongoingRefreshTask.value
            return
        }

        let task = Task { @MainActor in
            try await self.performSessionRefresh()
        }
        ongoingRefreshTask = task

        defer { ongoingRefreshTask = nil }
        try await task.value
    }

    // MARK: - Private

    private func supabaseSignIn(email: String, password: String) async throws -> SupabaseAuthResponse {
        guard let url = URL(string: "\(Config.supabaseURL)/auth/v1/token?grant_type=password") else {
            throw AuthError.networkError("Ungültige URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("Keine gültige Antwort")
        }

        guard (200...299).contains(http.statusCode) else {
            throw AuthError.invalidCredentials
        }

        return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
    }

    private func exchangeWithBackend(supabaseUserId: String) async throws {
        guard let url = URL(string: "\(Config.backendBaseURL)/auth/login") else {
            throw AuthError.networkError("Ungültige Backend-URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["supabase_id": supabaseUserId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.backendExchangeFailed
        }

        let loginResponse = try JSONDecoder().decode(BackendLoginResponse.self, from: data)

        if let token = loginResponse.user.accessToken {
            KeychainService.set(token, for: KeychainKey.backendToken)
        }
        if let refresh = loginResponse.user.refreshToken {
            KeychainService.set(refresh, for: KeychainKey.backendRefreshToken)
        }
    }

    private func performSessionRefresh() async throws {
        guard let supabaseUserId = KeychainService.get(KeychainKey.supabaseUserId),
              !supabaseUserId.isEmpty else {
            signOut()
            throw AuthError.notAuthenticated
        }

        if let backendRefreshToken = KeychainService.get(KeychainKey.backendRefreshToken),
           !backendRefreshToken.isEmpty {
            do {
                try await refreshBackendAccessToken(using: backendRefreshToken)
                isAuthenticated = true
                return
            } catch {
                // Fall back to a fresh backend exchange below.
            }
        }

        do {
            try await exchangeWithBackend(supabaseUserId: supabaseUserId)
            isAuthenticated = true
        } catch {
            signOut()
            throw AuthError.sessionRefreshFailed
        }
    }

    private func refreshBackendAccessToken(using refreshToken: String) async throws {
        guard let url = URL(string: "\(Config.backendBaseURL)/auth/refresh") else {
            throw AuthError.networkError("Ungültige Backend-URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AuthError.sessionRefreshFailed
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw AuthError.sessionRefreshFailed
        }

        let userPayload = json["user"] as? [String: Any]
        let accessToken =
            (json["access_token"] as? String) ??
            (json["accessToken"] as? String) ??
            (userPayload?["access_token"] as? String) ??
            (userPayload?["accessToken"] as? String)

        let nextRefreshToken =
            (json["refresh_token"] as? String) ??
            (json["refreshToken"] as? String) ??
            (userPayload?["refresh_token"] as? String) ??
            (userPayload?["refreshToken"] as? String)

        guard let accessToken, !accessToken.isEmpty else {
            throw AuthError.sessionRefreshFailed
        }

        KeychainService.set(accessToken, for: KeychainKey.backendToken)

        if let nextRefreshToken, !nextRefreshToken.isEmpty {
            KeychainService.set(nextRefreshToken, for: KeychainKey.backendRefreshToken)
        }
    }
}

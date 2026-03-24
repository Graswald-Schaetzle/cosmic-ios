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
              let backendToken = KeychainService.get(KeychainKey.backendToken),
              !supabaseUserId.isEmpty,
              !backendToken.isEmpty else {
            return
        }
        isAuthenticated = true
    }

    /// The backend JWT to use in Authorization headers.
    var backendToken: String? {
        KeychainService.get(KeychainKey.backendToken)
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

        let body = ["clerk_id": supabaseUserId]
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
}

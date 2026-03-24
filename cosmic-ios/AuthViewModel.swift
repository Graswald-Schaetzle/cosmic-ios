// AuthViewModel.swift
// Presentation logic for the login screen.

import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var email: String = ""
    @Published var password: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let authService = AuthService.shared

    func login() async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Bitte E-Mail und Passwort eingeben."
            return
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await authService.signIn(email: email, password: password)
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Unbekannter Fehler: \(error.localizedDescription)"
        }
    }

    func logout() async {
        authService.signOut()
    }
}

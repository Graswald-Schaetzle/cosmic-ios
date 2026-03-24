//
//  cosmic_iosApp.swift
//  cosmic-ios
//
//  Created by Cosimo on 23.03.26.
//

import SwiftUI
import SwiftData

@main
struct cosmic_iosApp: App {

    @StateObject private var authService = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    ContentView()
                } else {
                    LoginView()
                }
            }
            .task {
                await authService.restoreSession()
            }
        }
        .modelContainer(for: ScanRecord.self)
    }
}

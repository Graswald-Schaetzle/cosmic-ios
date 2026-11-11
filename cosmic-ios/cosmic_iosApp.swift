//
//  cosmic_iosApp.swift
//  cosmic-ios
//
//  Created by Cosimo on 23.03.26.
//

import SwiftUI
import SwiftData
import CosmicCapture

@main
struct cosmic_iosApp: App {

    // Lets the capture flow lock the interface orientation during a scan.
    @UIApplicationDelegateAdaptor(CaptureAppDelegate.self) private var captureAppDelegate
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

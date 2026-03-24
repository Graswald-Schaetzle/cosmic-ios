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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ScanRecord.self)
    }
}

//
//  ContentView.swift
//  cosmic-ios
//
//  Created by Cosimo on 23.03.26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ARMeshScannerView()
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }

            ScanHistoryView()
                .tabItem {
                    Label("Verlauf", systemImage: "clock")
                }
        }
    }
}

#Preview {
    ContentView()
}

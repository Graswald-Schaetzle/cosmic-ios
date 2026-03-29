// Config.swift
// Central configuration for external services.

import Foundation

enum Config {
    static let supabaseURL = "https://haaaayxcejprzqjainzp.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhhYWFheXhjZWpwcnpxamFpbnpwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQ5MDE0NzIsImV4cCI6MjA3MDQ3NzQ3Mn0.5ehbB4SCgeiDIBNtXBESOeAXsPuG5wBvmvfp_MiuHhc"
    static let backendBaseURL = "https://cosmic-backend-701520654148.europe-west4.run.app"

    static let matterportShowcaseURLString = bundleValue(for: "MATTERPORT_SHOWCASE_URL")
    static let matterportModelID = bundleValue(for: "MATTERPORT_MODEL_ID")
    static let matterportSDKKey = bundleValue(for: "MATTERPORT_SDK_KEY")

    static var matterportShowcaseURL: URL? {
        makeMatterportShowcaseURL(
            showcaseURLString: matterportShowcaseURLString,
            modelID: matterportModelID,
            sdkKey: matterportSDKKey
        )
    }

    static func makeMatterportShowcaseURL(
        showcaseURLString: String?,
        modelID: String?,
        sdkKey: String?
    ) -> URL? {
        if let showcaseURLString,
           let url = URL(string: showcaseURLString) {
            return url
        }

        guard let modelID else {
            return nil
        }

        var components = URLComponents(string: "https://my.matterport.com/show/")
        var queryItems = [
            URLQueryItem(name: "m", value: modelID),
            URLQueryItem(name: "search", value: "0"),
            URLQueryItem(name: "title", value: "0"),
            URLQueryItem(name: "play", value: "1"),
            URLQueryItem(name: "qs", value: "0"),
            URLQueryItem(name: "brand", value: "0"),
            URLQueryItem(name: "dh", value: "0"),
            URLQueryItem(name: "views", value: "0"),
            URLQueryItem(name: "mls", value: "2"),
            URLQueryItem(name: "tagNav", value: "0")
        ]

        if let sdkKey {
            queryItems.append(URLQueryItem(name: "applicationKey", value: sdkKey))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private static func bundleValue(for key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

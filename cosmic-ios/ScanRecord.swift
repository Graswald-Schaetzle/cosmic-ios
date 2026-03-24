import SwiftData
import Foundation

@Model
final class ScanRecord {
    var id: UUID
    var name: String
    var createdAt: Date
    var localFileURL: String
    var remoteURL: String?
    var isUploaded: Bool

    init(name: String, localFileURL: URL) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.localFileURL = localFileURL.absoluteString
        self.remoteURL = nil
        self.isUploaded = false
    }
}

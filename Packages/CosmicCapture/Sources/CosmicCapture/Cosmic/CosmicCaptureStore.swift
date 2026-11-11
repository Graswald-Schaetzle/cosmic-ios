import Foundation
import Observation
import SwiftUI

/// One saved room capture, as the host app sees it.
public struct CosmicCaptureSummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let durationSeconds: TimeInterval
    public let frameCount: Int
    /// Size of the Echo-3 bundle (images and camera files) on disk.
    public let bundleBytes: Int64
    public let thumbnailURL: URL?
    /// The room's LiDAR mesh (`.glb`), if the device recorded one.
    public let lidarMeshURL: URL?
    /// Folder with all LiDAR sidecar files (mesh, depth, metadata), if present.
    public let lidarDirectoryURL: URL?

    init(record: CaptureRecord, fileManager: FileManager = .default) {
        id = record.id
        name = record.name
        createdAt = record.createdAt
        durationSeconds = record.durationSeconds
        frameCount = record.frameCount
        bundleBytes = record.bundleBytes
        thumbnailURL = record.thumbnailURL
        let mesh = CapturePaths.lidarMesh(for: record.id)
        lidarMeshURL = fileManager.fileExists(atPath: mesh.path) ? mesh : nil
        let lidar = CapturePaths.lidarRoot(for: record.id)
        lidarDirectoryURL = fileManager.fileExists(atPath: lidar.path) ? lidar : nil
    }
}

public enum CosmicCaptureStoreError: Error, LocalizedError {
    case captureNotFound

    public var errorDescription: String? {
        "This capture is no longer on this device."
    }
}

/// The host app's handle on the captures saved on this device.
@MainActor
@Observable
public final class CosmicCaptureStore {
    let library = CaptureLibrary()

    public init() {}

    /// Whether this device can run the capture flow at all.
    public static var isCaptureSupported: Bool {
        ARCaptureCoordinator.isWorldTrackingSupported
    }

    /// Newest first.
    public var captures: [CosmicCaptureSummary] {
        library.captures.map { CosmicCaptureSummary(record: $0) }
    }

    public func refresh() async {
        await library.refresh()
    }

    public func delete(id: UUID) throws {
        try library.delete(id: id)
    }

    /// Zips the capture's Echo-3 bundle (`images/` and `cameras/` only, no
    /// LiDAR data) into a temporary file and returns its URL.
    public func makeBundleZip(id: UUID) async throws -> URL {
        guard let record = library.record(for: id) else {
            throw CosmicCaptureStoreError.captureNotFound
        }
        return try await Task.detached(priority: .userInitiated) {
            try CaptureBundleExporter.makeZip(for: record)
        }.value
    }
}

/// Full-screen capture of one room: readiness, live scan with the LiDAR
/// coverage mesh, review, and saving. Present it with `fullScreenCover`.
public struct CosmicRoomCaptureView: View {
    private let store: CosmicCaptureStore
    private let roomName: String?
    private let onSaved: (CosmicCaptureSummary) -> Void

    public init(
        store: CosmicCaptureStore,
        roomName: String? = nil,
        onSaved: @escaping (CosmicCaptureSummary) -> Void = { _ in }
    ) {
        self.store = store
        self.roomName = roomName
        self.onSaved = onSaved
    }

    public var body: some View {
        CaptureFlowView(
            library: store.library,
            initialName: roomName,
            onSaved: { record in onSaved(CosmicCaptureSummary(record: record)) }
        )
    }
}

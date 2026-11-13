import Foundation
import Observation
import CosmicCapture

/// App-wide state of the redesigned shell: the user's spaces, the space that
/// is open, the local captures and what is currently uploading or processing.
/// Owned by the root view and handed down through the environment.
@MainActor
@Observable
final class AppModel {
    private(set) var spaces: [BackendSpace] = []
    private(set) var isLoadingSpaces = false
    private(set) var spacesErrorMessage: String?

    /// The open space. Remembered across launches.
    var selectedSpaceID: Int? {
        didSet {
            if let selectedSpaceID {
                UserDefaults.standard.set(selectedSpaceID, forKey: Self.selectedSpaceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedSpaceKey)
            }
        }
    }

    let captureStore = CosmicCaptureStore()
    let uploads = RoomCaptureUploadService.shared

    private static let selectedSpaceKey = "selectedSpaceID"

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.selectedSpaceKey)
        selectedSpaceID = stored == 0 ? nil : stored
    }

    var selectedSpace: BackendSpace? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.spaceId == selectedSpaceID }
    }

    /// Loads the spaces and keeps the selection if it still exists,
    /// otherwise falls back to the first space.
    func loadSpaces() async {
        guard !isLoadingSpaces else { return }
        isLoadingSpaces = true
        spacesErrorMessage = nil
        defer { isLoadingSpaces = false }

        do {
            let fetched = try await SpaceService.shared.fetchSpaces()
            spaces = fetched
            if let selectedSpaceID, fetched.contains(where: { $0.spaceId == selectedSpaceID }) {
                return
            }
            selectedSpaceID = fetched.first?.spaceId
        } catch {
            spacesErrorMessage = error.localizedDescription
        }
    }

    /// Refreshes the processing state every 30 s while a capture is with
    /// Echo-3, so the accessory and the Captures tab notice when a room is done.
    /// Runs for the lifetime of the shell.
    func pollProcessing() async {
        while !Task.isCancelled {
            if uploads.hasProcessingCaptures {
                await uploads.refreshProcessing()
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: - Running work (bottom accessory)

    /// One capture that is uploading or processing, for the accessory bar
    /// above the tab bar.
    struct ActiveWork: Identifiable, Equatable {
        enum Kind: Equatable { case uploading, processing }

        let id: UUID
        let roomName: String
        let kind: Kind
        /// 0...1 while uploading; nil while processing (Echo-3 reports no progress).
        let progress: Double?
    }

    /// Uploads come first (the user is waiting on the device), then processing.
    var activeWork: [ActiveWork] {
        captureStore.captures.compactMap { capture -> ActiveWork? in
            guard let state = uploads.state(for: capture.id) else { return nil }
            switch state.phase {
            case .uploading:
                return ActiveWork(id: capture.id, roomName: capture.name, kind: .uploading,
                                  progress: uploads.progress[capture.id])
            case .processing:
                return ActiveWork(id: capture.id, roomName: capture.name, kind: .processing, progress: nil)
            case .completed, .failed:
                return nil
            }
        }
        .sorted { lhs, rhs in lhs.kind == .uploading && rhs.kind != .uploading }
    }
}

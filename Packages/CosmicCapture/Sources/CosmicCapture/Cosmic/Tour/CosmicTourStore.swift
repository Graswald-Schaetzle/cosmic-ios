import Foundation
import Observation

/// The capture tours on this device, one JSON file per space in
/// `Documents/CaptureTours/`. Every change is written at once, so a tour
/// survives the app being closed.
@MainActor
@Observable
public final class CosmicTourStore {
    public private(set) var tours: [Int: CaptureTour] = [:]
    /// Set when a tour could not be written; the change is still in memory.
    public private(set) var lastSaveError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureTours", isDirectory: true)
    }

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? Self.defaultDirectory
        self.fileManager = fileManager
        load()
    }

    /// The tour of a space; empty until its first room is captured.
    public func tour(for spaceID: Int) -> CaptureTour {
        tours[spaceID] ?? CaptureTour(spaceID: spaceID)
    }

    /// Changes a tour and writes it to disk.
    public func update(spaceID: Int, _ change: (inout CaptureTour) -> Void) {
        var tour = tour(for: spaceID)
        change(&tour)
        guard tour != tours[spaceID] else { return }
        tours[spaceID] = tour
        save(tour)
    }

    /// The tour room a local capture belongs to, in any space.
    public func room(forCapture captureID: UUID) -> (spaceID: Int, room: CaptureTourRoom)? {
        for (spaceID, tour) in tours {
            if let room = tour.room(forCapture: captureID) {
                return (spaceID, room)
            }
        }
        return nil
    }

    // MARK: - Files

    nonisolated static func fileName(for spaceID: Int) -> String {
        "space-\(spaceID).json"
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func load() {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = Self.makeDecoder()
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let tour = try? decoder.decode(CaptureTour.self, from: data)
            else { continue }
            tours[tour.spaceID] = tour
        }
    }

    private func save(_ tour: CaptureTour) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.makeEncoder().encode(tour)
            try data.write(
                to: directory.appendingPathComponent(Self.fileName(for: tour.spaceID)),
                options: .atomic
            )
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}

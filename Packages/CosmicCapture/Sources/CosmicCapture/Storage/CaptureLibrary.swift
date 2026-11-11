import Foundation
import Observation

/// Scans `Documents/Captures` and exposes only complete captures. Handles crash recovery on
/// launch: finalize contiguous interrupted captures, delete empty partials, never show incomplete
/// directories as valid.
@MainActor
@Observable
final class CaptureLibrary {
    private(set) var captures: [CaptureRecord] = []
    private(set) var isLoading = true
    private(set) var activeWriterIDs: Set<UUID> = []
    /// Guards against an in-flight `refresh` whose directory listing predates
    /// a delete re-adding the deleted row.
    @ObservationIgnored private var deletedIDs: Set<UUID> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var indexEntries: [UUID: CaptureLibraryIndexEntry] = [:]

    private let fileManager: FileManager
    @ObservationIgnored private let indexer: any CaptureLibraryIndexing
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        fileManager: FileManager = .default,
        indexer: (any CaptureLibraryIndexing)? = nil
    ) {
        self.fileManager = fileManager
        self.indexer = indexer ?? CaptureLibraryDiskIndexer(fileManager: fileManager)
        let preloadedEntries = self.indexer.preload()
        indexEntries = Dictionary(uniqueKeysWithValues: preloadedEntries.map {
            ($0.record.id, $0)
        })
        captures = Self.sortedRecords(from: preloadedEntries)
    }

    func markWriterActive(_ id: UUID) {
        activeWriterIDs.insert(id)
    }

    func markWriterInactive(_ id: UUID) {
        activeWriterIDs.remove(id)
    }

    func isWriting(_ id: UUID) -> Bool {
        activeWriterIDs.contains(id)
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        let indexer = indexer
        let activeWriterIDs = activeWriterIDs
        let cachedEntries = indexEntries
        var snapshot = await Task.detached(priority: .userInitiated) {
            indexer.scan(
                activeWriterIDs: activeWriterIDs,
                cachedEntries: cachedEntries
            )
        }.value

        let interruptedIDs = snapshot.interruptedIDs.filter {
            !self.activeWriterIDs.contains($0)
        }
        let cleanupCandidates = snapshot.cleanupCandidates.filter {
            $0.captureID.map { !self.activeWriterIDs.contains($0) } ?? true
        }
        if !interruptedIDs.isEmpty || !cleanupCandidates.isEmpty {
            let recovered = await Task.detached(priority: .utility) {
                indexer.reconcile(
                    interruptedIDs: interruptedIDs,
                    cleanupCandidates: cleanupCandidates
                )
            }.value
            snapshot.entries.append(contentsOf: recovered)
        }

        let entries = snapshot.entries.filter {
            !self.activeWriterIDs.contains($0.record.id)
                && !deletedIDs.contains($0.record.id)
        }
        indexEntries = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.record.id, $0)
        })
        captures = Self.sortedRecords(from: entries)
    }

    private static func sortedRecords(
        from entries: [CaptureLibraryIndexEntry]
    ) -> [CaptureRecord] {
        entries.map(\.record).sorted { lhs, rhs in
            let left = lhs.completedAt ?? lhs.createdAt
            let right = rhs.completedAt ?? rhs.createdAt
            return left > right
        }
    }

    func rename(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isWriting(id) else {
            throw CaptureLibraryError.busy
        }

        var manifest = try loadManifest(id: id)
        guard manifest.phase == .complete else {
            throw CaptureLibraryError.notComplete
        }
        manifest.name = trimmed
        manifest.updatedAt = Date()
        try writeManifest(manifest)
        if let index = captures.firstIndex(where: { $0.id == id }) {
            captures[index].name = trimmed
            indexEntries[id] = CaptureLibraryIndexEntry(
                record: captures[index],
                manifestUpdatedAt: manifest.updatedAt
            )
        }
    }

    func delete(id: UUID) throws {
        try deleteFiles(id: id)
        removeRecord(id: id)
    }

    /// Removes the capture from disk but keeps its row. SwiftUI's List crashes
    /// ("invalid number of items in section") when its data changes while a
    /// confirmation sheet, swipe action, or navigation pop is mid-transition,
    /// so UI callers call `removeRecord` once those transitions finish.
    func deleteFiles(id: UUID) throws {
        guard !isWriting(id) else {
            throw CaptureLibraryError.busy
        }
        let url = CapturePaths.captureRoot(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        deletedIDs.insert(id)
    }

    func removeRecord(id: UUID) {
        captures.removeAll { $0.id == id }
        indexEntries[id] = nil
    }

    func record(for id: UUID) -> CaptureRecord? {
        captures.first { $0.id == id }
    }

    var totalStorageBytes: Int64 {
        captures.reduce(0) { $0 + $1.storageBytes }
    }

    private func loadManifest(id: UUID) throws -> CaptureManifest {
        let data = try Data(contentsOf: CapturePaths.manifest(for: id))
        return try decoder.decode(CaptureManifest.self, from: data)
    }

    private func writeManifest(_ manifest: CaptureManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let url = CapturePaths.manifest(for: manifest.id)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

}

struct CaptureLibraryIndexEntry: Sendable {
    let record: CaptureRecord
    let manifestUpdatedAt: Date
}

struct CaptureLibraryCleanupCandidate: Sendable {
    let captureID: UUID?
    let url: URL
}

struct CaptureLibraryScanResult: Sendable {
    var entries: [CaptureLibraryIndexEntry] = []
    var interruptedIDs: [UUID] = []
    var cleanupCandidates: [CaptureLibraryCleanupCandidate] = []
}

protocol CaptureLibraryIndexing: Sendable {
    func preload() -> [CaptureLibraryIndexEntry]

    func scan(
        activeWriterIDs: Set<UUID>,
        cachedEntries: [UUID: CaptureLibraryIndexEntry]
    ) -> CaptureLibraryScanResult

    func reconcile(
        interruptedIDs: [UUID],
        cleanupCandidates: [CaptureLibraryCleanupCandidate]
    ) -> [CaptureLibraryIndexEntry]
}

extension CaptureLibraryIndexing {
    func preload() -> [CaptureLibraryIndexEntry] { [] }
}

final class CaptureLibraryDiskIndexer: CaptureLibraryIndexing, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    /// Loads only small manifests so existing rows are present before SwiftUI
    /// renders. Missing size caches are filled by the off-main scan.
    func preload() -> [CaptureLibraryIndexEntry] {
        captureDirectories().compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let manifest = try? loadManifest(id: id),
                  manifest.phase == .complete
            else {
                return nil
            }
            return makeEntry(
                from: manifest,
                measureMissingSizes: false
            )
        }
    }

    func scan(
        activeWriterIDs: Set<UUID>,
        cachedEntries: [UUID: CaptureLibraryIndexEntry]
    ) -> CaptureLibraryScanResult {
        var result = CaptureLibraryScanResult()
        for directory in captureDirectories() {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                == true
            else { continue }
            guard let id = UUID(uuidString: directory.lastPathComponent) else {
                result.cleanupCandidates.append(.init(captureID: nil, url: directory))
                continue
            }
            guard !activeWriterIDs.contains(id) else { continue }
            guard let manifest = try? loadManifest(id: id) else {
                result.cleanupCandidates.append(.init(captureID: id, url: directory))
                continue
            }
            switch manifest.phase {
            case .complete:
                if let cached = cachedEntries[id],
                   cached.manifestUpdatedAt == manifest.updatedAt
                {
                    result.entries.append(cached)
                } else if let entry = makeEntry(from: manifest) {
                    result.entries.append(entry)
                }
            case .recording, .finalizing:
                result.interruptedIDs.append(id)
            case .failed:
                break
            }
        }
        return result
    }

    func reconcile(
        interruptedIDs: [UUID],
        cleanupCandidates: [CaptureLibraryCleanupCandidate]
    ) -> [CaptureLibraryIndexEntry] {
        for candidate in cleanupCandidates {
            try? fileManager.removeItem(at: candidate.url)
        }
        return interruptedIDs.compactMap(recoverInterrupted(id:))
    }

    private func recoverInterrupted(id: UUID) -> CaptureLibraryIndexEntry? {
        guard var manifest = try? loadManifest(id: id) else {
            try? fileManager.removeItem(at: CapturePaths.captureRoot(for: id))
            return nil
        }
        guard manifest.phase == .recording || manifest.phase == .finalizing else {
            return makeEntry(from: manifest)
        }
        do {
            let writer = try CaptureBundleWriter(
                recoveringExisting: id,
                fileManager: fileManager
            )
            let finalized = try writer.finalize(
                durationSeconds: max(
                    manifest.durationSeconds,
                    Date().timeIntervalSince(manifest.startedAt)
                ),
                pathLengthM: manifest.pathLengthM,
                maxDistanceFromOriginM: manifest.maxDistanceFromOriginM
            )
            return makeEntry(from: finalized)
        } catch CaptureBundleWriterError.emptyCapture {
            try? fileManager.removeItem(at: CapturePaths.captureRoot(for: id))
        } catch {
            manifest.phase = .failed
            manifest.errorMessage = error.localizedDescription
            manifest.updatedAt = Date()
            try? writeManifest(manifest)
        }
        return nil
    }

    private func makeEntry(
        from manifest: CaptureManifest,
        measureMissingSizes: Bool = true
    ) -> CaptureLibraryIndexEntry? {
        guard manifest.phase == .complete else { return nil }
        let root = CapturePaths.captureRoot(for: manifest.id)
        let bundle = CapturePaths.bundleRoot(for: manifest.id)
        let metrics: CaptureStorageMetrics
        if let bundleBytes = manifest.bundleBytes,
           let storageBytes = manifest.storageBytes
        {
            metrics = .init(
                bundleBytes: bundleBytes,
                storageBytes: storageBytes
            )
        } else if measureMissingSizes {
            metrics = .measure(
                captureRoot: root,
                bundleRoot: bundle,
                fileManager: fileManager
            )
        } else {
            metrics = .init(bundleBytes: 0, storageBytes: 0)
        }
        let thumbnail = CapturePaths.thumbnail(for: manifest.id)
        let record = CaptureRecord(
            id: manifest.id,
            name: manifest.name,
            createdAt: manifest.createdAt,
            completedAt: manifest.completedAt,
            durationSeconds: manifest.durationSeconds,
            frameCount: manifest.frameCount,
            pathLengthM: manifest.pathLengthM,
            thumbnailURL: fileManager.fileExists(atPath: thumbnail.path)
                ? thumbnail : nil,
            rootURL: root,
            bundleURL: bundle,
            bundleBytes: metrics.bundleBytes,
            storageBytes: metrics.storageBytes
        )
        return CaptureLibraryIndexEntry(
            record: record,
            manifestUpdatedAt: manifest.updatedAt
        )
    }

    private func captureDirectories() -> [URL] {
        let root = CapturePaths.capturesRoot
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func loadManifest(id: UUID) throws -> CaptureManifest {
        let data = try Data(contentsOf: CapturePaths.manifest(for: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureManifest.self, from: data)
    }

    private func writeManifest(_ manifest: CaptureManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(
            to: CapturePaths.manifest(for: manifest.id),
            options: .atomic
        )
    }
}

struct CaptureStorageMetrics: Sendable, Equatable {
    let bundleBytes: Int64
    let storageBytes: Int64

    static func measure(
        captureRoot: URL,
        bundleRoot: URL,
        fileManager: FileManager = .default
    ) -> CaptureStorageMetrics {
        guard let enumerator = fileManager.enumerator(
            at: captureRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .init(bundleBytes: 0, storageBytes: 0)
        }
        let bundlePrefix = bundleRoot.standardizedFileURL.path + "/"
        var bundleBytes: Int64 = 0
        var storageBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true
            else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            storageBytes += bytes
            if fileURL.standardizedFileURL.path.hasPrefix(bundlePrefix) {
                bundleBytes += bytes
            }
        }
        return .init(bundleBytes: bundleBytes, storageBytes: storageBytes)
    }

    static func itemSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }
        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        return measure(
            captureRoot: url,
            bundleRoot: url,
            fileManager: fileManager
        ).storageBytes
    }
}

enum CaptureLibraryError: Error, LocalizedError {
    case busy
    case notComplete

    var errorDescription: String? {
        switch self {
        case .busy:
            return "This scan is still being written."
        case .notComplete:
            return "Only finished scans can be renamed."
        }
    }
}

enum CaptureStorageProbe {
    /// Returns available bytes for important usage, or nil if unavailable.
    static func availableBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func hasEnoughStorage(requiredBytes: Int64 = CapturePaths.estimatedMaxCaptureBytes) -> Bool {
        guard let available = availableBytes() else {
            // Fail open if the system cannot report capacity; mid-capture write errors still protect us.
            return true
        }
        return available >= requiredBytes
    }

    static func freeGigabytesLabel() -> String {
        guard let available = availableBytes() else { return "—" }
        let gb = Double(available) / 1_000_000_000
        if gb >= 10 {
            return String(format: "%.0f GB free on this \(CaptureDevice.name)", gb)
        }
        return String(format: "%.1f GB free on this \(CaptureDevice.name)", gb)
    }
}

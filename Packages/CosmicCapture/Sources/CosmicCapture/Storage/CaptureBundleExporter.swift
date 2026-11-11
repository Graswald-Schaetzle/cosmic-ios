import Foundation

enum CaptureBundleExporterError: Error, LocalizedError {
    case missingBundle
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "This scan has no bundle on disk."
        case let .zipFailed(reason):
            return "Couldn't create the zip: \(reason)"
        }
    }
}

/// Zips a finished capture's `bundle/` directory for sharing.
///
/// The zip holds a single top-level `bundle/` folder (`bundle/images/...`,
/// `bundle/cameras/...`). One wrapper folder is tolerated, so this zip is a
/// valid `capture_bundle` as is.
enum CaptureBundleExporter {
    static func exportsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Writes `<name>.zip` into the temporary exports directory and returns its URL.
    ///
    /// `NSFileCoordinator` with `.forUploading` produces a zip of a directory
    /// without a third-party dependency. The coordinator's zip is deleted
    /// when the accessor returns, so it is copied out first.
    static func makeZip(
        for record: CaptureRecord,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard fileManager.fileExists(atPath: record.bundleURL.path) else {
            throw CaptureBundleExporterError.missingBundle
        }
        let root = exportsRoot(fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(safeFileName(record.name)).zip")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: record.bundleURL,
            options: .forUploading,
            error: &coordinationError
        ) { zipURL in
            do {
                try fileManager.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw CaptureBundleExporterError.zipFailed(error.localizedDescription)
        }
        return destination
    }

    /// Removes stale zips from earlier share sessions.
    static func clearExports(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: exportsRoot(fileManager: fileManager))
    }

    static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "capture" : cleaned
    }
}

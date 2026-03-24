import Foundation

/// Creates a ZIP archive from a LiDAR scan directory containing frames/ and transforms.json.
/// Uses STORE method (no compression) — JPEG files are already compressed, so deflating
/// them again would not reduce size and avoids requiring any external library.
///
/// The resulting ZIP is suitable for uploading directly to GCS via a signed PUT URL.
/// The backend pipeline worker detects the presence of transforms.json inside the ZIP
/// to decide whether to skip COLMAP.
enum ScanPackager {

    /// Creates a ZIP file at `outputURL` containing all JPEG frames and transforms.json
    /// found in `scanDirectory`.
    ///
    /// - Parameters:
    ///   - scanDirectory: The scan directory produced by LiDARCaptureService (contains frames/ + transforms.json).
    ///   - outputURL: Destination URL for the output ZIP file.
    /// - Returns: The output URL (same as `outputURL`).
    static func createZip(scanDirectory: URL, outputURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.buildZip(scanDirectory: scanDirectory, outputURL: outputURL)
            return outputURL
        }.value
    }

    // MARK: - ZIP Builder

    private static func buildZip(scanDirectory: URL, outputURL: URL) throws {
        let fm = FileManager.default

        // Collect entries: transforms.json first, then all frames
        var entries: [(path: String, url: URL)] = []

        let jsonURL = scanDirectory.appendingPathComponent("transforms.json")
        guard fm.fileExists(atPath: jsonURL.path) else {
            throw PackagerError.missingTransformsJSON
        }
        entries.append(("transforms.json", jsonURL))

        let framesDir = scanDirectory.appendingPathComponent("frames")
        if fm.fileExists(atPath: framesDir.path) {
            let frameFiles = try fm.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)
            let sorted = frameFiles
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in sorted {
                entries.append(("frames/\(f.lastPathComponent)", f))
            }
        }

        guard !entries.isEmpty else { throw PackagerError.noFilesToPackage }

        // Remove existing output file if present
        try? fm.removeItem(at: outputURL)
        fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        // Central directory records (offset + metadata for each file)
        struct CDEntry {
            let filename: String
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
            let dosDate: UInt16
            let dosTime: UInt16
        }
        var cdEntries: [CDEntry] = []

        let (dosDate, dosTime) = currentDOSDateTime()

        // Write local file header + data for each entry
        for entry in entries {
            let data: Data
            do {
                data = try Data(contentsOf: entry.url)
            } catch {
                throw PackagerError.fileReadFailed(entry.url.lastPathComponent)
            }

            let crc    = crc32(data)
            let offset = UInt32(handle.offsetInFile)
            let fnData = entry.path.data(using: .utf8) ?? Data()

            // Local File Header
            var lhdr = Data()
            lhdr.appendUInt32(0x04034B50)         // signature
            lhdr.appendUInt16(20)                 // version needed (2.0)
            lhdr.appendUInt16(0)                  // general purpose bit flag
            lhdr.appendUInt16(0)                  // compression method: STORE
            lhdr.appendUInt16(dosTime)
            lhdr.appendUInt16(dosDate)
            lhdr.appendUInt32(crc)
            lhdr.appendUInt32(UInt32(data.count)) // compressed size = uncompressed (STORE)
            lhdr.appendUInt32(UInt32(data.count)) // uncompressed size
            lhdr.appendUInt16(UInt16(fnData.count))
            lhdr.appendUInt16(0)                  // extra field length
            lhdr.append(fnData)
            handle.write(lhdr)
            handle.write(data)

            cdEntries.append(CDEntry(
                filename: entry.path,
                crc32: crc,
                size: UInt32(data.count),
                localHeaderOffset: offset,
                dosDate: dosDate,
                dosTime: dosTime
            ))
        }

        // Write Central Directory
        let cdOffset = UInt32(handle.offsetInFile)
        var cdSize: UInt32 = 0

        for entry in cdEntries {
            let fnData = entry.filename.data(using: .utf8) ?? Data()
            var cdhdr = Data()
            cdhdr.appendUInt32(0x02014B50)         // signature
            cdhdr.appendUInt16(20)                 // version made by
            cdhdr.appendUInt16(20)                 // version needed
            cdhdr.appendUInt16(0)                  // general purpose bit flag
            cdhdr.appendUInt16(0)                  // compression method: STORE
            cdhdr.appendUInt16(entry.dosTime)
            cdhdr.appendUInt16(entry.dosDate)
            cdhdr.appendUInt32(entry.crc32)
            cdhdr.appendUInt32(entry.size)         // compressed = uncompressed
            cdhdr.appendUInt32(entry.size)
            cdhdr.appendUInt16(UInt16(fnData.count))
            cdhdr.appendUInt16(0)                  // extra field length
            cdhdr.appendUInt16(0)                  // file comment length
            cdhdr.appendUInt16(0)                  // disk number start
            cdhdr.appendUInt16(0)                  // internal attributes
            cdhdr.appendUInt32(0)                  // external attributes
            cdhdr.appendUInt32(entry.localHeaderOffset)
            cdhdr.append(fnData)
            handle.write(cdhdr)
            cdSize += UInt32(cdhdr.count)
        }

        // End of Central Directory Record
        var eocd = Data()
        eocd.appendUInt32(0x06054B50)
        eocd.appendUInt16(0)                       // disk number
        eocd.appendUInt16(0)                       // disk with CD start
        eocd.appendUInt16(UInt16(cdEntries.count))
        eocd.appendUInt16(UInt16(cdEntries.count))
        eocd.appendUInt32(cdSize)
        eocd.appendUInt32(cdOffset)
        eocd.appendUInt16(0)                       // comment length
        handle.write(eocd)
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    // MARK: - DOS Date/Time

    private static func currentDOSDateTime() -> (date: UInt16, time: UInt16) {
        let cal  = Calendar.current
        let now  = Date()
        let year = cal.component(.year, from: now)
        let mon  = cal.component(.month, from: now)
        let day  = cal.component(.day, from: now)
        let hr   = cal.component(.hour, from: now)
        let min  = cal.component(.minute, from: now)
        let sec  = cal.component(.second, from: now)
        let dosDate = UInt16(((year - 1980) << 9) | (mon << 5) | day)
        let dosTime = UInt16((hr << 11) | (min << 5) | (sec / 2))
        return (dosDate, dosTime)
    }
}

// MARK: - Errors

enum PackagerError: LocalizedError {
    case missingTransformsJSON
    case noFilesToPackage
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTransformsJSON:    return "transforms.json nicht gefunden."
        case .noFilesToPackage:         return "Keine Dateien zum Verpacken gefunden."
        case .fileReadFailed(let name): return "Datei konnte nicht gelesen werden: \(name)"
        }
    }
}

// MARK: - Data Extensions

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }
}

private extension FileHandle {
    var offsetInFile: UInt64 {
        (try? offset()) ?? 0
    }
}

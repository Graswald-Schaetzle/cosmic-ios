import Foundation
import simd

/// App-local lifecycle for a capture. Only `.complete` captures appear in the library.
enum CapturePhase: String, Codable, Sendable, Hashable {
    case recording
    case finalizing
    case complete
    case failed
}

/// Sidecar metadata that must never be written into `bundle/`.
struct CaptureManifest: Codable, Sendable, Hashable {
    var id: UUID
    var schemaVersion: Int
    var name: String
    var phase: CapturePhase
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date
    var completedAt: Date?
    var durationSeconds: TimeInterval
    var frameCount: Int
    var pathLengthM: Float
    var maxDistanceFromOriginM: Float
    var errorMessage: String?
    var videoFormatDescription: String?
    var selectedLens: String?
    var deviceModel: String?
    var cameraOrientation: CaptureCameraOrientation?
    var representativeThumbnailVersion: Int?
    /// Cached final sizes keep library navigation from walking thousands of files.
    var bundleBytes: Int64?
    var storageBytes: Int64?

    static let currentSchemaVersion = 1
    static let currentRepresentativeThumbnailVersion = 3

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion = "schema_version"
        case name
        case phase
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case frameCount = "frame_count"
        case pathLengthM = "path_length_m"
        case maxDistanceFromOriginM = "max_distance_from_origin_m"
        case errorMessage = "error_message"
        case videoFormatDescription = "video_format_description"
        case selectedLens = "selected_lens"
        case deviceModel = "device_model"
        case cameraOrientation = "camera_orientation"
        case representativeThumbnailVersion = "representative_thumbnail_version"
        case bundleBytes = "bundle_bytes"
        case storageBytes = "storage_bytes"
    }

    static func makeNew(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        videoFormatDescription: String?,
        selectedLens: String?,
        deviceModel: String?
    ) -> CaptureManifest {
        CaptureManifest(
            id: id,
            schemaVersion: currentSchemaVersion,
            name: name,
            phase: .recording,
            createdAt: startedAt,
            updatedAt: startedAt,
            startedAt: startedAt,
            completedAt: nil,
            durationSeconds: 0,
            frameCount: 0,
            pathLengthM: 0,
            maxDistanceFromOriginM: 0,
            errorMessage: nil,
            videoFormatDescription: videoFormatDescription,
            selectedLens: selectedLens,
            deviceModel: deviceModel,
            cameraOrientation: nil,
            representativeThumbnailVersion: nil,
            bundleBytes: nil,
            storageBytes: nil
        )
    }
}

/// Per-frame app-local record written incrementally during capture.
struct CaptureFrameRecord: Codable, Sendable, Hashable {
    var frameIndex: Int
    var arkitWorldFromCamera: [[Double]]
    var fxPx: Double
    var fyPx: Double
    var cxPx: Double
    var cyPx: Double
    var widthPx: Int
    var heightPx: Int
    var sampleReason: String

    enum CodingKeys: String, CodingKey {
        case frameIndex = "frame_index"
        case arkitWorldFromCamera = "arkit_world_from_camera"
        case fxPx = "fx_px"
        case fyPx = "fy_px"
        case cxPx = "cx_px"
        case cyPx = "cy_px"
        case widthPx = "width_px"
        case heightPx = "height_px"
        case sampleReason = "sample_reason"
    }
}

/// Ordered camera calibration for every accepted frame.
///
/// Parallel-array entry `i` corresponds to trajectory entry `i` and
/// `images/Image_%06d.jpg` with one-based image index `i + 1`. Resolution is
/// shared because accepted capture frames are always the same size.
struct CapturePerFrameIntrinsicsExport: Codable, Sendable, Hashable {
    var frameCount: Int
    var widthPx: Int
    var heightPx: Int
    var fxPx: [Double]
    var fyPx: [Double]
    var cxPx: [Double]
    var cyPx: [Double]

    enum CodingKeys: String, CodingKey {
        case frameCount = "frame_count"
        case widthPx = "width_px"
        case heightPx = "height_px"
        case fxPx = "fx_px"
        case fyPx = "fy_px"
        case cxPx = "cx_px"
        case cyPx = "cy_px"
    }
}

/// A complete capture visible in the library.
struct CaptureRecord: Identifiable, Sendable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var completedAt: Date?
    var durationSeconds: TimeInterval
    var frameCount: Int
    var pathLengthM: Float
    var thumbnailURL: URL?
    var rootURL: URL
    var bundleURL: URL
    var bundleBytes: Int64
    var storageBytes: Int64

    var formattedDuration: String {
        CaptureFormatting.duration(durationSeconds)
    }

    var formattedDate: String {
        CaptureFormatting.shortDate(createdAt)
    }

    var formattedTime: String {
        CaptureFormatting.shortTime(createdAt)
    }

    var formattedStorageSize: String {
        CaptureFormatting.byteCount(storageBytes)
    }

    var formattedBundleSize: String {
        CaptureFormatting.byteCount(bundleBytes)
    }
}

enum CaptureFormatting {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(.current))
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(.current))
    }

    static func automaticName(
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return "Scan · \(formatter.string(from: now))"
    }

    /// True while a scan still carries the name `automaticName` gave it.
    /// The date part is localized, so only the constant prefix is checked.
    static func isAutomaticName(_ name: String) -> Bool {
        name.hasPrefix("Scan · ")
    }

    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

extension simd_float4x4 {
    var rowMajorArray: [[Double]] {
        [
            [Double(columns.0.x), Double(columns.1.x), Double(columns.2.x), Double(columns.3.x)],
            [Double(columns.0.y), Double(columns.1.y), Double(columns.2.y), Double(columns.3.y)],
            [Double(columns.0.z), Double(columns.1.z), Double(columns.2.z), Double(columns.3.z)],
            [Double(columns.0.w), Double(columns.1.w), Double(columns.2.w), Double(columns.3.w)],
        ]
    }

    static func fromRowMajor(_ rows: [[Double]]) -> simd_float4x4? {
        guard rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else { return nil }
        return simd_float4x4(
            SIMD4(Float(rows[0][0]), Float(rows[1][0]), Float(rows[2][0]), Float(rows[3][0])),
            SIMD4(Float(rows[0][1]), Float(rows[1][1]), Float(rows[2][1]), Float(rows[3][1])),
            SIMD4(Float(rows[0][2]), Float(rows[1][2]), Float(rows[2][2]), Float(rows[3][2])),
            SIMD4(Float(rows[0][3]), Float(rows[1][3]), Float(rows[2][3]), Float(rows[3][3]))
        )
    }
}

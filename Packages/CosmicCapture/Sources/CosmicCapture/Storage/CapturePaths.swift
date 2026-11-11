import Foundation

/// On-disk layout for a single capture.
///
/// `bundle/` holds exactly the files the Echo-3 capture contract requires;
/// zip that folder to export it. Everything the scans list and detail need
/// (name, dates, duration, thumbnail, crash recovery) lives under `local/`
/// and is never exported.
///
/// ```
/// Documents/Captures/<id>/
/// ├── bundle/
/// │   ├── images/Image_000001.jpg   ← ARKit EXIF embedded
/// │   └── cameras/{camera_trajectory.json,per_frame_intrinsics.json}
/// └── local/
///     ├── manifest.json
///     ├── frame-records/Frame_000001.json
///     └── thumbnail.jpg
/// ```
enum CapturePaths {
    static let requiredWidth = 1920
    static let requiredHeight = 1440
    static let maxFrames = 5_000
    /// Conservative estimate used for pre-capture storage checks (~400 KB/frame + margin).
    static let estimatedBytesPerFrame: Int64 = 400_000
    static let estimatedMaxCaptureBytes: Int64 =
        Int64(maxFrames) * estimatedBytesPerFrame + 50_000_000

    static let capturesRoot: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }()

    static func captureRoot(for id: UUID) -> URL {
        capturesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func bundleRoot(for id: UUID) -> URL {
        captureRoot(for: id).appendingPathComponent("bundle", isDirectory: true)
    }

    static func localRoot(for id: UUID) -> URL {
        captureRoot(for: id).appendingPathComponent("local", isDirectory: true)
    }

    static func imagesDir(for id: UUID) -> URL {
        bundleRoot(for: id).appendingPathComponent("images", isDirectory: true)
    }

    static func camerasDir(for id: UUID) -> URL {
        bundleRoot(for: id).appendingPathComponent("cameras", isDirectory: true)
    }

    static func frameRecordsDir(for id: UUID) -> URL {
        localRoot(for: id).appendingPathComponent("frame-records", isDirectory: true)
    }

    static func manifest(for id: UUID) -> URL {
        localRoot(for: id).appendingPathComponent("manifest.json")
    }

    static func thumbnail(for id: UUID) -> URL {
        localRoot(for: id).appendingPathComponent("thumbnail.jpg")
    }

    static func trajectory(for id: UUID) -> URL {
        camerasDir(for: id).appendingPathComponent("camera_trajectory.json")
    }

    static func perFrameIntrinsics(for id: UUID) -> URL {
        camerasDir(for: id).appendingPathComponent("per_frame_intrinsics.json")
    }

    /// One-based, zero-padded, contiguous — matches `images/Image_%06d.jpg`.
    static func imageFilename(index: Int) -> String {
        String(format: "Image_%06d.jpg", index)
    }

    static func image(for id: UUID, index: Int) -> URL {
        imagesDir(for: id).appendingPathComponent(imageFilename(index: index))
    }

    static func frameRecordFilename(index: Int) -> String {
        String(format: "Frame_%06d.json", index)
    }

    static func frameRecord(for id: UUID, index: Int) -> URL {
        frameRecordsDir(for: id).appendingPathComponent(frameRecordFilename(index: index))
    }

    static func relativeBundleImagePath(index: Int) -> String {
        "images/\(imageFilename(index: index))"
    }

    static let relativeTrajectoryPath = "cameras/camera_trajectory.json"
    static let relativePerFrameIntrinsicsPath = "cameras/per_frame_intrinsics.json"

    /// Every bundle-relative path the contract expects: the images, then the
    /// two camera files.
    static func bundleFilePaths(frameCount: Int) -> [String] {
        let images = (1...frameCount).map(relativeBundleImagePath(index:))
        return images + [relativeTrajectoryPath, relativePerFrameIntrinsicsPath]
    }

    static func bundleFile(for id: UUID, relativePath: String) -> URL {
        bundleRoot(for: id).appending(path: relativePath)
    }
}

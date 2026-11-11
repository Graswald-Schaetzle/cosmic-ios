import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import UIKit
import UniformTypeIdentifiers

enum CaptureBundleWriterError: Error, LocalizedError, Sendable, Equatable {
    case directoryCreateFailed
    case frameBufferingFailed
    case jpegEncodeFailed
    case invalidImageResolution(width: Int, height: Int)
    case writeFailed(String)
    case emptyCapture
    case validationFailed([CaptureValidationIssue])
    case frameLimitReached
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .directoryCreateFailed:
            return "Couldn't create the scan folder."
        case .frameBufferingFailed:
            return "Camera frame buffering failed. Start a new scan and try again."
        case .jpegEncodeFailed:
            return "Couldn't encode a camera frame."
        case .invalidImageResolution(let width, let height):
            return "Camera frame was \(width)×\(height). The bundle contract needs 1920×1440."
        case .writeFailed(let message):
            return message
        case .emptyCapture:
            return "No frames were saved."
        case .validationFailed(let issues):
            return issues.first?.message ?? "Scan validation failed."
        case .frameLimitReached:
            return "This scan reached its capture limit."
        case .insufficientStorage:
            return "This \(CaptureDevice.name) is out of storage."
        }
    }
}

/// Motion stats committed alongside a frame so count and stats share one
/// atomic manifest write.
struct CaptureMotionStatsUpdate: Sendable {
    let pathLengthM: Float
    let maxDistanceFromOriginM: Float
    let durationSeconds: TimeInterval
}

struct PendingCaptureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let arkitWorldFromCamera: simd_float4x4
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Int
    let height: Int
    let sampleReason: String
    /// Binary plist of `ARFrame.exifData`, embedded into the JPEG.
    let exifPropertyListData: Data?

    init(
        pixelBuffer: CVPixelBuffer,
        arkitWorldFromCamera: simd_float4x4,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        width: Int,
        height: Int,
        sampleReason: String,
        exifPropertyListData: Data? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.arkitWorldFromCamera = arkitWorldFromCamera
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
        self.sampleReason = sampleReason
        self.exifPropertyListData = exifPropertyListData
    }
}

/// Crash-safe writer.
///
/// Protocol per accepted frame:
/// 1. Encode + verify JPEG at 1920×1440
/// 2. Assign next one-based index
/// 3. Atomically write image + frame-record
/// 4. Bump manifest.frameCount
///
/// Incomplete captures never appear in the library. Finalization rebuilds the contract
/// cameras JSON from frame-records so a mid-scan crash remains recoverable.
final class CaptureBundleWriter: @unchecked Sendable {
    let id: UUID
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "capture.bundle-writer")
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    private let jpegQuality: CGFloat = 0.85
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private var manifest: CaptureManifest
    private var isAcceptingFrames = true
    private var didWriteThumbnail = false
    private var lastError: CaptureBundleWriterError?

    var committedFrameCount: Int {
        queue.sync { manifest.frameCount }
    }

    var currentManifest: CaptureManifest {
        queue.sync { manifest }
    }

    init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        videoFormatDescription: String?,
        selectedLens: String?,
        deviceModel: String?,
        fileManager: FileManager = .default
    ) throws {
        self.id = id
        self.fileManager = fileManager
        self.manifest = .makeNew(
            id: id,
            name: name,
            startedAt: startedAt,
            videoFormatDescription: videoFormatDescription,
            selectedLens: selectedLens,
            deviceModel: deviceModel
        )
        try createDirectories()
        try writeManifest(manifest)
    }

    /// Recovers an interrupted capture directory for finalization or cleanup.
    init(recoveringExisting id: UUID, fileManager: FileManager = .default) throws {
        self.id = id
        self.fileManager = fileManager
        let data = try Data(contentsOf: CapturePaths.manifest(for: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.manifest = try decoder.decode(CaptureManifest.self, from: data)
        self.isAcceptingFrames = false
    }

    /// Appends a frame and, when provided, folds the motion stats into the
    /// same atomic manifest write as the frame count. This halves manifest
    /// I/O per committed frame versus a separate `updateMotionStats` call,
    /// and crash recovery still sees count and stats move together.
    func append(
        _ frame: PendingCaptureFrame,
        motionStats: CaptureMotionStatsUpdate? = nil
    ) throws -> Int {
        try queue.sync {
            guard isAcceptingFrames else {
                throw lastError ?? CaptureBundleWriterError.writeFailed("Scan is no longer accepting frames.")
            }
            guard manifest.frameCount < CapturePaths.maxFrames else {
                isAcceptingFrames = false
                lastError = .frameLimitReached
                throw CaptureBundleWriterError.frameLimitReached
            }
            guard frame.width == CapturePaths.requiredWidth,
                  frame.height == CapturePaths.requiredHeight
            else {
                isAcceptingFrames = false
                lastError = .invalidImageResolution(width: frame.width, height: frame.height)
                throw CaptureBundleWriterError.invalidImageResolution(
                    width: frame.width,
                    height: frame.height
                )
            }

            guard let jpeg = autoreleasepool(invoking: {
                jpegData(
                    from: frame.pixelBuffer,
                    exifPropertyListData: frame.exifPropertyListData
                )
            }) else {
                isAcceptingFrames = false
                lastError = .jpegEncodeFailed
                throw CaptureBundleWriterError.jpegEncodeFailed
            }

            let nextIndex = manifest.frameCount + 1
            let imageURL = CapturePaths.image(for: id, index: nextIndex)
            let recordURL = CapturePaths.frameRecord(for: id, index: nextIndex)

            do {
                try atomicWrite(jpeg, to: imageURL)
                let record = CaptureFrameRecord(
                    frameIndex: nextIndex,
                    arkitWorldFromCamera: frame.arkitWorldFromCamera.rowMajorArray,
                    fxPx: Double(frame.fx),
                    fyPx: Double(frame.fy),
                    cxPx: Double(frame.cx),
                    cyPx: Double(frame.cy),
                    widthPx: frame.width,
                    heightPx: frame.height,
                    sampleReason: frame.sampleReason
                )
                try atomicWrite(encoder.encode(record), to: recordURL)

                if !didWriteThumbnail {
                    // The first-frame preview is app-local decoration. Finalization
                    // replaces it with a representative contact sheet, so failure
                    // here must not reject an otherwise valid image/pose pair.
                    try? writeThumbnail(from: frame.pixelBuffer)
                    didWriteThumbnail = true
                }

                manifest.frameCount = nextIndex
                if let motionStats {
                    manifest.pathLengthM = motionStats.pathLengthM
                    manifest.maxDistanceFromOriginM =
                        motionStats.maxDistanceFromOriginM
                    manifest.durationSeconds = motionStats.durationSeconds
                }
                manifest.updatedAt = Date()
                try writeManifest(manifest)
                return nextIndex
            } catch {
                try? fileManager.removeItem(at: imageURL)
                try? fileManager.removeItem(at: recordURL)
                isAcceptingFrames = false
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileWriteOutOfSpaceError
                {
                    lastError = .insufficientStorage
                    throw CaptureBundleWriterError.insufficientStorage
                }
                lastError = .writeFailed(error.localizedDescription)
                throw CaptureBundleWriterError.writeFailed(error.localizedDescription)
            }
        }
    }

    func stopAcceptingFrames(
        because error: CaptureBundleWriterError? = nil
    ) {
        queue.sync {
            isAcceptingFrames = false
            if let error {
                lastError = error
            }
        }
    }

    func updateMotionStats(pathLengthM: Float, maxDistanceFromOriginM: Float, durationSeconds: TimeInterval) {
        queue.sync {
            manifest.pathLengthM = pathLengthM
            manifest.maxDistanceFromOriginM = maxDistanceFromOriginM
            manifest.durationSeconds = durationSeconds
            manifest.updatedAt = Date()
            try? writeManifest(manifest)
        }
    }

    func rename(_ name: String) throws {
        try queue.sync {
            manifest.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            manifest.updatedAt = Date()
            try writeManifest(manifest)
        }
    }

    @discardableResult
    func finalize(durationSeconds: TimeInterval, pathLengthM: Float, maxDistanceFromOriginM: Float) throws -> CaptureManifest {
        try queue.sync {
            isAcceptingFrames = false
            manifest.phase = .finalizing
            manifest.durationSeconds = durationSeconds
            manifest.pathLengthM = pathLengthM
            manifest.maxDistanceFromOriginM = maxDistanceFromOriginM
            manifest.updatedAt = Date()
            try writeManifest(manifest)

            let committed = try committedFramePairCount()
            guard committed > 0 else {
                let error = lastError ?? CaptureBundleWriterError.emptyCapture
                manifest.phase = .failed
                manifest.errorMessage = error.localizedDescription
                try writeManifest(manifest)
                throw error
            }

            // Drop orphan tail files beyond the contiguous committed prefix.
            try pruneOrphans(keeping: committed)
            manifest.frameCount = committed

            let records = try loadFrameRecords(count: committed)
            let opencvPoses = try records.map { record -> simd_float4x4 in
                guard let arkit = simd_float4x4.fromRowMajor(record.arkitWorldFromCamera) else {
                    throw CaptureBundleWriterError.writeFailed("Corrupt pose for frame \(record.frameIndex)")
                }
                return CameraGeometry.opencvCameraFromWorld(arkitWorldFromCamera: arkit)
            }
            let trajectory = opencvPoses.map(\.rowMajorArray)
            let orientation = CameraGeometry.voteHoldOrientation(
                opencvCameraFromWorld: opencvPoses
            )

            let trajectoryData = try JSONSerialization.data(
                withJSONObject: trajectory,
                options: [.prettyPrinted, .sortedKeys]
            )
            try atomicWrite(trajectoryData, to: CapturePaths.trajectory(for: id))
            let perFrameIntrinsics = CapturePerFrameIntrinsicsExport(
                frameCount: records.count,
                widthPx: CapturePaths.requiredWidth,
                heightPx: CapturePaths.requiredHeight,
                fxPx: records.map(\.fxPx),
                fyPx: records.map(\.fyPx),
                cxPx: records.map(\.cxPx),
                cyPx: records.map(\.cyPx)
            )
            try atomicWrite(
                encoder.encode(perFrameIntrinsics),
                to: CapturePaths.perFrameIntrinsics(for: id)
            )
            // `orientation.json` is optional and omitted. The app keeps the
            // hold vote locally to rotate the thumbnail.
            manifest.cameraOrientation = orientation
            do {
                try CaptureThumbnailRenderer.writeDisplayContactSheet(
                    fromSensorJPEGs: CaptureRepresentativeFrames.imageURLs(
                        captureID: id,
                        frameCount: committed
                    ),
                    orientation: orientation,
                    to: CapturePaths.thumbnail(for: id)
                )
                manifest.schemaVersion = CaptureManifest.currentSchemaVersion
                manifest.representativeThumbnailVersion =
                    CaptureManifest.currentRepresentativeThumbnailVersion
            } catch {
                // The persisted capture is valid even if its decorative local
                // thumbnail cannot be refreshed.
            }
            didWriteThumbnail = true

            let validation = CaptureBundleValidator.validateBundle(
                at: CapturePaths.bundleRoot(for: id),
                frameCount: committed
            )
            guard validation.isValid else {
                manifest.phase = .failed
                manifest.errorMessage = validation.issues.first?.message
                try writeManifest(manifest)
                throw CaptureBundleWriterError.validationFailed(validation.issues)
            }

            manifest.phase = .complete
            manifest.completedAt = Date()
            manifest.updatedAt = Date()
            manifest.errorMessage = nil
            manifest.schemaVersion = CaptureManifest.currentSchemaVersion
            let metrics = CaptureStorageMetrics.measure(
                captureRoot: CapturePaths.captureRoot(for: id),
                bundleRoot: CapturePaths.bundleRoot(for: id),
                fileManager: fileManager
            )
            manifest.bundleBytes = metrics.bundleBytes
            manifest.storageBytes = metrics.storageBytes
            try writeManifest(manifest)
            return manifest
        }
    }

    // MARK: - Private

    private func createDirectories() throws {
        let dirs = [
            CapturePaths.captureRoot(for: id),
            CapturePaths.bundleRoot(for: id),
            CapturePaths.localRoot(for: id),
            CapturePaths.imagesDir(for: id),
            CapturePaths.camerasDir(for: id),
            CapturePaths.frameRecordsDir(for: id),
        ]
        for dir in dirs {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw CaptureBundleWriterError.directoryCreateFailed
            }
        }
    }

    private func writeManifest(_ manifest: CaptureManifest) throws {
        try atomicWrite(encoder.encode(manifest), to: CapturePaths.manifest(for: id))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: temp.path) {
            try? fileManager.removeItem(at: temp)
        }
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    private func jpegData(
        from pixelBuffer: CVPixelBuffer,
        exifPropertyListData: Data? = nil
    ) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ]
        if let exifPropertyListData,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: exifPropertyListData,
               options: [],
               format: nil
           ),
           let exif = propertyList as? [String: Any]
        {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func writeThumbnail(from pixelBuffer: CVPixelBuffer) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let thumb = makeThumbnail(from: cgImage, width: 512)
        else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumb,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        try atomicWrite(data as Data, to: CapturePaths.thumbnail(for: id))
    }

    private func makeThumbnail(from image: CGImage, width: Int) -> CGImage? {
        let scale = CGFloat(width) / CGFloat(image.width)
        let height = Int(CGFloat(image.height) * scale)
        guard let space = image.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func committedFramePairCount() throws -> Int {
        var count = 0
        while true {
            let next = count + 1
            let imageExists = fileManager.fileExists(atPath: CapturePaths.image(for: id, index: next).path)
            let recordExists = fileManager.fileExists(atPath: CapturePaths.frameRecord(for: id, index: next).path)
            if imageExists && recordExists {
                count = next
                continue
            }
            break
        }
        return count
    }

    private func pruneOrphans(keeping count: Int) throws {
        try pruneNumberedFiles(
            in: CapturePaths.imagesDir(for: id),
            prefix: "Image_",
            suffix: ".jpg",
            keeping: count
        )
        try pruneNumberedFiles(
            in: CapturePaths.frameRecordsDir(for: id),
            prefix: "Frame_",
            suffix: ".json",
            keeping: count
        )
    }

    private func pruneNumberedFiles(
        in directory: URL,
        prefix: String,
        suffix: String,
        keeping count: Int
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let numberString = String(
                name.dropFirst(prefix.count).dropLast(suffix.count)
            )
            if let number = Int(numberString), number > count {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func loadFrameRecords(count: Int) throws -> [CaptureFrameRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [CaptureFrameRecord] = []
        records.reserveCapacity(count)
        for index in 1...count {
            let data = try Data(contentsOf: CapturePaths.frameRecord(for: id, index: index))
            let record = try decoder.decode(CaptureFrameRecord.self, from: data)
            records.append(record)
        }
        return records
    }
}

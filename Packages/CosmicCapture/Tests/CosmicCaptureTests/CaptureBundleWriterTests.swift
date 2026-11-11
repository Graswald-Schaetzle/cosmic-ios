import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd
import Testing
import UIKit
@testable import CosmicCapture

@Suite("CaptureBundleWriter")
struct CaptureBundleWriterTests {
    @Test("Writer preserves one canonical capture start date")
    func canonicalStartDate() throws {
        let startedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let writer = try CaptureBundleWriter(
            name: "Scan · May 2, 3:09 PM",
            startedAt: startedAt,
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        #expect(writer.currentManifest.name == "Scan · May 2, 3:09 PM")
        #expect(writer.currentManifest.createdAt == startedAt)
        #expect(writer.currentManifest.startedAt == startedAt)
        #expect(writer.currentManifest.updatedAt == startedAt)
    }

    @Test("Legacy manifests decode without thumbnail metadata")
    func legacyManifestDecode() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "schema_version": 1,
              "name": "Legacy scan",
              "phase": "complete",
              "created_at": "2026-08-20T10:00:00Z",
              "updated_at": "2026-08-20T10:01:00Z",
              "started_at": "2026-08-20T10:00:00Z",
              "completed_at": "2026-08-20T10:01:00Z",
              "duration_seconds": 60,
              "frame_count": 2,
              "path_length_m": 1.0,
              "max_distance_from_origin_m": 0.5
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(CaptureManifest.self, from: data)

        #expect(manifest.id == id)
        #expect(manifest.name == "Legacy scan")
        #expect(manifest.cameraOrientation == nil)
        #expect(manifest.representativeThumbnailVersion == nil)
    }

    @Test("Writes one-based images and recovers after interrupted finalize")
    func incrementalWriteAndFinalize() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Point Documents/Captures at a temp directory by writing relative to a custom writer
        // through the real CapturePaths (Documents). Clean up the created capture afterward.
        let writer = try CaptureBundleWriter(
            name: "Test Room",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        let frame = try makePendingFrame(translation: SIMD3(0.1, 0.2, 0.3), frameIndex: 0)
        let index = try writer.append(frame)
        #expect(index == 1)
        #expect(FileManager.default.fileExists(atPath: CapturePaths.image(for: writer.id, index: 1).path))
        #expect(FileManager.default.fileExists(atPath: CapturePaths.frameRecord(for: writer.id, index: 1).path))
        #expect(writer.currentManifest.phase == .recording)
        #expect(writer.currentManifest.frameCount == 1)

        let second = try makePendingFrame(translation: SIMD3(0.2, 0.3, 0.5), frameIndex: 1)
        #expect(try writer.append(second) == 2)

        let finalized = try writer.finalize(
            durationSeconds: 4,
            pathLengthM: 1.2,
            maxDistanceFromOriginM: 0.8
        )
        #expect(finalized.phase == .complete)
        #expect(finalized.frameCount == 2)
        #expect(finalized.cameraOrientation == .identity)
        #expect(
            finalized.representativeThumbnailVersion
                == CaptureManifest.currentRepresentativeThumbnailVersion
        )
        let landscapeThumbnail = CaptureBundleValidator.jpegPixelSize(
            at: CapturePaths.thumbnail(for: writer.id)
        )
        #expect(landscapeThumbnail?.width == 512)
        #expect(landscapeThumbnail?.height == 256)

        let validation = CaptureBundleValidator.validateBundle(
            at: CapturePaths.bundleRoot(for: writer.id),
            frameCount: 2
        )
        #expect(validation.isValid, "Issues: \(validation.issues.map(\.message))")

        // Filenames are one-based and contiguous.
        let names = try FileManager.default.contentsOfDirectory(
            atPath: CapturePaths.imagesDir(for: writer.id).path
        ).filter { $0.hasSuffix(".jpg") }.sorted()
        #expect(names == ["Image_000001.jpg", "Image_000002.jpg"])

        // Trajectory lives under cameras/, not the bundle root.
        #expect(
            FileManager.default.fileExists(atPath: CapturePaths.trajectory(for: writer.id).path)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: CapturePaths.bundleRoot(for: writer.id)
                    .appendingPathComponent("camera_trajectory.json").path
            )
        )
        #expect(
            try bundleFiles(for: writer.id)
                == CapturePaths.bundleFilePaths(frameCount: 2).sorted()
        )
    }

    @Test("Per-frame intrinsics export preserves accepted-frame order")
    func writesPerFrameIntrinsics() throws {
        let writer = try CaptureBundleWriter(
            name: "Variable focus",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer {
            try? FileManager.default.removeItem(
                at: CapturePaths.captureRoot(for: writer.id)
            )
        }

        let exifData = try captureEXIFPlist(
            secondsAfterStart: 0,
            extra: [
                kCGImagePropertyExifExposureTime as String: 1.0 / 60.0,
                kCGImagePropertyExifFNumber as String: 1.78,
            ]
        )
        #expect(
            try writer.append(
                makePendingFrame(fx: 1_403, fy: 1_404, exifPropertyListData: exifData)
            ) == 1
        )
        #expect(
            try writer.append(makePendingFrame(fx: 1_417, fy: 1_418, frameIndex: 1)) == 2
        )
        _ = try writer.finalize(
            durationSeconds: 2,
            pathLengthM: 0.2,
            maxDistanceFromOriginM: 0.2
        )

        let data = try Data(
            contentsOf: CapturePaths.perFrameIntrinsics(for: writer.id)
        )
        let export = try JSONDecoder().decode(
            CapturePerFrameIntrinsicsExport.self,
            from: data
        )
        #expect(export.frameCount == 2)
        #expect(export.widthPx == 1_920)
        #expect(export.heightPx == 1_440)
        #expect(export.fxPx == [1_403, 1_417])
        #expect(export.fyPx == [1_404, 1_418])
        let firstImageSource = CGImageSourceCreateWithURL(
            CapturePaths.image(for: writer.id, index: 1) as CFURL,
            nil
        )
        let imageProperties = firstImageSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil)
                as? [CFString: Any]
        }
        let exif = imageProperties?[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        #expect(
            (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?
                .doubleValue == 1.0 / 60.0
        )
        #expect(
            (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?
                .doubleValue == 1.78
        )
        #expect(
            exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+00:00"
        )
        #expect(imageProperties?[kCGImagePropertyOrientation] == nil)
    }

    @Test("Finalize votes arkit_landscape_sensor for a portrait-hold trajectory")
    func writesPortraitOrientation() throws {
        let writer = try CaptureBundleWriter(
            name: "Portrait Room",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        let opencvPortrait = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 90),
            translation: SIMD3(0.1, 0.2, 0.3)
        )
        let arkit = (CameraGeometry.arkitToOpenCV * opencvPortrait).inverse
        _ = try writer.append(try makePendingFrame(arkitWorldFromCamera: arkit))
        var second = arkit
        second.columns.3 = SIMD4(0.2, 0.3, 0.5, 1)
        _ = try writer.append(try makePendingFrame(arkitWorldFromCamera: second, frameIndex: 1))

        let finalized = try writer.finalize(
            durationSeconds: 4,
            pathLengthM: 1.2,
            maxDistanceFromOriginM: 0.8
        )

        #expect(finalized.cameraOrientation == .arkitLandscapeSensor)
        let portraitThumbnail = CaptureBundleValidator.jpegPixelSize(
            at: CapturePaths.thumbnail(for: writer.id)
        )
        #expect(portraitThumbnail?.width == 512)
        #expect(portraitThumbnail?.height == 256)
    }

    @Test("Finalize votes rotate_180 for an inverted landscape trajectory")
    func writesInvertedLandscapeOrientation() throws {
        let writer = try CaptureBundleWriter(
            name: "Inverted Landscape Room",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        let rotate180 = CameraGeometry.makeTransform(
            rotation: CameraGeometry.makeRotation(xDegrees: 0, yDegrees: 0, zDegrees: 180),
            translation: .zero
        )
        let opencvInvertedLandscape = rotate180 * CameraGeometry.arkitToOpenCV
        let arkit = (CameraGeometry.arkitToOpenCV * opencvInvertedLandscape).inverse
        _ = try writer.append(try makePendingFrame(arkitWorldFromCamera: arkit))

        let finalized = try writer.finalize(
            durationSeconds: 2,
            pathLengthM: 0.5,
            maxDistanceFromOriginM: 0.5
        )

        #expect(finalized.cameraOrientation == .rotate180)
    }

    @Test("Interrupted capture with frames can be recovered to complete")
    func recoverInterrupted() throws {
        let writer = try CaptureBundleWriter(
            name: "Interrupted",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        let id = writer.id
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: id)) }

        _ = try writer.append(try makePendingFrame(translation: .zero))
        _ = try writer.append(try makePendingFrame(translation: SIMD3(0.2, 0, 0), frameIndex: 1))
        #expect(writer.currentManifest.phase == .recording)

        // Simulate force-quit: leave phase as recording, then recover via a fresh writer.
        let recovered = try CaptureBundleWriter(recoveringExisting: id)
        let finalized = try recovered.finalize(
            durationSeconds: 3,
            pathLengthM: 0.4,
            maxDistanceFromOriginM: 0.2
        )
        #expect(finalized.phase == .complete)
        #expect(finalized.frameCount == 2)

        let validation = CaptureBundleValidator.validateBundle(
            at: CapturePaths.bundleRoot(for: id),
            frameCount: 2
        )
        #expect(validation.isValid)
    }

    @Test("Empty interrupted capture finalizes as empty error")
    func emptyInterrupted() throws {
        let writer = try CaptureBundleWriter(
            name: "Empty",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        let id = writer.id
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: id)) }

        let recovered = try CaptureBundleWriter(recoveringExisting: id)
        do {
            _ = try recovered.finalize(durationSeconds: 0, pathLengthM: 0, maxDistanceFromOriginM: 0)
            Issue.record("Expected emptyCapture error")
        } catch let error as CaptureBundleWriterError {
            #expect(error == .emptyCapture)
        }
    }

    @Test("Empty finalization preserves the original frame pipeline error")
    func emptyFinalizePreservesPipelineError() throws {
        let writer = try CaptureBundleWriter(
            name: "Buffer failure",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        writer.stopAcceptingFrames(because: .frameBufferingFailed)

        do {
            _ = try writer.finalize(
                durationSeconds: 10,
                pathLengthM: 1,
                maxDistanceFromOriginM: 0.5
            )
            Issue.record("Expected frameBufferingFailed error")
        } catch let error as CaptureBundleWriterError {
            #expect(error == .frameBufferingFailed)
            #expect(
                writer.currentManifest.errorMessage
                    == CaptureBundleWriterError.frameBufferingFailed.localizedDescription
            )
        }
    }

    @Test("Rejects wrong resolution before assigning an index")
    func rejectsWrongResolution() throws {
        let writer = try CaptureBundleWriter(
            name: "Bad res",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        var frame = try makePendingFrame(translation: .zero)
        // Forge wrong dimensions while keeping a valid buffer — width/height fields are authoritative.
        frame = PendingCaptureFrame(
            pixelBuffer: frame.pixelBuffer,
            arkitWorldFromCamera: frame.arkitWorldFromCamera,
            fx: frame.fx,
            fy: frame.fy,
            cx: frame.cx,
            cy: frame.cy,
            width: 3840,
            height: 2880,
            sampleReason: "initial"
        )

        do {
            _ = try writer.append(frame)
            Issue.record("Expected invalid resolution error")
        } catch let error as CaptureBundleWriterError {
            guard case .invalidImageResolution = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
        #expect(writer.committedFrameCount == 0)
    }

    @Test("Validator catches trajectory count mismatch")
    func validatorTrajectoryMismatch() {
        let issues = CaptureBundleValidator.validateTrajectory(
            [[[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]],
            expectedCount: 2
        )
        #expect(issues.contains(where: { $0.code == "TRAJECTORY_COUNT_MISMATCH" }))
    }

    @Test("Image filenames must start at one")
    func imageSequenceStart() {
        let issues = CaptureBundleValidator.validateImageFilenames(
            ["Image_000000.jpg"],
            expectedCount: 1
        )
        #expect(issues.contains(where: { $0.code == "IMAGE_SEQUENCE_START" }))
    }

    @Test("Validator rejects a bundle without per-frame intrinsics")
    func validatorMissingPerFrameIntrinsics() throws {
        let writer = try CaptureBundleWriter(
            name: "No intrinsics",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        _ = try writer.append(try makePendingFrame(translation: .zero))
        _ = try writer.finalize(durationSeconds: 1, pathLengthM: 0, maxDistanceFromOriginM: 0)
        try FileManager.default.removeItem(at: CapturePaths.perFrameIntrinsics(for: writer.id))

        let result = CaptureBundleValidator.validateBundle(
            at: CapturePaths.bundleRoot(for: writer.id),
            frameCount: 1
        )
        #expect(result.issues.map(\.code) == ["PER_FRAME_INTRINSICS_MISSING"])
    }

    @Test("Finalize refuses frames without EXIF capture time")
    func finalizeRejectsMissingEXIF() throws {
        let writer = try CaptureBundleWriter(
            name: "No EXIF",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        _ = try writer.append(try makePendingFrame(exifPropertyListData: Data()))
        #expect(throws: CaptureBundleWriterError.self) {
            _ = try writer.finalize(durationSeconds: 1, pathLengthM: 0, maxDistanceFromOriginM: 0)
        }
        let issues = CaptureBundleValidator.validateImages([
            CapturePaths.image(for: writer.id, index: 1),
        ])
        // ImageIO still writes an EXIF segment, just without the time tags.
        #expect(issues.map(\.code) == ["EXIF_CAPTURE_TIME_INVALID"])
    }

    @Test("EXIF capture times must strictly increase")
    func validatorRejectsNonIncreasingEXIF() throws {
        let writer = try CaptureBundleWriter(
            name: "Clock skew",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer { try? FileManager.default.removeItem(at: CapturePaths.captureRoot(for: writer.id)) }

        _ = try writer.append(try makePendingFrame(frameIndex: 1))
        _ = try writer.append(try makePendingFrame(frameIndex: 1))
        let issues = CaptureBundleValidator.validateImages([
            CapturePaths.image(for: writer.id, index: 1),
            CapturePaths.image(for: writer.id, index: 2),
        ])
        #expect(issues.map(\.code) == ["EXIF_TIMESTAMPS_NOT_INCREASING"])
    }

    @Test("EXIF capture time parses the contract format")
    func exifTimeParsing() {
        let utc = CaptureExifTime.seconds(
            dateTimeOriginal: "2026:01:01 12:00:00",
            subSecTimeOriginal: "25",
            offsetTimeOriginal: "+00:00"
        )
        #expect(utc == 1_767_268_800.25)
        let berlin = CaptureExifTime.seconds(
            dateTimeOriginal: "2026:01:01 13:00:00",
            subSecTimeOriginal: "25",
            offsetTimeOriginal: "+01:00"
        )
        #expect(berlin == utc)
        #expect(
            CaptureExifTime.seconds(
                dateTimeOriginal: "2026-01-01 12:00:00",
                subSecTimeOriginal: "25",
                offsetTimeOriginal: "+00:00"
            ) == nil
        )
        #expect(
            CaptureExifTime.seconds(
                dateTimeOriginal: "2026:01:01 12:00:00",
                subSecTimeOriginal: "25",
                offsetTimeOriginal: nil
            ) == nil
        )
    }

    @Test("Per-frame intrinsics outside the contract bounds fail")
    func validatorPerFrameIntrinsicsBounds() {
        let issues = CaptureBundleValidator.validatePerFrameIntrinsics(
            [
                "frame_count": 2,
                "width_px": 1_920,
                "height_px": 1_440,
                "fx_px": [1_340, 50],
                "fy_px": [1_340, 1_340],
                "cx_px": [960, 2_000],
                "cy_px": [720, 720],
            ] as [String: Any],
            expectedCount: 2
        )
        #expect(
            issues.map(\.code) == ["INTRINSICS_FX_UNREASONABLE", "INTRINSICS_CX_OUT_OF_BOUNDS"]
        )
    }

    @Test("Representative views use deterministic temporal bucket midpoints")
    func representativeFrameSelection() {
        let expected = [
            [0],
            [0, 1],
            [0, 1, 2],
            [0, 1, 2, 3],
            [0, 1, 2, 3, 4],
            [0, 1, 2, 3, 4, 5],
            [0, 1, 2, 3, 4, 5, 6],
            [0, 1, 2, 3, 4, 5, 6, 7],
            [0, 1, 2, 3, 5, 6, 7, 8],
        ]
        for (offset, indices) in expected.enumerated() {
            #expect(
                CaptureRepresentativeFrames.indices(frameCount: offset + 1)
                    == indices
            )
        }
        #expect(
            CaptureRepresentativeFrames.indices(frameCount: 3_000)
                == [187, 562, 937, 1_312, 1_687, 2_062, 2_437, 2_812]
        )
        #expect(CaptureRepresentativeFrames.indices(frameCount: 0).isEmpty)

        for frameCount in 1...CapturePaths.maxFrames {
            let indices = CaptureRepresentativeFrames.indices(frameCount: frameCount)
            #expect(Set(indices).count == indices.count)
        }
    }

    @Test("Representative zero-based indices map to one-based image files")
    func representativeImagePaths() {
        let captureID = UUID()
        let names = CaptureRepresentativeFrames.imageURLs(
            captureID: captureID,
            frameCount: 9
        ).map(\.lastPathComponent)

        #expect(
            names
                == [
                    "Image_000001.jpg",
                    "Image_000002.jpg",
                    "Image_000003.jpg",
                    "Image_000004.jpg",
                    "Image_000006.jpg",
                    "Image_000007.jpg",
                    "Image_000008.jpg",
                    "Image_000009.jpg",
                ]
        )
    }

    @Test("Contact-sheet tiles fit full portrait and landscape source bounds")
    func contactSheetAspectFitGeometry() {
        let tile = CGRect(x: 0, y: 0, width: 300, height: 200)

        let landscape = CaptureThumbnailRenderer.aspectFitRect(
            imageSize: CGSize(width: 400, height: 200),
            in: tile
        )
        #expect(landscape == CGRect(x: 0, y: 25, width: 300, height: 150))

        let portrait = CaptureThumbnailRenderer.aspectFitRect(
            imageSize: CGSize(width: 200, height: 400),
            in: tile
        )
        #expect(portrait == CGRect(x: 100, y: 0, width: 100, height: 200))
    }

    @Test("Adaptive contact-sheet rows cover the canvas without empty tiles")
    func threeViewContactSheetLayout() {
        let canvas = CaptureThumbnailRenderer.displayContactSheetSize
        let rects = CaptureThumbnailRenderer.contactSheetRects(
            count: 3,
            canvasSize: canvas
        )

        #expect(rects.count == 3)
        #expect(rects[0] == CGRect(x: 0, y: 0, width: 256, height: 128))
        #expect(rects[1] == CGRect(x: 256, y: 0, width: 256, height: 128))
        #expect(rects[2] == CGRect(x: 0, y: 128, width: 512, height: 128))

        for count in 1...CaptureRepresentativeFrames.maximumViewCount {
            let adaptiveRects = CaptureThumbnailRenderer.contactSheetRects(
                count: count,
                canvasSize: canvas
            )
            #expect(adaptiveRects.count == count)
            #expect(
                adaptiveRects.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
                    == canvas.width * canvas.height
            )
        }
    }

    @Test("Eight-view contact sheet is a full 4 by 2 grid")
    func eightViewContactSheetLayout() {
        let canvas = CaptureThumbnailRenderer.displayContactSheetSize
        let rects = CaptureThumbnailRenderer.contactSheetRects(
            count: 8,
            canvasSize: canvas
        )

        #expect(
            rects
                == [
                    CGRect(x: 0, y: 0, width: 128, height: 128),
                    CGRect(x: 128, y: 0, width: 128, height: 128),
                    CGRect(x: 256, y: 0, width: 128, height: 128),
                    CGRect(x: 384, y: 0, width: 128, height: 128),
                    CGRect(x: 0, y: 128, width: 128, height: 128),
                    CGRect(x: 128, y: 128, width: 128, height: 128),
                    CGRect(x: 256, y: 128, width: 128, height: 128),
                    CGRect(x: 384, y: 128, width: 128, height: 128),
                ]
        )
    }

    @Test(
        "Rendered contact sheets preserve every sharp source corner over a full background",
        arguments: [
            CaptureCameraOrientation.identity,
            CaptureCameraOrientation.rotate180,
            CaptureCameraOrientation.arkitLandscapeSensor,
        ]
    )
    func renderedContactSheetPreservesSource(
        orientation: CaptureCameraOrientation
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceData = try makeCornerMarkedJPEG()
        let sourceURLs = try (0..<8).map { index in
            let url = directory.appendingPathComponent("\(index).jpg")
            try sourceData.write(to: url)
            return url
        }
        let outputURL = directory.appendingPathComponent("contact-sheet.jpg")

        try CaptureThumbnailRenderer.writeDisplayContactSheet(
            fromSensorJPEGs: sourceURLs,
            orientation: orientation,
            to: outputURL
        )

        guard let image = UIImage(contentsOfFile: outputURL.path)?.cgImage else {
            Issue.record("Contact sheet could not be decoded")
            return
        }
        #expect(image.width == 512)
        #expect(image.height == 256)

        let pixels = try rgbaPixels(image)
        #expect(!pixels.contains(where: isNearlyBlack))
        for pixel in outerCornerPixels(
            pixels,
            width: image.width,
            height: image.height
        ) {
            #expect(!isNearlyBlack(pixel))
        }
        #expect(pixels.count(where: isRed) > 100)
        #expect(pixels.count(where: isGreen) > 100)
        #expect(pixels.count(where: isBlue) > 100)
        #expect(pixels.count(where: isYellow) > 100)
    }

    @Test(
        "One-to-seven-view contact sheets fill every output edge",
        arguments: Array(1...7)
    )
    func adaptiveRenderedContactSheetFillsOutput(frameCount: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceData = try makeCornerMarkedJPEG()
        let sourceURLs = try (0..<frameCount).map { index in
            let url = directory.appendingPathComponent("\(index).jpg")
            try sourceData.write(to: url)
            return url
        }
        let outputURL = directory.appendingPathComponent("contact-sheet.jpg")

        try CaptureThumbnailRenderer.writeDisplayContactSheet(
            fromSensorJPEGs: sourceURLs,
            orientation: .identity,
            to: outputURL
        )

        guard let image = UIImage(contentsOfFile: outputURL.path)?.cgImage else {
            Issue.record("Contact sheet could not be decoded")
            return
        }
        #expect(image.width == 512)
        #expect(image.height == 256)

        let pixels = try rgbaPixels(image)
        #expect(!pixels.contains(where: isNearlyBlack))
        for pixel in outerCornerPixels(
            pixels,
            width: image.width,
            height: image.height
        ) {
            #expect(!isNearlyBlack(pixel))
        }
    }
}

@Suite("CaptureVideoFormatSelector")
struct CaptureVideoFormatSelectorTests {
    // ARConfiguration.VideoFormat cannot be synthesized in unit tests without ARKit hardware
    // fixtures. Selection logic is covered by integration on device; this guards the constants.
    @Test("Required resolution matches contract")
    func requiredResolution() {
        #expect(CaptureVideoFormatSelector.requiredWidth == 1920)
        #expect(CaptureVideoFormatSelector.requiredHeight == 1440)
    }

    @Test("Motion stats committed with a frame land in the same on-disk manifest write")
    func motionStatsRideTheAppendManifestWrite() throws {
        let writer = try CaptureBundleWriter(
            name: "Stats",
            videoFormatDescription: "1920x1440@60",
            selectedLens: "wide",
            deviceModel: "iPhone"
        )
        defer {
            try? FileManager.default.removeItem(
                at: CapturePaths.captureRoot(for: writer.id)
            )
        }

        let frame = try makePendingFrame(translation: SIMD3(0.1, 0, 0))
        let index = try writer.append(
            frame,
            motionStats: CaptureMotionStatsUpdate(
                pathLengthM: 1.5,
                maxDistanceFromOriginM: 0.75,
                durationSeconds: 12
            )
        )
        #expect(index == 1)

        // Read the manifest from disk, not the in-memory copy: crash recovery
        // must see the frame count and its motion stats move together.
        let data = try Data(contentsOf: CapturePaths.manifest(for: writer.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureManifest.self, from: data)
        #expect(manifest.frameCount == 1)
        #expect(manifest.pathLengthM == 1.5)
        #expect(manifest.maxDistanceFromOriginM == 0.75)
        #expect(manifest.durationSeconds == 12)
    }
}

// MARK: - Helpers

/// Bundle-relative paths of every file under the capture's `bundle/`.
private func bundleFiles(for id: UUID) throws -> [String] {
    let root = CapturePaths.bundleRoot(for: id).standardizedFileURL.path
    let enumerator = FileManager.default.enumerator(atPath: root)
    return (enumerator?.allObjects as? [String] ?? [])
        .filter { !$0.hasSuffix("/") && !["images", "cameras"].contains($0) }
        .sorted()
}

/// ARKit-style `exifData` plist with the three capture-time tags Echo-3 needs,
/// `secondsAfterStart` after 2026-01-01 12:00:00 UTC.
private func captureEXIFPlist(
    secondsAfterStart: Double,
    extra: [String: Any] = [:]
) throws -> Data {
    let whole = Int(secondsAfterStart)
    let milliseconds = Int(((secondsAfterStart - Double(whole)) * 1_000).rounded())
    var exif = extra
    exif[kCGImagePropertyExifDateTimeOriginal as String] = String(
        format: "2026:01:01 12:%02d:%02d", whole / 60, whole % 60
    )
    exif[kCGImagePropertyExifSubsecTimeOriginal as String] = String(format: "%03d", milliseconds)
    exif[kCGImagePropertyExifOffsetTimeOriginal as String] = "+00:00"
    return try PropertyListSerialization.data(fromPropertyList: exif, format: .binary, options: 0)
}

/// A 1920×1440 frame. `frameIndex` sets its EXIF capture time (0.25 s apart),
/// so frames appended in index order satisfy the increasing-time rule.
private func makePendingFrame(
    translation: SIMD3<Float> = .zero,
    arkitWorldFromCamera: simd_float4x4? = nil,
    fx: Float = 1_340,
    fy: Float = 1_340,
    frameIndex: Int = 0,
    exifPropertyListData: Data? = nil
) throws -> PendingCaptureFrame {
    let buffer = try makePixelBuffer(width: 1920, height: 1440)
    var transform = arkitWorldFromCamera ?? matrix_identity_float4x4
    if arkitWorldFromCamera == nil || translation != .zero {
        transform.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
    }
    return PendingCaptureFrame(
        pixelBuffer: buffer,
        arkitWorldFromCamera: transform,
        fx: fx,
        fy: fy,
        cx: 960,
        cy: 720,
        width: 1920,
        height: 1440,
        sampleReason: "test",
        exifPropertyListData: try exifPropertyListData
            ?? captureEXIFPlist(secondsAfterStart: Double(frameIndex) * 0.25)
    )
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        struct PixelBufferError: Error {}
        throw PixelBufferError()
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 40, CVPixelBufferGetDataSize(buffer))
    }
    return buffer
}

private struct TestPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private func makeCornerMarkedJPEG() throws -> Data {
    let renderer = UIGraphicsImageRenderer(
        size: CGSize(width: 240, height: 180)
    )
    let image = renderer.image { context in
        UIColor(white: 0.55, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
        let markers: [(UIColor, CGRect)] = [
            (.red, CGRect(x: 0, y: 0, width: 28, height: 28)),
            (.green, CGRect(x: 212, y: 0, width: 28, height: 28)),
            (.blue, CGRect(x: 0, y: 152, width: 28, height: 28)),
            (.yellow, CGRect(x: 212, y: 152, width: 28, height: 28)),
        ]
        for (color, rect) in markers {
            color.setFill()
            context.fill(rect)
        }
    }
    guard let data = image.jpegData(compressionQuality: 1) else {
        throw CaptureBundleWriterError.jpegEncodeFailed
    }
    return data
}

private func rgbaPixels(_ image: CGImage) throws -> [TestPixel] {
    let byteCount = image.width * image.height * 4
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
    defer { bytes.deallocate() }
    bytes.initialize(repeating: 0, count: byteCount)
    guard let context = CGContext(
        data: bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CaptureBundleWriterError.jpegEncodeFailed
    }
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )

    return stride(from: 0, to: byteCount, by: 4).map { offset in
        TestPixel(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2]
        )
    }
}

private func outerCornerPixels(
    _ pixels: [TestPixel],
    width: Int,
    height: Int
) -> [TestPixel] {
    [
        pixels[0],
        pixels[width - 1],
        pixels[(height - 1) * width],
        pixels[height * width - 1],
    ]
}

private func isNearlyBlack(_ pixel: TestPixel) -> Bool {
    pixel.red < 5 && pixel.green < 5 && pixel.blue < 5
}

private func isRed(_ pixel: TestPixel) -> Bool {
    pixel.red > 150 && pixel.green < 120 && pixel.blue < 120
}

private func isGreen(_ pixel: TestPixel) -> Bool {
    pixel.green > 120
        && Float(pixel.green) > Float(pixel.red) * 1.4
        && Float(pixel.green) > Float(pixel.blue) * 1.4
}

private func isBlue(_ pixel: TestPixel) -> Bool {
    pixel.blue > 150 && pixel.red < 120 && pixel.green < 120
}

private func isYellow(_ pixel: TestPixel) -> Bool {
    pixel.red > 150 && pixel.green > 150 && pixel.blue < 120
}

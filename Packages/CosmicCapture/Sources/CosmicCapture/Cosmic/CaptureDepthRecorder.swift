import ARKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A copy of one frame's LiDAR depth, taken before the frame is committed.
struct CaptureDepthSample: Sendable {
    var width: Int
    var height: Int
    /// Row-major metres, `width * height` values.
    var depthMeters: [Float]
    /// Row-major `ARConfidenceLevel` raw values (0 low, 1 medium, 2 high).
    var confidence: [UInt8]?
}

extension CaptureDepthSample {
    init?(sceneDepth: ARDepthData) {
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        var depth = [Float](repeating: 0, count: width * height)
        depth.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                destination.baseAddress!
                    .advanced(by: row * width * MemoryLayout<Float>.stride)
                    .copyMemory(
                        from: depthBase.advanced(by: row * depthRowBytes),
                        byteCount: width * MemoryLayout<Float>.stride
                    )
            }
        }

        var confidence: [UInt8]?
        if let confidenceMap = sceneDepth.confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceMap) == width,
           CVPixelBufferGetHeight(confidenceMap) == height
        {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(confidenceMap) {
                let rowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
                var values = [UInt8](repeating: 0, count: width * height)
                values.withUnsafeMutableBytes { destination in
                    for row in 0..<height {
                        destination.baseAddress!
                            .advanced(by: row * width)
                            .copyMemory(from: base.advanced(by: row * rowBytes), byteCount: width)
                    }
                }
                confidence = values
            }
        }

        self.init(width: width, height: height, depthMeters: depth, confidence: confidence)
    }
}

/// PNG encoding for depth sidecar files. Depth is stored as 16-bit grayscale
/// millimetres (0 means no measurement), the common convention for RGB-D data.
enum CaptureDepthEncoder {
    static func millimeters(fromMeters meters: [Float]) -> [UInt16] {
        meters.map { value in
            guard value.isFinite, value > 0 else { return 0 }
            let millimeters = (value * 1000).rounded()
            return millimeters >= Float(UInt16.max) ? UInt16.max : UInt16(millimeters)
        }
    }

    static func depthPNG(width: Int, height: Int, millimeters: [UInt16]) -> Data? {
        guard millimeters.count == width * height else { return nil }
        // PNG stores 16-bit samples big-endian.
        var bytes = Data(capacity: millimeters.count * 2)
        for value in millimeters {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
        return png(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                .union(.byteOrder16Big),
            bytes: bytes
        )
    }

    static func confidencePNG(width: Int, height: Int, values: [UInt8]) -> Data? {
        guard values.count == width * height else { return nil }
        return png(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            bytes: Data(values)
        )
    }

    private static func png(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        bitmapInfo: CGBitmapInfo,
        bytes: Data
    ) -> Data? {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bitsPerPixel: bitsPerComponent,
                  bytesPerRow: width * bitsPerComponent / 8,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Writes depth and confidence maps for committed frames off the main thread.
/// Failures never affect the Echo-3 bundle; they only leave a frame without
/// depth.
final class CaptureDepthRecorder: Sendable {
    private let queue = DispatchQueue(label: "cosmic.capture.depth", qos: .utility)

    func record(_ sample: CaptureDepthSample, captureID: UUID, frameIndex: Int) {
        queue.async {
            Self.write(sample, captureID: captureID, frameIndex: frameIndex)
        }
    }

    /// Returns once every sample recorded so far is on disk.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    static func write(
        _ sample: CaptureDepthSample,
        captureID: UUID,
        frameIndex: Int,
        fileManager: FileManager = .default
    ) {
        let millimeters = CaptureDepthEncoder.millimeters(fromMeters: sample.depthMeters)
        guard let depthPNG = CaptureDepthEncoder.depthPNG(
            width: sample.width, height: sample.height, millimeters: millimeters
        ) else { return }
        do {
            try fileManager.createDirectory(
                at: CapturePaths.lidarDepthDir(for: captureID),
                withIntermediateDirectories: true
            )
            try depthPNG.write(
                to: CapturePaths.lidarDepth(for: captureID, index: frameIndex),
                options: .atomic
            )
            if let confidence = sample.confidence,
               let confidencePNG = CaptureDepthEncoder.confidencePNG(
                   width: sample.width, height: sample.height, values: confidence
               )
            {
                try fileManager.createDirectory(
                    at: CapturePaths.lidarConfidenceDir(for: captureID),
                    withIntermediateDirectories: true
                )
                try confidencePNG.write(
                    to: CapturePaths.lidarConfidence(for: captureID, index: frameIndex),
                    options: .atomic
                )
            }
        } catch {
            // Depth is optional sidecar data; a failed write is not fatal.
        }
    }
}

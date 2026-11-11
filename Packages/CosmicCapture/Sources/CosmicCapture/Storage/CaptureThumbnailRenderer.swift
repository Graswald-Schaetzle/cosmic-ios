import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UIKit

enum CaptureRepresentativeFrames {
    static let maximumViewCount = 8

    /// Zero-based midpoint indices from equal-width temporal buckets.
    static func indices(
        frameCount: Int,
        maximumViewCount: Int = maximumViewCount
    ) -> [Int] {
        guard frameCount > 0, maximumViewCount > 0 else { return [] }
        guard frameCount > maximumViewCount else {
            return Array(0..<frameCount)
        }
        return (0..<maximumViewCount).map { index in
            ((2 * index + 1) * frameCount) / (2 * maximumViewCount)
        }
    }

    static func imageURLs(captureID: UUID, frameCount: Int) -> [URL] {
        indices(frameCount: frameCount).map {
            CapturePaths.image(for: captureID, index: $0 + 1)
        }
    }
}

enum CaptureThumbnailRenderer {
    static let displayContactSheetSize = CGSize(width: 512, height: 256)

    private static let downsampleMaximumPixelSize = 1_024
    private static let backgroundBlurRadius: CGFloat = 12
    private static let backgroundRGBScale: CGFloat = 0.55
    private static let backgroundRGBBias: CGFloat = 20 / 255
    private static let ciContext = CIContext(
        options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()]
    )

    static func writeDisplayContactSheet(
        fromSensorJPEGs sourceURLs: [URL],
        orientation: CaptureCameraOrientation,
        to destinationURL: URL
    ) throws {
        guard (1...CaptureRepresentativeFrames.maximumViewCount).contains(sourceURLs.count)
        else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }

        let images = try sourceURLs.map { sourceURL in
            let sensorImage = try downsampledImage(at: sourceURL)
            return try orientForDisplay(sensorImage, orientation: orientation)
        }
        let canvasSize = displayContactSheetSize
        let rects = contactSheetRects(count: images.count, canvasSize: canvasSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let contactSheet = renderer.image { context in
            for (image, rect) in zip(images, rects) {
                autoreleasepool {
                    drawTile(image, in: rect, context: context.cgContext)
                }
            }
        }
        guard let jpeg = contactSheet.jpegData(compressionQuality: 0.8) else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        try jpeg.write(to: destinationURL, options: .atomic)
    }

    private static func downsampledImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: false,
                      kCGImageSourceThumbnailMaxPixelSize: downsampleMaximumPixelSize,
                  ] as CFDictionary
              )
        else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        return image
    }

    private static func orientForDisplay(
        _ sensorImage: CGImage,
        orientation: CaptureCameraOrientation
    ) throws -> CGImage {
        let displayOrientation: CGImagePropertyOrientation
        switch orientation {
        case .identity:
            return sensorImage
        case .arkitLandscapeSensor:
            displayOrientation = .right
        case .rotate180:
            displayOrientation = .down
        }

        let image = CIImage(cgImage: sensorImage).oriented(displayOrientation)
        let context = CIContext(
            options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()]
        )
        guard let rotated = context.createCGImage(image, from: image.extent) else {
            throw CaptureBundleWriterError.jpegEncodeFailed
        }
        return rotated
    }

    static func contactSheetRects(
        count: Int,
        canvasSize: CGSize
    ) -> [CGRect] {
        guard (1...CaptureRepresentativeFrames.maximumViewCount).contains(count)
        else { return [] }

        let rowCounts = count <= 2
            ? [count]
            : [(count + 1) / 2, count / 2]
        let rowHeight = floor(canvasSize.height / CGFloat(rowCounts.count))
        var rects: [CGRect] = []
        rects.reserveCapacity(count)

        for (rowIndex, columnCount) in rowCounts.enumerated() {
            let top = CGFloat(rowIndex) * rowHeight
            let height = rowIndex == rowCounts.count - 1
                ? canvasSize.height - top
                : rowHeight
            let columnWidth = floor(canvasSize.width / CGFloat(columnCount))
            for columnIndex in 0..<columnCount {
                let left = CGFloat(columnIndex) * columnWidth
                let width = columnIndex == columnCount - 1
                    ? canvasSize.width - left
                    : columnWidth
                rects.append(
                    CGRect(x: left, y: top, width: width, height: height)
                )
            }
        }
        return rects
    }

    static func aspectFitRect(
        imageSize: CGSize,
        in rect: CGRect
    ) -> CGRect {
        let scale = min(
            rect.width / imageSize.width,
            rect.height / imageSize.height
        )
        let drawSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func drawTile(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext
    ) {
        if let background = blurredBackground(image, size: rect.size) {
            UIImage(cgImage: background).draw(in: rect)
        } else {
            UIColor(white: backgroundRGBBias, alpha: 1).setFill()
            context.fill(rect)
        }
        let drawRect = aspectFitRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: rect
        )
        UIImage(cgImage: image).draw(in: drawRect)
    }

    private static func blurredBackground(
        _ image: CGImage,
        size: CGSize
    ) -> CGImage? {
        let source = CIImage(cgImage: image)
        let scale = max(
            size.width / source.extent.width,
            size.height / source.extent.height
        )
        let scaled = source.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let positioned = scaled.transformed(
            by: CGAffineTransform(
                translationX: (size.width - scaled.extent.width) / 2,
                y: (size.height - scaled.extent.height) / 2
            )
        )
        let outputRect = CGRect(origin: .zero, size: size)
        let background = positioned
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: backgroundBlurRadius]
            )
            .applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.65]
            )
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: backgroundRGBScale, y: 0, z: 0),
                    "inputGVector": CIVector(x: 0, y: backgroundRGBScale, z: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: backgroundRGBScale),
                    "inputBiasVector": CIVector(
                        x: backgroundRGBBias,
                        y: backgroundRGBBias,
                        z: backgroundRGBBias
                    ),
                ]
            )
            .cropped(to: outputRect)
        return ciContext.createCGImage(background, from: outputRect)
    }
}

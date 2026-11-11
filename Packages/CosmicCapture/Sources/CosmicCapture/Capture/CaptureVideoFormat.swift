import ARKit
import AVFoundation
import Foundation

struct CaptureVideoFormatChoice: Hashable, Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let description: String
}

enum CaptureVideoFormatSelector {
    static let requiredWidth = CapturePaths.requiredWidth
    static let requiredHeight = CapturePaths.requiredHeight

    /// Exactly 1920×1440 on the built-in wide-angle camera, as the Echo-3
    /// capture contract requires. Other lenses at that size are rejected; a
    /// device without a matching format cannot start a scan.
    static func selectExact1920x1440(
        from formats: [ARConfiguration.VideoFormat]
    ) -> (selected: ARConfiguration.VideoFormat?, candidates: [CaptureVideoFormatChoice], reason: String?) {
        let exact = formats.filter {
            Int($0.imageResolution.width) == requiredWidth
                && Int($0.imageResolution.height) == requiredHeight
        }

        let candidates = exact.map { format in
            CaptureVideoFormatChoice(
                width: Int(format.imageResolution.width),
                height: Int(format.imageResolution.height),
                framesPerSecond: format.framesPerSecond,
                description: "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond) \(format.captureDeviceType.rawValue)"
            )
        }

        if let wide = exact.first(where: { $0.captureDeviceType == .builtInWideAngleCamera }) {
            return (wide, candidates, nil)
        }

        let available = formats.map {
            "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))@\($0.framesPerSecond) \($0.captureDeviceType.rawValue)"
        }.joined(separator: ", ")
        return (
            nil,
            candidates,
            "This \(CaptureDevice.name) has no ARKit 1920×1440 format on the wide-angle camera. Available: \(available.isEmpty ? "none" : available)"
        )
    }
}

enum CaptureReadinessIssue: Equatable, Sendable {
    case arkitUnsupported
    case cameraDenied
    case cameraNotDetermined
    case unsupportedVideoFormat(String)
    case insufficientStorage
    case trackingFailed(String)

    var title: String {
        switch self {
        case .arkitUnsupported:
            return "This \(CaptureDevice.name) doesn't support spatial tracking"
        case .cameraDenied:
            return "Camera access required"
        case .cameraNotDetermined:
            return "Camera access needed"
        case .unsupportedVideoFormat:
            return "Camera format unavailable"
        case .insufficientStorage:
            return "Not enough storage"
        case .trackingFailed:
            return "Tracking unavailable"
        }
    }

    var message: String {
        switch self {
        case .arkitUnsupported:
            return "This app needs an \(CaptureDevice.name) that supports ARKit world tracking."
        case .cameraDenied:
            return "The camera is used to scan your space. Scans stay on this device until you export them."
        case .cameraNotDetermined:
            return "Allow camera access to scan your space. Scans stay on this device until you export them."
        case .unsupportedVideoFormat(let detail):
            return detail
        case .insufficientStorage:
            return "Free up about 2 GB on this \(CaptureDevice.name) before starting a scan."
        case .trackingFailed(let detail):
            return detail
        }
    }
}

import Foundation

/// Ranked missing regions from live saved-view evidence. Used for a finish
/// advisory; point-cloud colours are always preserved.
struct CaptureCoverageReviewData: Sendable {
    let gaps: [CaptureCoverageGap]
}

struct CapturePreview: Sendable {
    let pointCloud: CapturePointCloud?
    let trajectory: CaptureTrajectory?
    let coverage: CaptureCoverageReviewData?

    init(
        pointCloud: CapturePointCloud?,
        trajectory: CaptureTrajectory?,
        coverage: CaptureCoverageReviewData? = nil
    ) {
        self.pointCloud = pointCloud
        self.trajectory = trajectory
        self.coverage = coverage
    }

    var availability: CapturePreviewAvailability {
        CapturePreviewAvailability(
            hasPointCloud: pointCloud?.positions.isEmpty == false,
            hasTrajectory: trajectory?.arkitWorldFromCamera.isEmpty == false,
            hasCoverage: coverage?.gaps.isEmpty == false
        )
    }
}

struct CapturePreviewLayerVisibility: Equatable, Sendable {
    var isPointCloudVisible: Bool
    var areCamerasVisible: Bool
    init(availability: CapturePreviewAvailability) {
        isPointCloudVisible = availability.hasPointCloud
        areCamerasVisible =
            !availability.hasPointCloud && availability.hasTrajectory
    }

    static func allAvailable(
        for availability: CapturePreviewAvailability
    ) -> Self {
        var visibility = Self(availability: availability)
        visibility.areCamerasVisible = availability.hasTrajectory
        return visibility
    }

    var hasVisibleLayer: Bool {
        isPointCloudVisible || areCamerasVisible
    }
}

struct CapturePreviewAvailability: Equatable, Sendable {
    let hasPointCloud: Bool
    let hasTrajectory: Bool
    let hasCoverage: Bool

    init(
        hasPointCloud: Bool,
        hasTrajectory: Bool,
        hasCoverage: Bool = false
    ) {
        self.hasPointCloud = hasPointCloud
        self.hasTrajectory = hasTrajectory
        self.hasCoverage = hasCoverage
    }

    var isAvailable: Bool {
        hasPointCloud || hasTrajectory
    }
}

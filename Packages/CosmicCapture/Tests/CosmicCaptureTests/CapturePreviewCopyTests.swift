import Testing
@testable import CosmicCapture

@Suite("Capture preview copy")
struct CapturePreviewCopyTests {
    @Test("Review guidance stays concise and nontechnical")
    func conciseGuidance() {
        #expect(
            CapturePreviewCopy.reviewGuidance
                == "Check the area you meant to scan. Revisit any obvious holes, or save when you’re ready."
        )
        #expect(
            CapturePreviewCopy.coverageGuidance
                == "Some areas may need more coverage. This could affect the final result."
        )
        #expect(CapturePreviewCopy.gestureHint == "Drag to look around. Pinch to zoom.")
    }

    @Test(
        "Accessibility names layers without counts or source details",
        arguments: [
            CapturePreviewAvailability(
                hasPointCloud: true,
                hasTrajectory: true
            ),
            CapturePreviewAvailability(
                hasPointCloud: true,
                hasTrajectory: false
            ),
            CapturePreviewAvailability(
                hasPointCloud: false,
                hasTrajectory: true
            ),
        ]
    )
    func accessibleLayerSummary(
        availability: CapturePreviewAvailability
    ) {
        let label = CapturePreviewCopy.accessibilityLabel(
            availability: availability
        )
        var expected = "Interactive capture preview."
        if availability.hasPointCloud {
            expected += " Point Cloud layer available."
        }
        if availability.hasTrajectory {
            expected += " Cameras layer available."
        }
        expected += " The preview is a rough guide."

        #expect(label == expected)
        #expect(!label.contains("LiDAR"))
        #expect(!label.contains("RGB"))
        #expect(!label.contains("position"))
    }
}

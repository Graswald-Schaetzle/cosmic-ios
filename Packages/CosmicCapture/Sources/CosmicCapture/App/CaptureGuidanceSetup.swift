/// Chooses the guidance setup. Cosmic always uses the Full setup: LiDAR
/// coverage mesh, gap coaching, walkthrough and finish review from
/// `FullGuidance/`. Devices without LiDAR fall back inside that experience.
@MainActor
enum CaptureGuidanceSetup {
    static func makeExperience() -> (any CaptureGuidanceExperience)? {
        CoverageGuidanceExperience()
    }
}

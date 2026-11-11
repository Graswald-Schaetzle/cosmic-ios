import Foundation
import SwiftUI

/// Optional add-on that replaces the live screen and finish review with its
/// own guidance UI, such as the LiDAR coverage experience in `FullGuidance/`.
/// Core capture runs without one; `CaptureGuidanceSetup` picks which to use
/// (see `docs/guidance-setups.md`).
///
/// Every save, discard and keep-scanning action still goes through
/// `CaptureFlowModel`, so the bundle on disk is identical in both setups.
@MainActor
protocol CaptureGuidanceExperience: AnyObject {
    /// Observes live capture; handed to the coordinator at creation.
    var liveGuide: (any CaptureLiveGuide)? { get }

    /// Binds the experience to the flow it decorates. Called once.
    func attach(to model: CaptureFlowModel)

    /// Returns false to hold the start, e.g. while a walkthrough asks the
    /// user to turn the phone sideways.
    func shouldStartCapture() -> Bool

    func captureDidStart()

    /// Called when the user taps Finish. Return true when the experience
    /// presents its own review; the core finish sheet is skipped then.
    func presentFinishReview() -> Bool

    func captureDidResume()
    func captureDidSave()

    /// Called after the bundle is finalized on disk and before the flow shows
    /// the saved screen. Add-ons persist their own sidecar data here; it must
    /// never touch `bundle/`.
    func captureDidFinalize(id: UUID) async

    func liveView() -> AnyView

    /// Drawn above every step: walkthrough introduction, finish review.
    func flowOverlay() -> AnyView
}

extension CaptureGuidanceExperience {
    func captureDidFinalize(id: UUID) async {}
}

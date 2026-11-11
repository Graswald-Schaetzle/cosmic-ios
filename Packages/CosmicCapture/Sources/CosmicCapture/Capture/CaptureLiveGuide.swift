import ARKit
import simd

/// What the coordinator knows about one processed frame, for a live guide.
struct CaptureLiveGuideFrameContext {
    let isActivelySampling: Bool
    let isTrackingNormal: Bool
    /// True while a hold-mismatch or flow message owns the HUD; add-on cues
    /// must stay quiet then.
    let hasBlockingMessage: Bool
    /// Seconds of sampling so far in this capture.
    let scanningSeconds: TimeInterval
    /// The message the arbiter published for this frame.
    let guidance: CaptureGuidance?
}

/// Optional add-on that extends live capture with its own guidance, such as
/// the LiDAR coverage guide in `FullGuidance/`. Core capture runs without one
/// (see `docs/guidance-setups.md`).
///
/// A guide only observes. It never decides which frames are saved and never
/// writes to the bundle. `configure` may add scene reconstruction or frame
/// semantics, but must leave the video format, focus and exposure alone.
@MainActor
protocol CaptureLiveGuide: AnyObject {
    /// Extra reset options for a fresh session, e.g. `.resetSceneReconstruction`.
    var sessionResetOptions: ARSession.RunOptions { get }

    func configure(_ configuration: ARWorldTrackingConfiguration)

    /// A new capture is starting; drop all state from the previous one.
    func captureWillBegin()

    /// The capture was saved or discarded.
    func captureDidEnd()

    /// Add-on cues for the arbiter, evaluated before each frame's guidance.
    func advisories() -> [CaptureGuidanceAdvisory]

    /// Called for every processed frame after guidance is evaluated.
    func observe(_ frame: ARFrame, context: CaptureLiveGuideFrameContext)

    /// Called when a frame is accepted for writing. The returned closure runs
    /// on the main actor only after the frame committed to disk, so guidance
    /// reflects saved frames and nothing else.
    func prepareCommit(of frame: ARFrame) -> (@MainActor (_ frameIndex: Int) -> Void)?

    /// Anchor updates while sampling is active.
    func anchorsDidUpdate(_ anchors: [ARAnchor])
    func anchorsDidRemove(_ anchors: [ARAnchor])
}

import Foundation
import Observation

/// Teaching progress is independent of recording and coverage. Skipping, going
/// back, and reviewing never reset the writer, AR session, or saved evidence.
@MainActor
@Observable
final class CaptureWalkthrough {
    enum Lesson: String, CaseIterable {
        case preview, inspect, reset, camera, layout, hiddenSurfaces, review, sweep

        var title: String {
            switch self {
            case .preview: "Watch your scan grow"
            case .inspect: "Look from different angles"
            case .reset: "Back to the starting view"
            case .camera: "Where you’re looking"
            case .layout: "See the full preview"
            case .hiddenSurfaces: "Scan around objects"
            case .review: "Do one final pass"
            case .sweep: "Sweep high to low"
            }
        }

        func detail(hasLayout: Bool) -> String {
            switch self {
            case .preview: "This preview shows what you’ve scanned. Keep moving to fill in more detail, and revisit areas with holes."
            case .inspect: "Drag the preview to look around, or pinch to zoom."
            case .reset: "Tap reset to return to the starting view. Everything you’ve captured stays in place."
            case .camera: "The orange dot is your phone. Its rays show where the camera is looking."
            case .layout: "Tap expand for a closer look as you scan. Holes show areas to scan again."
            case .hiddenSurfaces: "Walk around tables, chairs and beds so the scan sees each side."
            case .review: hasLayout
                ? "Aim for a preview that looks like your space. If you like, try another angle to fill holes in walls, floors, ceilings or objects you care about."
                : "If you like, revisit your starting point, walls and objects. Another pass can help fill in the details."
            case .sweep: "Walk slowly and tilt from high to low. Keep some of the wall or nearby surroundings in view."
            }
        }
    }

    static let choiceKey = "capture.firstScanWalkthrough.v1.choice"
    private let defaults: UserDefaults
    var isPresentingIntroduction = false
    private(set) var introductionPage = 0
    private(set) var isOffered = false
    private(set) var isSelected = false
    private(set) var lesson: Lesson?
    private(set) var hasLayout = false
    private(set) var inspectedLayout = false
    private(set) var inspectedPreview = false
    private(set) var didReview = false
    private(set) var didComplete = false
    enum PostScanStage { case preview, actions }
    var postScanStage: PostScanStage?
    var inspectedPointCloud = false
    private(set) var practiceFrames = 0
    private(set) var practiceDistance: Float = 0
    private var lastFrames: Int?
    private var lastDistance: Float = 0
    private var evidenceLesson: Lesson?

    var canAdvance: Bool {
        switch lesson {
        case .inspect: return inspectedPreview
        case .reset: return false
        case .layout: return inspectedLayout
        case .review, .none: return false
        default: return true
        }
    }

    func observeCapture(frames: Int, distance: Float, category: CaptureStructuralCategory) {
        guard isActive else { return }
        if evidenceLesson != lesson || lastFrames == nil || frames < lastFrames! {
            evidenceLesson = lesson
            practiceFrames = 0
            practiceDistance = 0
            lastFrames = frames
            lastDistance = distance
            return
        }
        let delta = max(0, frames - (lastFrames ?? frames))
        let moved = max(0, distance - lastDistance)
        lastFrames = frames
        lastDistance = distance
        // A continuous sweep deliberately crosses surface categories.
        practiceFrames += delta
        if delta > 0 { practiceDistance += moved }
    }

    func completedTour() {
        didComplete = true
        postScanStage = nil
        lesson = nil
        isSelected = false
        defaults.set("completed", forKey: Self.choiceKey)
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isActive: Bool { lesson != nil }
    var lessons: [Lesson] {
        hasLayout ? [.preview, .inspect, .reset, .camera, .layout, .hiddenSurfaces, .review]
            : [.sweep, .hiddenSurfaces, .review]
    }
    var totalSteps: Int { lessons.count + 2 }
    var postScanStep: Int { lessons.count + (postScanStage == .preview ? 1 : 2) }

    var progress: String {
        guard let lesson, let index = lessons.firstIndex(of: lesson) else { return "" }
        return "\(index + 1) of \(lessons.count)"
    }

    func offerIfNeeded(isFirstCapture: Bool, isContinuation: Bool) {
        guard !isSelected else { return }
        isOffered = isFirstCapture && !isContinuation && defaults.string(forKey: Self.choiceKey) == nil
    }

    func presentIntroduction() {
        introductionPage = 0
        isPresentingIntroduction = true
    }

    func requestLandscape() {
        introductionPage = 1
        isPresentingIntroduction = true
    }

    func select() {
        isPresentingIntroduction = false
        isSelected = true
        isOffered = false
        didComplete = false
    }

    func start(hasLayout: Bool) {
        guard isSelected else { return }
        defaults.set("started", forKey: Self.choiceKey)
        self.hasLayout = hasLayout
        inspectedLayout = false
        inspectedPreview = false
        didReview = false
        lastFrames = nil
        postScanStage = nil
        lesson = lessons.first
    }

    func skip() {
        postScanStage = nil
        isPresentingIntroduction = false
        defaults.set("skipped", forKey: Self.choiceKey)
        isOffered = false
        isSelected = false
        lesson = nil
    }

    func advance() {
        guard let lesson, let index = lessons.firstIndex(of: lesson), index + 1 < lessons.count else { return }
        self.lesson = lessons[index + 1]
        practiceFrames = 0
        practiceDistance = 0
        lastFrames = nil
    }

    func interactedWithPreview() {
        if lesson == .inspect { inspectedPreview = true }
    }

    func resetPreview() {
        if lesson == .reset { advance() }
    }

    func openedLayout() {
        if lesson == .layout { inspectedLayout = true }
    }

    func closedLayout() {
        if lesson == .layout && inspectedLayout { advance() }
    }

    func openedReview() {
        guard isActive else { return }
        lesson = .review
        didReview = true
        postScanStage = .preview
        inspectedPointCloud = false
    }

    /// Saving the practice scan completes the tour.
    func saved() {
        guard isActive || postScanStage != nil else { return }
        completedTour()
    }
}

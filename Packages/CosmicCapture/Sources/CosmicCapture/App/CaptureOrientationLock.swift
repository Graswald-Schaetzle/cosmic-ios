import UIKit

enum CaptureOrientationLifecycleStage: CaseIterable, Sendable {
    case readiness
    case live
    case finish
    case saving
    case saved
    case background
    case foreground
}

/// iPhone browses in portrait; iPad rotates freely everywhere except a live
/// capture, which locks the orientation it started in.
enum CaptureOrientationDeviceClass: Sendable {
    case phone
    case pad

    @MainActor static var current: CaptureOrientationDeviceClass {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }

    var unlockedMask: UIInterfaceOrientationMask {
        switch self {
        case .phone: .allButUpsideDown
        case .pad: .all
        }
    }
}

/// Pure orientation policy, kept separate from UIKit so it is unit-testable.
///
/// A capture locks to the interface orientation it starts in. The hold mode
/// recorded at that moment decides the hold-mismatch warning, and every frame
/// in one bundle must share one hold (see `docs/coordinate-conventions.md`).
struct CaptureOrientationLifecyclePolicy {
    let deviceClass: CaptureOrientationDeviceClass
    private(set) var isCapturePresentationActive = false
    private(set) var stage: CaptureOrientationLifecycleStage?
    private(set) var lockedMask: UIInterfaceOrientationMask?

    init(deviceClass: CaptureOrientationDeviceClass = .phone) {
        self.deviceClass = deviceClass
    }

    var supportedMask: UIInterfaceOrientationMask {
        lockedMask ?? deviceClass.unlockedMask
    }

    mutating func beginCapturePresentation() {
        isCapturePresentationActive = true
        stage = .readiness
        lockedMask = nil
    }

    mutating func lockForCapture(_ mask: UIInterfaceOrientationMask) {
        guard isCapturePresentationActive else { return }
        lockedMask = mask
        stage = .live
    }

    mutating func transition(to stage: CaptureOrientationLifecycleStage) {
        guard isCapturePresentationActive else { return }
        self.stage = stage
    }

    mutating func endCapturePresentation() {
        isCapturePresentationActive = false
        stage = nil
        lockedMask = nil
    }

    static func lock(
        for interfaceOrientation: UIInterfaceOrientation
    ) -> (mask: UIInterfaceOrientationMask, holdMode: CaptureHoldMode) {
        switch interfaceOrientation {
        case .landscapeLeft:
            return (.landscapeLeft, .landscape)
        case .landscapeRight:
            return (.landscapeRight, .landscape)
        case .portraitUpsideDown:
            return (.portraitUpsideDown, .portrait)
        case .portrait, .unknown:
            return (.portrait, .portrait)
        @unknown default:
            return (.portrait, .portrait)
        }
    }
}

@MainActor
enum CaptureOrientationLock {
    private(set) static var currentMask: UIInterfaceOrientationMask =
        CaptureOrientationDeviceClass.current.unlockedMask
    private static var lifecyclePolicy = CaptureOrientationLifecyclePolicy(
        deviceClass: .current
    )

    static func beginCapturePresentation() {
        lifecyclePolicy.beginCapturePresentation()
        apply(forceRequest: true)
    }

    static func lockForCapture(
        interfaceOrientation: UIInterfaceOrientation? = nil
    ) -> CaptureHoldMode {
        let lock = CaptureOrientationLifecyclePolicy.lock(
            for: interfaceOrientation ?? currentInterfaceOrientation
        )
        lifecyclePolicy.lockForCapture(lock.mask)
        apply(forceRequest: true)
        return lock.holdMode
    }

    static func transition(to stage: CaptureOrientationLifecycleStage) {
        lifecyclePolicy.transition(to: stage)
        apply(forceRequest: stage == .background || stage == .foreground)
    }

    static func endCapturePresentation() {
        lifecyclePolicy.endCapturePresentation()
        apply(forceRequest: true)
    }

    private static var currentInterfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        return scenes.first(where: {
            $0.activationState == .foregroundActive
        })?.interfaceOrientation
            ?? scenes.first?.interfaceOrientation
            ?? .portrait
    }

    private static func apply(forceRequest: Bool) {
        let mask = lifecyclePolicy.supportedMask
        guard forceRequest || currentMask != mask else { return }
        currentMask = mask

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}

/// Keeps the screen awake while a live capture holds it.
@MainActor
enum CaptureIdleTimerLock {
    static let captureHolder = "capture"

    private static var holders: Set<String> = []

    static var isDisabled: Bool { !holders.isEmpty }

    static func setDisabled(_ disabled: Bool, holder: String = captureHolder) {
        if disabled {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        if UIApplication.shared.isIdleTimerDisabled != isDisabled {
            UIApplication.shared.isIdleTimerDisabled = isDisabled
        }
    }

    static func restore(holder: String = captureHolder) {
        setDisabled(false, holder: holder)
    }
}

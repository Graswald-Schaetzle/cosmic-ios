import UIKit

/// Supplies the orientation mask so the capture flow can lock the interface
/// to the orientation the scan started in. The host app installs it with
/// `@UIApplicationDelegateAdaptor(CaptureAppDelegate.self)`.
public final class CaptureAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { CaptureOrientationLock.currentMask }
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CaptureBundleExporter.clearExports()
        return true
    }
}

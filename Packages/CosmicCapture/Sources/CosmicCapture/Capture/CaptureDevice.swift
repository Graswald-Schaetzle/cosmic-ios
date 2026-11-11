import Foundation

/// The hardware noun for user-facing copy, as in "Saved on this iPad".
///
/// Read from the model identifier rather than `UIDevice`, which is main-actor
/// isolated, so storage errors can use it off the main actor.
enum CaptureDevice {
    static let name = isPad ? "iPad" : "iPhone"

    static let isPad: Bool = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPad")
        }
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.hasPrefix("iPad")
    }()
}

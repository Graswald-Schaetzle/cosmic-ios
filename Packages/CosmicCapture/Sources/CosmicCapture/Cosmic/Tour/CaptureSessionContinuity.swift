import Foundation

/// Decides which captures may claim to share one ARKit world.
///
/// The backend places two rooms with the same `capture_session_id` in the
/// same coordinates without looking at their doors, so a wrong claim is
/// worse than a missing one. Anything that could have moved the world
/// origin therefore ends the current session id; the next capture gets a
/// new one and the rooms are linked through their door markings only.
public struct CaptureSessionContinuity: Sendable {
    public enum Tracking: Sendable, Equatable {
        case normal
        /// ARKit is starting up: there is no world yet.
        case initializing
        /// ARKit lost the world and is trying to find it again.
        case relocalizing
        case notAvailable
        /// Too little texture or too much motion. The world is kept, but
        /// the position drifts while this lasts.
        case degraded
    }

    /// How long tracking may stay degraded before the positions are no
    /// longer trusted across rooms.
    public static let maximumDegradedSeconds: TimeInterval = 3

    public private(set) var sessionID: String
    public private(set) var isBroken = true
    private var degradedSince: TimeInterval?
    private let makeID: @Sendable () -> String

    public init(makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.makeID = makeID
        sessionID = makeID()
    }

    /// Feed every processed frame's tracking state with its timestamp.
    public mutating func observe(_ tracking: Tracking, at timestamp: TimeInterval) {
        switch tracking {
        case .normal:
            degradedSince = nil
        case .initializing, .relocalizing, .notAvailable:
            degradedSince = nil
            isBroken = true
        case .degraded:
            let since = degradedSince ?? timestamp
            degradedSince = since
            if timestamp - since > Self.maximumDegradedSeconds {
                isBroken = true
            }
        }
    }

    /// The session was paused, interrupted, reset, or the app left the foreground.
    public mutating func markBroken() {
        isBroken = true
    }

    /// The id for a capture that starts now. Captures started while the
    /// session stayed intact get the same id.
    public mutating func sessionIDForCaptureStart() -> String {
        if isBroken {
            sessionID = makeID()
            isBroken = false
        }
        degradedSince = nil
        return sessionID
    }
}

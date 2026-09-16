import Foundation
import SwiftUI

/// Why the Hermes WebSocket dropped while a messaging live turn was open.
enum MessagingTransportInterruptReason: Equatable {
    /// App backgrounded; iOS may tear down the socket — expected, not failure.
    case background
    /// Socket closed while foreground; resume sync may recover the turn.
    case foregroundTransport
    /// Gateway/session auth is gone — use disconnected chrome, not drop copy.
    case sessionDead
}

/// Client-only overlays orthogonal to `MessagingLiveTurn.Phase`.
enum MessagingLifecycleOverlay: Equatable {
    case appBackground
    case resumeSync
    case reconnecting
    case resumedStream
    case turnLost
}

enum MessagingResumeTiming {
    static let softReconnectDelay: Duration = .milliseconds(800)
    static let turnLossBudget: Duration = .seconds(3)
}

enum MessagingResumeCopy {
    static let softReconnect = "Catching up with the reply…"
    static let softReconnectAlt = "Reconnecting…"
    static let turnLost = "Couldn't restore this reply. Retry?"
}

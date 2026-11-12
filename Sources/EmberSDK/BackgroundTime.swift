import Foundation
import Synchronization

/// Asks the system to keep the app running while a file goes up, should it leave the foreground.
/// `begin` starts asking, with a reason, and answers how to stop; stopping twice is harmless.
public struct BackgroundTime: Sendable {
    public var begin: @Sendable (_ reason: String) -> @Sendable () -> Void

    public init(begin: @escaping @Sendable (_ reason: String) -> @Sendable () -> Void) {
        self.begin = begin
    }

    /// `ProcessInfo.performExpiringActivity`: the time the system gives an app leaving the
    /// foreground. When it runs out the upload is suspended with the app, and fails or goes on
    /// when the app comes back. On macOS, where an app isn't suspended so, it asks for nothing.
    public static let system: BackgroundTime = {
        #if os(macOS)
        none
        #else
        expiringActivity
        #endif
    }()

    #if !os(macOS)
    private static let expiringActivity = BackgroundTime { reason in
        let done = DispatchSemaphore(value: 0)
        let ended = Mutex(false)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired { done.signal() } else { done.wait() }
        }
        return {
            let first = ended.withLock { ended in
                defer { ended = true }
                return !ended
            }
            if first { done.signal() }
        }
    }
    #endif

    /// Asks for nothing.
    public static let none = BackgroundTime { _ in {} }
}

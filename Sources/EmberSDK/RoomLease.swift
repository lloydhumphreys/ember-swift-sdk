import Foundation

/// A hold on a room's socket, from `RoomSession.open()`: the socket opens with a session's first
/// lease and closes with its last. Each screen showing the room keeps one while it's shown.
///
/// Closing twice is the same as once, and a lease that's let go of closes itself.
@MainActor public final class RoomLease {
    private let hold: Hold

    init(_ session: RoomSession) {
        hold = Hold(session)
    }

    deinit {
        // A lease is nearly always let go of on the main actor, where it can close at once; elsewhere
        // it closes as soon as the main actor gets to it.
        let hold = hold
        if Thread.isMainThread {
            MainActor.assumeIsolated { hold.close() }
        } else {
            Task { @MainActor in hold.close() }
        }
    }

    /// Whether `close()` has been called (or the lease let go of).
    public var isClosed: Bool { hold.isClosed }

    /// Lets go of the room. Nothing when closed already.
    public func close() {
        hold.close()
    }
}

/// What a lease holds, kept apart from it so its deinit can reach it.
@MainActor private final class Hold {
    private weak var session: RoomSession?
    private(set) var isClosed = false

    init(_ session: RoomSession) {
        self.session = session
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        session?.leaseClosed()
    }
}

import Foundation

/// A clock that only moves when a test says so, for `EmberTiming(clock:)`: a 25-second heartbeat
/// or a 15-second backoff passes with one `advance(by:)`. Safe to use from any thread.
public final class ManualClock: Clock, @unchecked Sendable {
    /// A moment on the clock: how long after it started.
    public struct Instant: InstantProtocol, Sendable {
        /// How long after the clock started.
        public var offset: Duration

        /// The moment `offset` after the clock started.
        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    /// A clock at zero.
    public init() {}

    /// Now, as far as this clock has been moved.
    public var now: Instant {
        lock.withLock { current }
    }

    /// Nothing smaller than an instant.
    public var minimumResolution: Duration { .zero }

    /// How many sleeps are waiting for the clock to move.
    public var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    /// How many sleeps are waiting that moving the clock on by `duration` would wake. A sleep started
    /// on a task of its own is waiting only a moment after whatever started it, and one that starts
    /// after a move is due a whole `duration` after it, so a test waits for this before the move.
    public func sleeperCount(dueWithin duration: Duration) -> Int {
        lock.withLock {
            let horizon = current.advanced(by: duration)
            return sleepers.values.filter { $0.deadline <= horizon }.count
        }
    }

    /// Sleeps until the clock has been moved to `deadline`. Cancelling it throws `CancellationError`.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper }
                cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration`, waking every sleep that's due, soonest first.
    public func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

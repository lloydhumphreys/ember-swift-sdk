import EmberTesting
import Foundation
import Testing

/// Waits, on the real clock, until `condition` holds, for work the test can't await directly:
/// a socket's loop, a frame on its way through the main actor. False if it never does.
@MainActor
func eventually(within timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Gives the main actor and the sockets' tasks a moment, before checking that nothing happened.
@MainActor
func settle() async {
    try? await Task.sleep(for: .milliseconds(40))
}

extension ManualClock {
    /// Waits, on the real clock, until `count` sleeps are waiting that moving this clock on by
    /// `duration` would wake. The SDK's timers each sleep on a task of their own, so one a test has
    /// just set going (a reconnect's backoff, a send's timeout) is waiting only some time later, and
    /// a clock moved before then leaves it waiting its whole length after the move. False if they
    /// never are.
    @MainActor func sleeping(_ count: Int = 1, dueWithin duration: Duration) async -> Bool {
        await eventually { sleeperCount(dueWithin: duration) >= count }
    }

    /// Moves this clock on by `duration` once `count` sleeps it wakes are waiting, for a test that
    /// counts on a timer firing. False, with the clock left where it was, if they never are.
    @MainActor func pass(_ duration: Duration, waking count: Int = 1) async -> Bool {
        guard await sleeping(count, dueWithin: duration) else { return false }
        advance(by: duration)
        return true
    }
}

/// Timing on a clock that only moves when the test says, with backoff never spread (`random` is ½).
func manualTiming() -> (EmberTiming, ManualClock) {
    let clock = ManualClock()
    return (EmberTiming(clock: clock, random: { 0.5 }), clock)
}

/// A JSON body as an object.
func object(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

extension MockSocketConnection {
    /// The frames the client sent of one `type`.
    func sent(_ type: String) -> [ClientFrame] {
        sentClientFrames.filter { $0.type == type }
    }
}

extension URLRequest {
    /// The request's query, as sent.
    var query: String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }
}

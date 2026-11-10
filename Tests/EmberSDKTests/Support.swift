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
        sentFrames.filter { $0.type == type }
    }
}

extension URLRequest {
    /// The request's query, as sent.
    var query: String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }
}

import Foundation

/// Every interval the SDK waits on, in one place, with the web client's values as defaults.
///
/// Tests pass `clock` a clock they move by hand (EmberTesting's `ManualClock`) and `random` a fixed
/// value, so a 25-second heartbeat or a 15-second backoff takes no time at all and always the same.
public struct EmberTiming: Sendable {
    /// How often an open socket pings; a ping that hears nothing back by the next one reconnects.
    public var heartbeat: Duration
    /// How long a socket has to open before it's tried again.
    public var connectTimeout: Duration
    /// The first wait before reconnecting, doubled each try.
    public var backoffBase: Duration
    /// The longest wait before reconnecting.
    public var backoffMax: Duration
    /// A typing start goes to the room at most this often.
    public var typingThrottle: Duration
    /// A composer left alone this long counts as no longer typing.
    public var typingPause: Duration
    /// Where every wait sleeps.
    public var clock: any Clock<Duration>
    /// A number in 0..<1, for spreading reconnects.
    public var random: @Sendable () -> Double

    /// Timing with the given values; anything left out is as the web client has it.
    public init(
        heartbeat: Duration = .seconds(25),
        connectTimeout: Duration = .seconds(10),
        backoffBase: Duration = .milliseconds(500),
        backoffMax: Duration = .seconds(15),
        typingThrottle: Duration = .seconds(1),
        typingPause: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.heartbeat = heartbeat
        self.connectTimeout = connectTimeout
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.typingThrottle = typingThrottle
        self.typingPause = typingPause
        self.clock = clock
        self.random = random
    }

    /// The web client's timing, on the real clock.
    public static let standard = EmberTiming()

    /// How long to wait before reconnecting after `attempt` failed tries in a row (0 for the first):
    /// `min(max, base·2^attempt)`, give or take a quarter.
    public func backoff(attempt: Int) -> Duration {
        let doubled = backoffBase * Double(1 << min(max(attempt, 0), 20))
        let capped = min(doubled, backoffMax)
        return capped * (0.75 + random() / 2)
    }

    /// Sleeps for `duration` on `clock`.
    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

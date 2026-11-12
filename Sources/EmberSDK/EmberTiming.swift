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
    /// About how long a socket waits before reconnecting when the server asks it to (4001), give or
    /// take half, so a whole room's clients don't all come back in the same instant.
    public var reconnectFloor: Duration
    /// How long a connection has to stay open before its end backs off from the start again.
    public var stablePeriod: Duration
    /// The sidebar is read again on a reconnect at most this often.
    public var sidebarRefresh: Duration
    /// The directory is read again on a reconnect at most this often.
    public var directoryRefresh: Duration
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
        reconnectFloor: Duration = .milliseconds(250),
        stablePeriod: Duration = .seconds(10),
        sidebarRefresh: Duration = .seconds(10),
        directoryRefresh: Duration = .seconds(60),
        typingThrottle: Duration = .seconds(1),
        typingPause: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.heartbeat = heartbeat
        self.connectTimeout = connectTimeout
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.reconnectFloor = reconnectFloor
        self.stablePeriod = stablePeriod
        self.sidebarRefresh = sidebarRefresh
        self.directoryRefresh = directoryRefresh
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

    /// How long to wait before reconnecting when the server asks to: `reconnectFloor`, give or take half.
    public func reconnectDelay() -> Duration {
        reconnectFloor * (0.5 + random())
    }

    /// Sleeps for `duration` on `clock`.
    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

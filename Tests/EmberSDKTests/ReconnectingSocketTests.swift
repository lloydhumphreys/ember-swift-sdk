import EmberTesting
import Foundation
import Testing

/// The socket that keeps itself connected, on a clock the tests move.
@MainActor @Suite struct ReconnectingSocketTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock
    let network = MockNetworkPath()
    let socket: ReconnectingSocket
    let heard = Heard()

    init() {
        (timing, clock) = manualTiming()
        socket = ReconnectingSocket(connector: connector, timing: timing, network: network) {
            URLRequest(url: URL(string: "wss://ember.test/api/socket")!)
        }
        socket.onText = { [heard] in heard.texts.append($0) }
        socket.onStatus = { [heard] in heard.statuses.append($0) }
    }

    /// Waits for the socket to be waiting to try again after `connections` tries, `delay` from now:
    /// its one sleep is due by then, which, for a delay shorter than the connect timeout, tells the
    /// wait from a connect timeout that's about to be cancelled.
    func waitingToRetry(after connections: Int, in delay: Duration) async -> Bool {
        await eventually {
            connector.connections.count == connections && socket.status == .connecting
                && clock.sleeperCount == 1 && clock.sleeperCount(dueWithin: delay) == 1
        }
    }

    @Test func opens() async {
        #expect(socket.status == .idle)
        socket.start()
        #expect(socket.status == .connecting)
        #expect(await eventually { socket.status == .open })
        #expect(connector.connections.count == 1)
        #expect(heard.statuses == [.connecting, .open])
    }

    @Test func waitsForTheUpgrade() async {
        connector.autoOpen = false
        socket.start()
        #expect(await eventually { connector.connections.count == 1 })
        await settle()
        #expect(socket.status == .connecting)
        connector.latest?.open()
        #expect(await eventually { socket.status == .open })
    }

    @Test func deliversTextInOrderWithoutPongs() async {
        connector.onConnect { connection in
            connection.serverSends(#"{"type":"a"}"#)
            connection.serverSends(#"{"type":"pong"}"#)
            connection.serverSends(#"{"type":"b"}"#)
        }
        socket.start()
        #expect(await eventually { heard.texts.count == 2 })
        connector.latest?.serverSends(#"{"type":"c"}"#)
        #expect(await eventually { heard.texts.count == 3 })
        #expect(heard.texts == [#"{"type":"a"}"#, #"{"type":"b"}"#, #"{"type":"c"}"#])
    }

    @Test func sendsOnlyWhenOpen() async {
        #expect(!socket.send("early"))
        socket.start()
        #expect(await eventually { socket.status == .open })
        #expect(socket.send("one"))
        #expect(socket.send("two"))
        #expect(await eventually { connector.latest?.sent == ["one", "two"] })
        socket.stop()
        #expect(!socket.send("late"))
        #expect(connector.latest?.isClosedByClient == true)
    }

    @Test func aFailedSendEndsTheConnectionAndReconnects() async throws {
        socket.start()
        #expect(await eventually { socket.status == .open })
        let first = try #require(connector.latest)
        first.failSends()
        #expect(socket.send("lost"))
        // The failure closes the connection, so nothing after it is taken as sent.
        #expect(await eventually { first.isClosedByClient })
        #expect(!socket.send("after"))
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })
        #expect(socket.send("again"))
        #expect(await eventually { connector.latest?.sent == ["again"] })
        #expect(first.sent.isEmpty)
    }

    @Test func pingsAndReconnectsWhenAPingGoesUnanswered() async throws {
        socket.start()
        #expect(await eventually { socket.status == .open && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(25))
        let first = try #require(connector.latest)
        #expect(await eventually { first.sent == [ReconnectingSocket.ping] })

        // Answered: the next beat pings again.
        first.serverSends(Fixtures.WorkspaceFrames.pong)
        first.serverSends(#"{"type":"heard"}"#)
        #expect(await eventually { heard.texts == [#"{"type":"heard"}"#] && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(25))
        #expect(await eventually { first.sent.count == 2 })

        // Unanswered: the next beat gives up on the socket and connects again.
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(25))
        #expect(await eventually { first.isClosedByClient })
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })
    }

    @Test func reconnectsWithBackoff() async {
        socket.start()
        #expect(await eventually { socket.status == .open })

        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(499))
        await settle()
        #expect(connector.connections.count == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })

        // A socket that closes before the server says anything is backed off from further.
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 2, in: .seconds(1)))
        clock.advance(by: .milliseconds(999))
        await settle()
        #expect(connector.connections.count == 2)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { connector.connections.count == 3 && socket.status == .open })

        // Hearing from the server isn't enough to start the backoff over: a server that welcomes a
        // socket and drops it keeps being backed off from.
        connector.latest?.serverSends(#"{"type":"welcome"}"#)
        #expect(await eventually { heard.texts.count == 1 })
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 3, in: .seconds(2)))
        clock.advance(by: .milliseconds(1999))
        await settle()
        #expect(connector.connections.count == 3)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { connector.connections.count == 4 && socket.status == .open })

        // Staying up for the stable period is.
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: timing.stablePeriod)
        await settle()
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 4, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 5 })
    }

    @Test func backoffDoublesUpToTheMaximumAndSpreads() {
        #expect(timing.backoff(attempt: 0) == .milliseconds(500))
        #expect(timing.backoff(attempt: 3) == .seconds(4))
        #expect(timing.backoff(attempt: 10) == .seconds(15))
        let low = EmberTiming(random: { 0 })
        #expect(low.backoff(attempt: 0) == .milliseconds(375))
    }

    @Test func aConnectThatHangsTimesOut() async {
        connector.autoOpen = false
        socket.start()
        #expect(await eventually { connector.connections.count == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(10))
        #expect(await eventually { connector.connections.first?.isClosedByClient == true })
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
    }

    @Test func reconnectsSoonWhenAskedTo() async {
        socket.start()
        #expect(await eventually { socket.status == .open })
        connector.latest?.serverSends(#"{"type":"welcome"}"#)
        #expect(await eventually { heard.texts.count == 1 })
        connector.latest?.serverCloses(code: SocketClose.reconnect)
        // Not in the same instant: a whole room's clients would all come back at once.
        #expect(await waitingToRetry(after: 1, in: timing.reconnectFloor))
        #expect(timing.reconnectDelay() == .milliseconds(250))
        clock.advance(by: .milliseconds(249))
        await settle()
        #expect(connector.connections.count == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })
    }

    @Test func theReconnectWaitIsSpread() {
        #expect(EmberTiming(random: { 0 }).reconnectDelay() == .milliseconds(125))
        #expect(EmberTiming(random: { 0.999 }).reconnectDelay() < .milliseconds(375))
    }

    @Test func aServerThatKeepsAskingToReconnectIsBackedOffFrom() async {
        connector.onConnect { connection in connection.serverCloses(code: SocketClose.reconnect) }
        socket.start()
        #expect(await waitingToRetry(after: 1, in: timing.reconnectFloor))
        clock.advance(by: .milliseconds(250))
        // Asked again with nothing heard between: an ordinary failure, backed off from.
        #expect(await waitingToRetry(after: 2, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(499))
        await settle()
        #expect(connector.connections.count == 2)
        clock.advance(by: .milliseconds(1))
        #expect(await waitingToRetry(after: 3, in: .seconds(1)))
        clock.advance(by: .milliseconds(999))
        await settle()
        #expect(connector.connections.count == 3)
        clock.advance(by: .milliseconds(1))
        #expect(await waitingToRetry(after: 4, in: .seconds(2)))
    }

    @Test(arguments: [
        (SocketClosed(closeCode: 4003), ReconnectingSocket.StopReason.signedOut),
        (SocketClosed(closeCode: 4004), .notFound),
        (SocketClosed(httpStatus: 401), .signedOut),
        (SocketClosed(httpStatus: 403), .refused(status: 403)),
        (SocketClosed(httpStatus: 404), .refused(status: 404)),
        (SocketClosed(httpStatus: 400), .refused(status: 400)),
    ])
    func stopsWhenTheServerSaysNotToComeBack(closed: SocketClosed, reason: ReconnectingSocket.StopReason) async {
        connector.autoOpen = closed.httpStatus == nil
        socket.start()
        #expect(await eventually { connector.connections.count == 1 })
        connector.latest?.serverCloses(code: closed.closeCode, httpStatus: closed.httpStatus)
        #expect(await eventually { socket.status == .stopped(reason) })
        clock.advance(by: .seconds(60))
        await settle()
        #expect(connector.connections.count == 1)
        #expect(clock.sleeperCount == 0)

        // Starting again tries again.
        connector.autoOpen = true
        socket.start()
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })
    }

    @Test(arguments: [503, 500, 408, 429])
    func anUpgradeRefusedForNowIsTriedAgain(status: Int) async {
        connector.autoOpen = false
        socket.start()
        #expect(await eventually { connector.connections.count == 1 })
        connector.latest?.serverCloses(httpStatus: status)
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
    }

    // MARK: The network

    @Test func triesAgainAsSoonAsTheNetworkIsBack() async {
        socket.start()
        #expect(await eventually { socket.status == .open && network.listenerCount == 1 })
        network.set(available: false)
        #expect(await eventually { !socket.isNetworkAvailable })
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 1, in: timing.backoffMax))
        clock.advance(by: .seconds(1))
        await settle()
        #expect(connector.connections.count == 1)
        network.set(available: true)
        #expect(await eventually { connector.connections.count == 2 && socket.status == .open })
        #expect(socket.isNetworkAvailable)
    }

    @Test func doesntSpendTheBackoffWhileOffline() async {
        socket.start()
        #expect(await eventually { network.listenerCount == 1 })
        network.set(available: false)
        #expect(await eventually { !socket.isNetworkAvailable })
        for tries in 1...3 {
            #expect(await eventually { connector.connections.count == tries && socket.status == .open })
            connector.latest?.serverCloses(code: 1006)
            #expect(await waitingToRetry(after: tries, in: timing.backoffMax))
            clock.advance(by: timing.backoffMax)
        }
        // Back online, the next failure waits the first backoff, not the fourth.
        #expect(await eventually { connector.connections.count == 4 && socket.status == .open })
        network.set(available: true)
        #expect(await eventually { socket.isNetworkAvailable })
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 4, in: .milliseconds(500)))
        clock.advance(by: .milliseconds(500))
        #expect(await eventually { connector.connections.count == 5 })
    }

    @Test func stopsListeningToTheNetworkWhenStopped() async {
        socket.start()
        #expect(await eventually { network.listenerCount == 1 })
        socket.stop()
        #expect(await eventually { network.listenerCount == 0 })
    }

    @Test func stoppingMidBackoffReallyStops() async {
        socket.start()
        #expect(await eventually { socket.status == .open })
        connector.latest?.serverCloses(code: 1006)
        #expect(await waitingToRetry(after: 1, in: .milliseconds(500)))
        socket.stop()
        #expect(socket.status == .idle)
        #expect(await eventually { clock.sleeperCount == 0 })
        clock.advance(by: .seconds(60))
        await settle()
        #expect(connector.connections.count == 1)
        #expect(socket.status == .idle)
    }

    @Test func stoppingWhileConnectingReallyStops() async {
        connector.autoOpen = false
        socket.start()
        #expect(await eventually { connector.connections.count == 1 })
        socket.stop()
        connector.latest?.open()
        await settle()
        #expect(socket.status == .idle)
        #expect(connector.latest?.isClosedByClient == true)
    }

    @Test func eachTryAsksForTheRequestAgain() async {
        var asked = 0
        let socket = ReconnectingSocket(connector: connector, timing: timing) {
            asked += 1
            return URLRequest(url: URL(string: "wss://ember.test/api/rooms/r/socket?try=\(asked)")!)
        }
        socket.start()
        #expect(await eventually { socket.status == .open })
        connector.latest?.serverCloses(code: SocketClose.reconnect)
        #expect(await eventually { socket.status == .connecting && clock.sleeperCount == 1 })
        clock.advance(by: timing.reconnectFloor)
        #expect(await eventually { connector.connections.count == 2 })
        #expect(connector.connections.map { $0.request.query } == ["try=1", "try=2"])
        socket.stop()
    }
}

/// What a socket's callbacks heard.
@MainActor final class Heard {
    var texts: [String] = []
    var statuses: [ReconnectingSocket.Status] = []
}

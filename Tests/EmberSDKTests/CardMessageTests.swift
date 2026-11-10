import EmberTesting
import Foundation
import Testing

/// A bot's cards, from the server's JSON to a room's timeline.
@MainActor @Suite struct CardMessageTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    @Test func aRoomShowsTheCardsItIsWelcomedWithAndSent() async throws {
        connector.welcomeEverySocket(messages: Fixtures.messages(1) + [Fixtures.cardMessage("m002", minute: 2)])
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        let socket = try #require(connector.latest)
        #expect(session.timeline.messages.map(\.cards) == [nil, [Fixtures.deployCard]])

        let alert = Fixtures.cardMessage("m003", cards: [Fixtures.alertCard], plainText: "[FIRING:1] HighCPU", minute: 3)
        socket.serverSends(Fixtures.RoomFrames.messageCreated(alert, seq: 11))
        #expect(await eventually { session.timeline.messages.last?.id == "m003" })
        #expect(session.timeline.messages.last?.cards == [Fixtures.alertCard])
        #expect(session.timeline.messages.last?.cards?.first?.accent == .danger)
    }
}

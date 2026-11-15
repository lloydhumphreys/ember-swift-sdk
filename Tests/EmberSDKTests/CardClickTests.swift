import EmberTesting
import Foundation
import Testing

/// Clicks on cards' buttons that act: what goes on the room's socket, and each way a click ends.
@MainActor @Suite struct CardClickTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming

    init() {
        var (timing, _) = manualTiming()
        timing.connectTimeout = .seconds(1_000_000)
        self.timing = timing
    }

    func opened() async throws -> (RoomSession, MockSocketConnection) {
        connector.welcomeEverySocket(messages: [Fixtures.cardMessage("m001", cards: [Fixtures.approvalCard])])
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: MemoryUnsentMessageStore())
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.phase == .admitted })
        return (session, try #require(connector.latest))
    }

    @Test func aClickSaysWhichButtonAndFinishesOnceTheBotHasTakenIt() async throws {
        let (session, socket) = try await opened()
        let click = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        let sent = socket.sentClicks[0]
        #expect(sent.string("messageId") == "m001")
        #expect(sent.string("actionId") == "approve")
        #expect(sent.string("blockId") == "deploy_actions")
        #expect(sent.string("value") == "web-2.4.1")
        #expect(sent.string("clickId")?.isEmpty == false)
        socket.answerClick()
        try await click.value
        #expect(session.notice == nil)
    }

    @Test func aButtonWithoutABlockOrValueSendsNeither() async throws {
        let (session, socket) = try await opened()
        let click = Task { try await session.click(Fixtures.logsAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        #expect(socket.sentClicks[0]["blockId"] == nil && socket.sentClicks[0]["value"] == nil)
        socket.answerClick()
        try await click.value
    }

    @Test func eachClickHearsOnlyItsOwnAnswer() async throws {
        let (session, socket) = try await opened()
        let first = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        let second = Task { try await session.click(Fixtures.holdAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 2 })
        let firstID = try #require(socket.sentClicks[0].string("clickId"))
        #expect(firstID != socket.sentClicks[1].string("clickId"))
        socket.refuseClick("Wait for your earlier clicks to be answered")
        await #expect(throws: EmberError(kind: .refused, message: "Wait for your earlier clicks to be answered")) { try await second.value }
        socket.serverSends(Fixtures.RoomFrames.cardClicked(ClickID(firstID)))
        try await first.value
    }

    @Test func aRefusalIsThrownToTheClickAndIsntANotice() async throws {
        let (session, socket) = try await opened()
        let click = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        socket.refuseClick()
        await #expect(throws: EmberError(kind: .refused, message: "That button is no longer there")) { try await click.value }
        #expect(session.notice == nil)
    }

    @Test func aClicksRefusalIsntAnEditsThoughTheyWereSentTogether() async throws {
        let (session, socket) = try await opened()
        let deletion = Task { try await session.delete(message: "m001") }
        try #require(await eventually { socket.sentTypes.contains("message.delete") })
        let click = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        let clickID = try #require(socket.sentClicks[0].string("clickId"))
        socket.serverSends(Fixtures.RoomFrames.error("That click couldn’t be delivered", clickId: ClickID(clickID), failed: "card.click"))
        await #expect(throws: EmberError(kind: .refused, message: "That click couldn’t be delivered")) { try await click.value }
        socket.serverSends(Fixtures.RoomFrames.messageDeleted("m001", seq: 11))
        try await deletion.value
    }

    @Test func anAnswerToAClickNoOneIsWaitingForIsLeftAlone() async throws {
        let (session, socket) = try await opened()
        socket.serverSends(Fixtures.RoomFrames.error("That button is no longer there", clickId: "k-old"))
        socket.serverSends(Fixtures.RoomFrames.cardClicked("k-old"))
        await settle()
        #expect(session.notice == nil)
    }

    @Test func aClickBeforeTheRoomLetsTheSocketInIsntSent() async throws {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: MemoryUnsentMessageStore())
        await #expect(throws: EmberError(kind: .unreachable, message: RoomSession.notConnected)) {
            try await session.click(Fixtures.approveAction, on: "m001")
        }
        #expect(connector.connections.isEmpty)
    }

    @Test func aClickTheRoomWouldntTakeIsntSent() async throws {
        let (session, socket) = try await opened()
        for (action, messageID) in [
            (CardAction(id: ""), MessageID("m001")),
            (CardAction(id: "approve", blockId: ""), "m001"),
            (CardAction(id: "approve", value: String(repeating: "x", count: CardAction.maxValueLength + 1)), "m001"),
            (Fixtures.approveAction, MessageID(String(repeating: "m", count: 65))),
            (Fixtures.approveAction, ""),
        ] {
            await #expect(throws: EmberError(kind: .invalid, message: "That button can’t be clicked.")) {
                try await session.click(action, on: messageID)
            }
        }
        #expect(socket.sentClicks.isEmpty)
    }

    @Test func aClickWhoseSocketDropsFails() async throws {
        let (session, socket) = try await opened()
        let click = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        socket.serverCloses()
        await #expect(throws: EmberError(kind: .unreachable, message: RoomSession.notConnected)) { try await click.value }
    }

    @Test func aClickTheRoomLetsInAgainBeforeAnsweringHasLostItsAnswer() async throws {
        let (session, socket) = try await opened()
        let click = Task { try await session.click(Fixtures.approveAction, on: "m001") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        socket.serverSends(Fixtures.RoomFrames.welcome(you: Fixtures.me.user, messages: Fixtures.messages(3), seq: 10))
        await #expect(throws: EmberError(kind: .unreachable, message: RoomSession.clickLost)) { try await click.value }
        // The answer that comes after changes nothing.
        socket.answerClick()
        await settle()
        #expect(session.notice == nil)
    }

    @Test func aClickInAThreadGoesOnTheRoomsSocket() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let click = Task { try await thread.click(Fixtures.holdAction, on: "m002") }
        try #require(await eventually { socket.sentClicks.count == 1 })
        #expect(socket.sentClicks[0].string("messageId") == "m002")
        socket.answerClick()
        try await click.value
    }
}

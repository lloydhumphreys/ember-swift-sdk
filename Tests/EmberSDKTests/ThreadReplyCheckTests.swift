import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

@MainActor @Suite struct ThreadReplyCheckTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock
    let parent = Fixtures.withThread(Fixtures.message("m001", "Message 1", minute: 1), count: 1)

    init() { (timing, clock) = manualTiming() }

    /// A thread's text held behind a file is released while the thread's check (sent before the
    /// release) is still unanswered: the check's `missing` must not create it a second time, as it
    /// doesn't for a room message.
    @Test func aReleasedReplyIsntCreatedAgainByACheckSentBeforeIt() async throws {
        connector.welcomeEverySocket()
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        let socket = try #require(connector.latest)
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let ids = thread.send(files: [try file.source()], body: "<p>After</p>", plainText: "After")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: ids[0]))
        await gate.waitForRequest()

        // The thread opens while the file is going up: its check asks about the held text.
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent))
        #expect(await eventually { socket.sent("message.check").contains(where: { if case let .checkMessages(c) = $0 { c.contains(ids[1]) } else { false } }) })
        #expect(socket.sent("message.create").isEmpty)

        // The file finishes before the check's answer: the text goes.
        gate.release()
        #expect(await eventually { socket.sent("message.create").count == 1 })

        // The answer to the earlier check, sent before the create, says it's missing.
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [ids[1]]))
        await settle()
        #expect(socket.sent("message.create").count == 1)
        lease.close()
    }
}

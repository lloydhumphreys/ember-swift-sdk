import EmberRichText
import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Link previews going out with a message or a reply, and kept with it while it's unsent.
@MainActor @Suite struct SendingPreviewsTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let store = MemoryUnsentMessageStore()

    init() {
        (timing, _) = manualTiming()
        connector.welcomeEverySocket()
    }

    func opened() async throws -> (RoomSession, MockSocketConnection) {
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: store)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open && session.phase == .admitted })
        return (session, try #require(connector.latest))
    }

    var attachment: String { RichText.previewAttachment(Fixtures.linkPreview) }

    @Test func aMessageCarriesItsPreviewsAfterItsBody() async throws {
        let (session, socket) = try await opened()
        let id = session.send(body: "<p>https://example.com/engine</p>", plainText: "https://example.com/engine", previews: [Fixtures.linkPreview])
        let body = "<p>https://example.com/engine</p>" + attachment
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: body)] })
        #expect(session.timeline.pending.map(\.body) == [body])
        // Unsent, it's kept with its preview, so sending it again sends that too.
        try await session.flushUnsent()
        let key = UnsentMessageKey(server: URL(string: "https://ember.test")!, userID: Fixtures.ada.id, roomID: Fixtures.general.id)
        #expect(store.saved[key]?.map(\.body) == [body])
    }

    @Test func noPreviewsLeavesTheBodyAsItIs() async throws {
        let (session, socket) = try await opened()
        let id = session.send(body: "<p>Hi</p>", plainText: "Hi")
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Hi</p>")] })
    }

    @Test func plainTextCarriesPreviewsToo() async throws {
        let (session, socket) = try await opened()
        let id = try session.send(text: "Look", previews: [Fixtures.linkPreview])
        #expect(await eventually { socket.sent("message.create").count == 1 })
        let pending = try #require(session.timeline.pending.first)
        #expect(pending.clientMessageId == id)
        #expect(pending.body.hasPrefix("<p>Look"))
        #expect(pending.body.hasSuffix(attachment))
    }

    @Test func aReplyCarriesItsPreviews() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let id = thread.reply(body: "<p>Yes</p>", plainText: "Yes", previews: [Fixtures.linkPreview])
        #expect(await eventually {
            socket.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Yes</p>" + attachment, parentId: "m001", alsoSend: false)]
        })
        lease.close()
    }
}

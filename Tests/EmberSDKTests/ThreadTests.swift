import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Threads on a room's socket.
@MainActor @Suite struct ThreadTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock
    let parent = Fixtures.withThread(Fixtures.message("m001", "Message 1", minute: 1), count: 1)
    let bot = User(id: "user_bot", name: "Helper")

    init() {
        (timing, clock) = manualTiming()
    }

    func session() -> RoomSession {
        RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
    }

    /// A session whose every socket is welcomed, opened and admitted.
    func opened() async throws -> (RoomSession, MockSocketConnection) {
        connector.welcomeEverySocket()
        let session = session()
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return (session, try #require(connector.latest))
    }

    /// The parent IDs of the `thread.open` and `thread.close` frames `socket` sent, in order.
    func threadFrames(_ socket: MockSocketConnection) -> [String] {
        socket.sentFrames.compactMap {
            switch $0 {
            case let .openThread(id): "open \(id)"
            case let .closeThread(id): "close \(id)"
            default: nil
            }
        }
    }

    /// Drops `socket` and waits for the next connection, welcomed by `welcomeEverySocket`.
    func reconnect(_ session: RoomSession, from socket: MockSocketConnection) async throws -> MockSocketConnection {
        let count = connector.connections.count
        socket.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount >= 1 })
        clock.advance(by: timing.backoff(attempt: 0))
        try #require(await eventually { connector.connections.count == count + 1 && session.status == .open })
        let next = try #require(connector.latest)
        try #require(await eventually { session.isAdmitted })
        return next
    }

    @Test func aThreadOpensOnceTheRoomLetsTheSocketIn() async throws {
        connector.welcomeEverySocket()
        let session = session()
        let thread = session.thread("m001")
        let lease = thread.open()
        // The thread's lease holds the room's socket open by itself.
        #expect(await eventually { session.status == .open && session.isAdmitted })
        let socket = try #require(connector.latest)
        #expect(await eventually { threadFrames(socket) == ["open m001"] })

        let reply = Fixtures.reply("r001", "First", to: "m001", minute: 2, parentText: "Message 1")
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent, replies: [reply]))
        #expect(await eventually { thread.timeline.isLoaded })
        #expect(thread.timeline.parentMessage == parent)
        #expect(thread.timeline.replies == [reply])

        lease.close()
        #expect(await eventually { socket.isClosedByClient })
    }

    @Test func aThreadOpenedOnAnOpenSocketGoesAtOnce() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        #expect(await eventually { threadFrames(socket) == ["open m001"] })
        lease.close()
        #expect(await eventually { threadFrames(socket) == ["open m001", "close m001"] })
        // The room's own lease still holds the socket.
        #expect(!socket.isClosedByClient)
    }

    @Test func threadsOpenAgainAfterAWelcomeTheMostRecentLast() async throws {
        let (session, socket) = try await opened()
        let first = session.thread("m001")
        let second = session.thread("m002")
        let leases = [first.open(), second.open()]
        #expect(await eventually { threadFrames(socket) == ["open m001", "open m002"] })

        let next = try await reconnect(session, from: socket)
        #expect(await eventually { threadFrames(next) == ["open m001", "open m002"] })

        // Opening one again makes it the current one.
        let again = first.open()
        #expect(await eventually { threadFrames(next) == ["open m001", "open m002", "open m001"] })

        // The current one's last lease closing opens the next most recent in its place.
        leases[0].close()
        #expect(threadFrames(next).count == 3)
        again.close()
        #expect(await eventually { threadFrames(next) == ["open m001", "open m002", "open m001", "close m001", "open m002"] })
        _ = leases
    }

    @Test func threadsOpenAgainAfterAResumed() async throws {
        connector.onConnect { connection in
            if connection.request.query?.contains("since=") == true {
                connection.serverSends(Fixtures.RoomFrames.resumed(seq: 10))
            } else {
                connection.serverSends(Fixtures.RoomFrames.welcome())
            }
        }
        let session = session()
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        let socket = try #require(connector.latest)
        let lease = session.thread("m001").open()
        #expect(await eventually { threadFrames(socket) == ["open m001"] })

        let next = try await reconnect(session, from: socket)
        #expect(next.request.query?.contains("since=10") == true)
        #expect(await eventually { threadFrames(next) == ["open m001"] })
        lease.close()
    }

    @Test func aReplyGoesAtOnce() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let id = thread.reply(body: "<p>Yes</p>", plainText: "Yes")
        let also = thread.reply(body: "<p>Both</p>", plainText: "Both", alsoSend: true)
        #expect(await eventually {
            socket.sent("message.create") == [
                .createMessage(clientMessageId: id, body: "<p>Yes</p>", parentId: "m001", alsoSend: false),
                .createMessage(clientMessageId: also, body: "<p>Both</p>", parentId: "m001", alsoSend: true),
            ]
        })
        #expect(thread.timeline.pending.map(\.clientMessageId) == [id, also])
        // A reply doesn't touch the room's own pendings.
        #expect(session.timeline.pending.isEmpty)

        let reply = Fixtures.reply("r001", "Yes", to: "m001", by: Fixtures.ada, minute: 2, clientMessageId: id)
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent))
        socket.serverSends(Fixtures.RoomFrames.messageCreated(reply, seq: 11))
        #expect(await eventually { thread.timeline.pending.map(\.clientMessageId) == [also] })
        #expect(thread.timeline.replies == [reply])
        lease.close()
    }

    @Test func aReplyWrittenOfflineGoesOnceTheThreadOpensAgain() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent))
        #expect(await eventually { thread.timeline.isLoaded })

        socket.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount >= 1 })
        let id = thread.reply(body: "<p>Later</p>", plainText: "Later")
        #expect(socket.sent("message.create").isEmpty)

        clock.advance(by: timing.backoff(attempt: 0))
        #expect(await eventually { connector.connections.count == 2 })
        let next = try #require(connector.latest)
        #expect(await eventually { threadFrames(next) == ["open m001"] })
        next.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent))
        #expect(await eventually { next.sent("message.check").contains(.checkMessages(clientMessageIds: [id])) })
        next.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually {
            next.sent("message.create") == [.createMessage(clientMessageId: id, body: "<p>Later</p>", parentId: "m001", alsoSend: false)]
        })
        lease.close()
    }

    @Test func refusalsLandOnTheThread() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let id = thread.reply(body: "<p>No</p>", plainText: "No")
        socket.serverSends(Fixtures.RoomFrames.error("That’s too long.", clientMessageId: id, failed: "message.create"))
        #expect(await eventually { thread.timeline.pending.first?.failure == "That’s too long." })
        #expect(session.notice == nil)

        socket.serverSends(Fixtures.RoomFrames.error("Thread not found", failed: "thread.open"))
        #expect(await eventually { thread.notice == "Thread not found" })
        #expect(thread.timeline.notice == nil)
        #expect(session.notice == nil)

        thread.retry(id)
        #expect(await eventually { socket.sent("message.create").count == 2 })
        thread.discard(id)
        #expect(thread.timeline.pending.isEmpty)
        lease.close()
    }

    @Test func aThreadLetGoOfIsKeptUntilItsRepliesSettle() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let id = thread.reply(body: "<p>Bye</p>", plainText: "Bye")
        lease.close()
        #expect(session.threads.map(\.parentID) == ["m001"])
        #expect(session.thread("m001") === thread)

        let reply = Fixtures.reply("r001", "Bye", to: "m001", by: Fixtures.ada, minute: 2, clientMessageId: id)
        socket.serverSends(Fixtures.RoomFrames.messageCreated(reply, seq: 11))
        #expect(await eventually { thread.timeline.pending.isEmpty })
        #expect(await eventually { session.threads.isEmpty })
        #expect(session.thread("m001") !== thread)
    }

    @Test func aLingeringThreadOpensAgainOnlyToBeChecked() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        socket.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting && clock.sleeperCount >= 1 })
        thread.reply(body: "<p>Bye</p>", plainText: "Bye")
        lease.close()
        // The room's own lease keeps the socket coming back.
        clock.advance(by: timing.backoff(attempt: 0))
        #expect(await eventually { connector.connections.count == 2 })
        let next = try #require(connector.latest)
        #expect(await eventually { threadFrames(next) == ["open m001", "close m001"] })
    }

    @Test func aThreadsFileSaysWhichThread() async throws {
        let (session, _) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        let ids = thread.send(files: [try file.source()], body: "<p>See</p>", plainText: "See", alsoSend: true)
        let posted = Fixtures.fileMessage("r100", parentID: "m001", alsoSent: true, clientMessageId: ids[0])
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        #expect(thread.timeline.pending.map(\.clientMessageId) == ids)
        #expect(thread.timeline.pending.first?.upload != nil)
        #expect(session.timeline.pending.isEmpty)

        #expect(await eventually { thread.timeline.pending.count == 1 })
        let start = try #require(transport.lastBody("POST", uploads))
        #expect(start["parentId"] as? String == "m001")
        #expect(start["alsoSend"] as? Bool == true)
        #expect(thread.timeline.replies == [posted])
        // Also sent, so the room shows it too.
        #expect(session.timeline.messages.last == posted)
        let socket = try #require(connector.latest)
        #expect(await eventually {
            socket.sent("message.create") == [.createMessage(clientMessageId: ids[1], body: "<p>See</p>", parentId: "m001", alsoSend: true)]
        })
        lease.close()
    }

    @Test func aThreadKeepsAFileGoingAfterItsLetGoOf() async throws {
        let (session, _) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(thread.send(files: [try file.source()]).first)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: id))
        await gate.waitForRequest()
        lease.close()
        #expect(session.threads.count == 1)
        gate.release()
        #expect(await eventually { session.threads.isEmpty })
        #expect(thread.timeline.replies.map(\.id) == ["r100"])
    }

    @Test func aBotsTypingExpiresOnTheSessionsClock() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        socket.serverSends(Fixtures.RoomFrames.typing(bot, true, inThread: "m001"))
        socket.serverSends(Fixtures.RoomFrames.typing(bot, true, inThread: "m002"))
        #expect(await eventually { thread.timeline.typing == [bot] })
        // The room's own typing isn't the thread's.
        #expect(session.timeline.typing.isEmpty)

        clock.advance(by: .seconds(4))
        await settle()
        #expect(thread.timeline.typing == [bot])
        clock.advance(by: .seconds(2))
        #expect(await eventually { thread.timeline.typing.isEmpty })
        lease.close()
    }

    @Test func aThreadPagesBack() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let replies = (2 ... 4).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent, replies: replies, hasMore: true))
        #expect(await eventually { thread.timeline.isLoaded })

        thread.loadOlder()
        #expect(await eventually { socket.sent("thread.before") == [.threadBefore(parentId: "m001", before: "r002")] })
        let older = Fixtures.reply("r001", "Reply 1", to: "m001", minute: 1)
        socket.serverSends(Fixtures.RoomFrames.threadHistory("m001", before: "r002", replies: [older], hasMore: false))
        #expect(await eventually { thread.timeline.replies.first == older })
        #expect(!thread.timeline.hasMore)
        lease.close()
    }

    @Test func aTombstoneCanStillBeRepliedTo() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: Fixtures.tombstone("m001")))
        #expect(await eventually { thread.timeline.isLoaded })
        #expect(thread.timeline.parentMessage?.isDeleted == true)
        #expect(thread.timeline.canReply)
        lease.close()
    }

    // MARK: A second link into the thread

    /// The thread under m001, open on `socket` with `replies` and more before them.
    func openedThread(_ session: RoomSession, on socket: MockSocketConnection, replies: [Message], hasMore: Bool = false, at replyID: String? = nil) async throws -> (ThreadSession, ThreadLease) {
        let thread = session.thread("m001", at: replyID)
        let lease = thread.open()
        try #require(await eventually { threadFrames(socket).last == "open m001" })
        socket.serverSends(Fixtures.RoomFrames.threadOpened("m001", parent: parent, replies: replies, hasMore: hasMore))
        try #require(await eventually { thread.timeline.isLoaded })
        return (thread, lease)
    }

    @Test func aLinkToALoadedReplyFocusesIt() async throws {
        let (session, socket) = try await opened()
        let replies = (1 ... 3).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        let (thread, lease) = try await openedThread(session, on: socket, replies: replies)
        let id = thread.reply(body: "<p>Mine</p>", plainText: "Mine")
        #expect(thread.timeline.focus == nil)

        #expect(session.thread("m001", at: "r002") === thread)
        #expect(thread.timeline.focus == "r002")
        #expect(thread.timeline.replies == replies)
        #expect(thread.timeline.pending.map(\.clientMessageId) == [id])
        #expect(socket.sent("thread.before").isEmpty)
        thread.focusShown()
        #expect(thread.timeline.focus == nil)
        lease.close()
    }

    @Test func aLinkToAnOlderReplyPagesBackToIt() async throws {
        let (session, socket) = try await opened()
        let replies = (3 ... 4).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        let (thread, lease) = try await openedThread(session, on: socket, replies: replies, hasMore: true)
        let id = thread.reply(body: "<p>Mine</p>", plainText: "Mine")

        #expect(session.thread("m001", at: "r001") === thread)
        #expect(await eventually { socket.sent("thread.before") == [.threadBefore(parentId: "m001", before: "r003")] })
        #expect(thread.timeline.focus == nil)
        let older = (1 ... 2).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        socket.serverSends(Fixtures.RoomFrames.threadHistory("m001", before: "r003", replies: older, hasMore: false))
        #expect(await eventually { thread.timeline.focus == "r001" })
        #expect(thread.timeline.replies.map(\.id) == ["r001", "r002", "r003", "r004"])
        #expect(thread.timeline.pending.map(\.clientMessageId) == [id])
        lease.close()
    }

    @Test func aLinkWithNoReplyLeavesTheThreadWhereItIs() async throws {
        let (session, socket) = try await opened()
        let replies = (1 ... 3).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        let (thread, lease) = try await openedThread(session, on: socket, replies: replies, at: "r002")
        #expect(thread.timeline.focus == "r002")

        // Not shown yet: it stays.
        #expect(session.thread("m001") === thread)
        #expect(thread.timeline.focus == "r002")
        // Shown: it doesn't come back.
        thread.focusShown()
        #expect(session.thread("m001") === thread)
        #expect(thread.timeline.focus == nil)
        #expect(socket.sent("thread.before").isEmpty)
        lease.close()
    }

    @Test func aLinkIntoALingeringThreadKeepsItsFileGoing() async throws {
        let (session, socket) = try await opened()
        let replies = (1 ... 2).map { Fixtures.reply(String(format: "r%03d", $0), "Reply \($0)", to: "m001", minute: $0) }
        let (thread, lease) = try await openedThread(session, on: socket, replies: replies)
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(thread.send(files: [try file.source()]).first)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: id))
        await gate.waitForRequest()
        lease.close()

        #expect(session.thread("m001", at: "r001") === thread)
        #expect(thread.timeline.focus == "r001")
        #expect(thread.timeline.pending.map(\.clientMessageId) == [id])
        gate.release()
        #expect(await eventually { thread.timeline.replies.map(\.id) == ["r001", "r002", "r100"] })
    }

    @Test func aThreadOnlyFileStaysOutOfTheRoom() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        let id = try #require(thread.send(files: [try file.source()]).first)
        let posted = Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)

        #expect(await eventually { thread.timeline.pending.isEmpty && thread.timeline.replies == [posted] })
        #expect(!session.timeline.messages.contains { $0.id == "r100" })
        #expect(session.timeline.pending.isEmpty)
        // The room's own frame for it doesn't put it there either.
        socket.serverSends(Fixtures.RoomFrames.messageCreated(posted, seq: 11))
        await settle()
        #expect(!session.timeline.messages.contains { $0.id == "r100" })
        #expect(thread.timeline.replies == [posted])
        lease.close()
    }
}

import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Holds an object without keeping it, to see when it goes.
@MainActor final class WeakBox<Object: AnyObject> {
    weak var object: Object?
    init(_ object: Object) { self.object = object }
}

/// How long sessions and threads live: shutting down, the workspace's cache letting go of them, and
/// what's left of them afterwards.
@MainActor @Suite struct SessionLifetimeTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let workspace: Workspace

    init() {
        let (timing, _) = manualTiming()
        self.timing = timing
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    /// A session of its own (not the workspace's), welcomed and admitted.
    func opened() async throws -> RoomSession {
        connector.welcomeEverySocket()
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.isAdmitted })
        return session
    }

    /// Lets go of the cache's idle sessions for `roomID` by using `idleSessionLimit` other rooms.
    func crowdOut() {
        for index in 0 ..< Workspace.idleSessionLimit { _ = workspace.session(for: "crowd-\(index)") }
    }

    // MARK: Shutting down

    @Test func shuttingDownLetsGoOfTheThreads() async throws {
        let session = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        // Never confirmed, so the thread stays on after its lease closes.
        thread.reply(body: "<p>Yes</p>", plainText: "Yes")
        lease.close()
        #expect(session.threads.count == 1)

        session.shutDown()
        #expect(session.threads.isEmpty)
        #expect(session.openThread == nil)
        // The reply stays pending, as the room's own messages do.
        #expect(thread.timeline.pending.map(\.plainText) == ["Yes"])
        // Nothing registers with the room again.
        let again = thread.open()
        thread.reply(body: "<p>And</p>", plainText: "And")
        #expect(session.threads.isEmpty)
        again.close()
    }

    /// A signed-in workspace with a room, a thread with a reply pending and a file going up in it,
    /// then signed out; answers the room and thread, held weakly.
    func signedOutWithAThread(file: TestFile) async throws -> (WeakBox<RoomSession>, WeakBox<ThreadSession>) {
        workspace.start()
        let session = workspace.session(for: Fixtures.general.id)
        let lease = session.open()
        try #require(await eventually { session.isAdmitted })
        let thread = session.thread("m001")
        let threadLease = thread.open()
        thread.reply(body: "<p>Yes</p>", plainText: "Yes")
        let gate = transport.hold("POST", uploads)
        thread.send(files: [try file.temporarySource()])
        await gate.waitForRequest()

        workspace.shutdown()
        #expect(session.threads.isEmpty)
        #expect(!file.exists)
        // The file's pending reply goes with it, rather than showing as going up for good.
        #expect(thread.timeline.pending.map(\.plainText) == ["Yes"])
        // The cancelled upload's task lets go of the session once its request answers.
        gate.release()
        threadLease.close()
        lease.close()
        return (WeakBox(session), WeakBox(thread))
    }

    @Test func signingOutLetsTheRoomAndItsThreadsGo() async throws {
        let file = try TestFile([1])
        defer { file.remove() }
        let (room, thread) = try await signedOutWithAThread(file: file)
        #expect(await eventually { room.object == nil && thread.object == nil })
    }

    // MARK: The cache letting go

    @Test func aSessionLetGoOfThatAScreenStillHoldsIsAnsweredAgain() {
        let screen = workspace.session(for: "kept")
        // The screen's lease has lapsed, but the screen still holds the session.
        screen.open().close()
        crowdOut()
        #expect(screen.onSignedOut == nil)

        #expect(workspace.session(for: "kept") === screen)
        #expect(screen.onSignedOut != nil)
    }

    @Test func aSessionLetGoOfAndOpenedAgainIsShutDownOnSigningOut() async throws {
        workspace.start()
        let screen = workspace.session(for: Fixtures.general.id)
        screen.open().close()
        crowdOut()
        #expect(screen.onSignedOut == nil)

        // The screen comes back and opens it, without asking the workspace.
        let lease = screen.open()
        #expect(await eventually { screen.status == .open })
        #expect(screen.onSignedOut != nil)
        #expect(workspace.session(for: Fixtures.general.id) === screen)

        workspace.shutdown()
        #expect(screen.status == .idle)
        #expect(screen.isShutDown)
        lease.close()
    }

    @Test func aSessionLetGoOfAndOpenedWhileStoppedWaitsForStart() async throws {
        workspace.start()
        let screen = workspace.session(for: Fixtures.general.id)
        screen.open().close()
        crowdOut()
        workspace.stop()

        let lease = screen.open()
        await settle()
        #expect(screen.status == .idle)
        workspace.start()
        #expect(await eventually { screen.status == .open })
        lease.close()
    }

    /// A session the cache lets go of, held weakly.
    func letGoOf() -> WeakBox<RoomSession> {
        let session = workspace.session(for: "gone")
        crowdOut()
        return WeakBox(session)
    }

    @Test func aSessionLetGoOfThatNothingHoldsGoes() async {
        let session = letGoOf()
        #expect(await eventually { session.object == nil })
        _ = workspace.session(for: "gone")
    }

    // MARK: Files of a session let go of

    @Test func aSessionLetGoOfKeepsNoFiles() async throws {
        let session = try await opened()
        let failed = try TestFile([1], name: "failed.txt")
        let going = try TestFile([2], name: "going.txt")
        defer { [failed, going].forEach { $0.remove() } }
        transport.stub("POST", uploads, status: 422, json: Fixtures.errorJSON("No."))
        session.send(files: [try failed.temporarySource()])
        #expect(await eventually { session.timeline.pending.first?.failure == "No." })
        let gate = transport.hold("POST", uploads)
        session.thread("m001").send(files: [try going.temporarySource()])
        await gate.waitForRequest()

        session.detach()
        #expect(!failed.exists)
        #expect(!going.exists)
        #expect(session.timeline.pending.isEmpty)
        #expect(session.running == nil && session.outgoing.isEmpty && session.failedUploads.isEmpty)
        #expect(session.threads.isEmpty)
        gate.release()
    }

    @Test func trimmingLeavesNoFileBehind() async throws {
        let session = workspace.session(for: Fixtures.general.id)
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads, status: 422, json: Fixtures.errorJSON("No."))
        let id = try #require(session.send(files: [try file.temporarySource()]).first)
        #expect(await eventually { session.timeline.pending.first?.failure == "No." })
        // The room has it after all, so nothing is left to retry and the session counts as idle.
        // The failed job goes as the confirmation lands, so trimming finds nothing left behind.
        session.handle(ServerFrame(text: Fixtures.RoomFrames.welcome(seq: 10)))
        session.handle(ServerFrame(text: Fixtures.RoomFrames.messageCreated(Fixtures.fileMessage("m100", clientMessageId: id), seq: 11)))
        #expect(session.timeline.pending.isEmpty)
        try #require(!session.isBusy)

        crowdOut()
        #expect(session.onSignedOut == nil)
        #expect(!file.exists)
        #expect(session.failedUploads.isEmpty)
    }
}

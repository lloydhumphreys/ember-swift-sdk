import EmberTesting
import Foundation
import Synchronization
import Testing
@testable import EmberSDK

/// How often welcomes read the sidebar again, what a sidebar change makes views hear, which page a
/// room opens on, and whether the workspace says the network is there.
@MainActor @Suite struct WorkspaceRefreshTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let network = MockNetworkPath()
    let clock: ManualClock
    let timing: EmberTiming
    let workspace: Workspace

    init() {
        var (timing, clock) = manualTiming()
        // No heartbeat falls due while the tests move the clock.
        timing.heartbeat = .seconds(1_000_000)
        self.clock = clock
        self.timing = timing
        transport.stubSignedIn()
        connector.welcomeEverySocket()
        let client = EmberClient.mock(transport: transport, connector: connector, timing: timing, network: network)
        workspace = Workspace(client: client, me: Fixtures.me, account: Fixtures.account)
    }

    var sidebarReads: Int { transport.requests("GET", "/api/sidebar").count }
    var directoryReads: Int { transport.requests("GET", "/api/users").count }

    /// Starts the workspace and waits until the loads its start and first welcome asked for are done.
    func started() async throws -> MockSocketConnection {
        workspace.start()
        try #require(await eventually { workspace.isLoaded && workspace.directoryStatus == .loaded && sidebarReads >= 2 })
        await settle()
        return try #require(connector.connections.first)
    }

    // MARK: Welcomes

    @Test func welcomesInQuickSuccessionReadTheSidebarOnceMoreAfterAWhile() async throws {
        let socket = try await started()
        let sidebar = sidebarReads
        let directory = directoryReads

        for _ in 0..<5 { socket.serverSends(Fixtures.WorkspaceFrames.welcome()) }
        await settle()
        #expect(sidebarReads == sidebar)

        #expect(await clock.pass(timing.sidebarRefresh))
        #expect(await eventually { sidebarReads == sidebar + 1 })
        await settle()
        #expect(sidebarReads == sidebar + 1)
        #expect(directoryReads == directory)
    }

    @Test func aWelcomeAfterTheSidebarRefreshReadsItAtOnce() async throws {
        let socket = try await started()
        let sidebar = sidebarReads
        clock.advance(by: timing.sidebarRefresh)
        socket.serverSends(Fixtures.WorkspaceFrames.welcome())
        #expect(await eventually { sidebarReads == sidebar + 1 })
    }

    @Test func theDirectoryIsReadAgainOnlyOnceItsRefreshHasPassed() async throws {
        let socket = try await started()
        let directory = directoryReads

        clock.advance(by: timing.sidebarRefresh)
        socket.serverSends(Fixtures.WorkspaceFrames.welcome())
        #expect(await eventually { transport.requests("GET", "/api/sidebar").count >= 3 })
        await settle()
        #expect(directoryReads == directory)

        clock.advance(by: timing.directoryRefresh)
        socket.serverSends(Fixtures.WorkspaceFrames.welcome())
        #expect(await eventually { directoryReads == directory + 1 })
    }

    @Test func stoppingDropsAWaitingRefresh() async throws {
        let socket = try await started()
        let sidebar = sidebarReads
        socket.serverSends(Fixtures.WorkspaceFrames.welcome())
        #expect(await clock.sleeping(dueWithin: timing.sidebarRefresh))
        workspace.stop()
        clock.advance(by: timing.sidebarRefresh)
        await settle()
        #expect(sidebarReads == sidebar)
    }

    // MARK: Sorting

    @Test func readingTheSidebarDoesntSortItAgain() async throws {
        _ = try await started()
        let sorts = workspace.sortCount
        for _ in 0..<10 {
            _ = workspace.sharedRooms
            _ = workspace.directRooms
            _ = workspace.unreadRooms
            _ = workspace.suggestedPeople
            _ = workspace.isFavorite(Fixtures.general.id)
        }
        #expect(workspace.sortCount == sorts)
    }

    @Test func aChangeSortsTheSidebarOnce() async throws {
        let socket = try await started()
        let sorts = workspace.sortCount
        socket.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.engines.id))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.unread == true })
        #expect(workspace.sortCount == sorts + 1)
    }

    @Test func aDMGoingUnreadDoesntChangeTheSharedRoomsOrStars() async throws {
        let socket = try await started()
        let heard = Flag()
        withObservationTracking {
            _ = workspace.sharedRooms
            _ = workspace.isFavorite(Fixtures.general.id)
        } onChange: {
            heard.set()
        }
        socket.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.directWithGrace.id))
        #expect(await eventually { workspace.room(Fixtures.directWithGrace.id)?.unread == true })
        #expect(!heard.value)
    }

    // MARK: Opening a room

    @Test func openingARoomAfterAJumpGoesBackToTheNewest() async throws {
        _ = try await started()
        let session = workspace.session(for: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded })
        let socket = try #require(connector.latest)

        _ = workspace.session(for: Fixtures.general.id, around: "m100")
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        try #require(await eventually { session.timeline.anchor == "m100" && !session.isJumping })

        #expect(workspace.session(for: Fixtures.general.id) === session)
        #expect(await eventually { socket.sent("history.around") == [.historyAround(messageId: "m100"), .historyAround(messageId: nil)] })
    }

    @Test func openingAThreadLeavesTheRoomOnItsPage() async throws {
        _ = try await started()
        let session = workspace.session(for: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded })
        let socket = try #require(connector.latest)

        _ = workspace.session(for: Fixtures.general.id, around: "m100")
        socket.serverSends(Fixtures.RoomFrames.historyAround(messages: Fixtures.messages(5, from: 98), around: "m100"))
        try #require(await eventually { session.timeline.anchor == "m100" && !session.isJumping })

        _ = workspace.thread("m100", in: Fixtures.general.id, at: "r1")
        await settle()
        #expect(socket.sent("history.around") == [.historyAround(messageId: "m100")])
        #expect(session.timeline.anchor == "m100")
    }

    // MARK: The network

    @Test func theWorkspaceSaysWhenTheNetworkIsGone() async throws {
        _ = try await started()
        #expect(workspace.isNetworkAvailable)
        network.set(available: false)
        #expect(await eventually { !workspace.isNetworkAvailable })
        network.set(available: true)
        #expect(await eventually { workspace.isNetworkAvailable })
    }
}

/// Whether something happened, from any thread.
private final class Flag: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

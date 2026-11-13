import EmberSDK
import EmberTesting
import Foundation
import Synchronization
import Testing

/// What a client runs on comes from its environment, whatever its transport is.
@MainActor @Suite struct EnvironmentTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()

    /// Where `FileUnsentMessageStore()` keeps files when given no folder.
    let defaultFolder = URL.applicationSupportDirectory.appending(path: "Ember/Unsent", directoryHint: .isDirectory)

    @Test func theSystemEnvironmentWithATransportOfItsOwnKeepsUnsentMessagesInFiles() throws {
        var environment = EmberEnvironment.system(cookies: EphemeralCookieStorage())
        environment.transport = Forwarding(to: transport)
        environment.connector = connector
        let client = EmberClient(origin: URL(string: "https://ember.test")!, environment: environment)

        let store = try #require(client.unsentStore as? FileUnsentMessageStore)
        #expect(store.folder == defaultFolder)
        // Never started or signed in, so it writes nothing there.
        let session = RoomSession(client: client, roomID: Fixtures.general.id)
        #expect(session.unsentStore === store)
    }

    @Test func theURLSessionClientsKeepUnsentMessagesInFiles() throws {
        let clients = [
            EmberClient(origin: URL(string: "https://ember.test")!),
            EmberClient(origin: URL(string: "https://ember.test")!, cookies: EphemeralCookieStorage()),
        ]
        for client in clients {
            let store = try #require(client.unsentStore as? FileUnsentMessageStore)
            #expect(store.folder == defaultFolder)
            #expect(store === FileUnsentMessageStore.shared)
            #expect(!store.includedInBackup)
            #expect(client.transport is URLSessionHTTPTransport)
        }
    }

    @Test func aWorkspacesSessionsUseTheClientsStoreAndBackgroundTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unsent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        let asked = Mutex<[String]>([])
        let ended = Mutex(0)
        let backgroundTime = BackgroundTime { reason in
            asked.withLock { $0.append(reason) }
            return { ended.withLock { $0 += 1 } }
        }
        transport.stubSignedIn()
        connector.welcomeEverySocket()
        // A transport the SDK doesn't know, as an app's own would be.
        let environment = EmberEnvironment.mock(transport: Forwarding(to: transport), connector: connector, unsentStore: store, backgroundTime: backgroundTime)
        let client = EmberClient(origin: URL(string: "https://ember.test")!, environment: environment)
        let workspace = Workspace(client: client, me: Fixtures.me, account: Fixtures.account)

        let session = workspace.session(for: Fixtures.general.id)
        #expect(session.unsentStore === store)
        let id = session.send(body: "<p>Early</p>", plainText: "Early")
        let key = UnsentMessageKey(server: client.origin, userID: Fixtures.me.id, roomID: Fixtures.general.id)
        try await session.flushUnsent()
        #expect(try store.messages(for: key).map(\.clientMessageId) == [id])

        let file = try TestFile([1], name: "photo.jpg")
        defer { file.remove() }
        let gate = transport.hold("POST", uploads)
        session.send(files: [try file.source(contentType: "image/jpeg")])
        await gate.waitForRequest()
        #expect(asked.withLock { $0 } == ["Sending photo.jpg"])
        #expect(ended.withLock { $0 } == 0)
        gate.release()
        #expect(await eventually { ended.withLock { $0 } == 1 })
        workspace.shutdown()
    }

    @Test func aSessionsOwnStoreWinsOverTheClients() {
        let clientStore = MemoryUnsentMessageStore()
        let own = MemoryUnsentMessageStore()
        let client = EmberClient.mock(connector: connector, unsentStore: clientStore)
        #expect(RoomSession(client: client, roomID: Fixtures.general.id).unsentStore === clientStore)
        #expect(RoomSession(client: client, roomID: Fixtures.general.id, unsentStore: own).unsentStore === own)
    }

    @Test func sessionsOnOneClientShareItsStoreAndKeepTheirRoomsApart() async throws {
        let store = MemoryUnsentMessageStore()
        let client = EmberClient.mock(connector: connector, unsentStore: store)
        let workspace = Workspace(client: client, me: Fixtures.me, account: Fixtures.account)
        let general = workspace.session(for: Fixtures.general.id)
        let engines = workspace.session(for: Fixtures.engines.id)
        let inGeneral = general.send(body: "<p>One</p>", plainText: "One")
        let inEngines = engines.send(body: "<p>Two</p>", plainText: "Two")
        let key = { (roomID: RoomID) in UnsentMessageKey(server: client.origin, userID: Fixtures.me.id, roomID: roomID) }
        try await workspace.flushUnsent()
        #expect(try store.messages(for: key(Fixtures.general.id)).map(\.clientMessageId) == [inGeneral])
        #expect(try store.messages(for: key(Fixtures.engines.id)).map(\.clientMessageId) == [inEngines])
        workspace.shutdown()
    }
}

/// An HTTP transport of an app's own, in front of a mock.
private struct Forwarding: HTTPTransport {
    let to: MockHTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await to.send(request)
    }
}

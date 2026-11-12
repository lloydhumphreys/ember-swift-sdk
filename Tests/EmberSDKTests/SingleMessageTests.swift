import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// `EmberClient.message(_:in:)`: one message, fetched once through a room socket that closes again.
@Suite struct SingleMessageTests {
    let connector = MockSocketConnector()
    let transport = MockHTTPTransport()
    let clock: ManualClock
    let client: EmberClient

    init() {
        let (timing, clock) = manualTiming()
        self.clock = clock
        client = EmberClient.mock(transport: transport, connector: connector, timing: timing)
    }

    private func welcome(_ messages: [Message]) {
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.welcome(messages: messages, around: "m002")) }
    }

    @Test func fetchesTheMessageFromTheWelcomeAroundIt() async throws {
        welcome(Fixtures.messages(5))
        let message = try await client.message("m002", in: "room-general")
        #expect(message.id == "m002")
        #expect(message.plainText == "Message 2")
    }

    @Test func opensAQuietSocketAroundTheMessageAndClosesItAfter() async throws {
        welcome(Fixtures.messages(3))
        _ = try await client.message("m002", in: "room-general")
        let connection = try #require(connector.latest)
        #expect(connector.connections.count == 1)
        #expect(connection.request.url?.path == "/api/rooms/room-general/socket")
        #expect(connection.request.query == "visible=0&protocol=4&around=m002")
        #expect(connection.isClosedByClient)
        #expect(connection.sent.isEmpty)
    }

    @Test func aMessageTheRoomDoesntHaveIs404() async {
        welcome(Fixtures.messages(3))
        let error = await #expect(throws: EmberError.self) { try await client.message("m999", in: "room-general") }
        #expect(error?.status == 404)
        #expect(error?.message == "That message isn’t in this room.")
        #expect(connector.latest?.isClosedByClient == true)
    }

    @Test func aDeletedMessageIs404() async {
        var gone = Fixtures.message("m002", "Gone")
        gone.deleted = true
        welcome([Fixtures.message("m001", "Before"), gone])
        let error = await #expect(throws: EmberError.self) { try await client.message("m002", in: "room-general") }
        #expect(error?.status == 404)
    }

    @Test func aRoomTheServerRefusesFailsWithThatStatus() async {
        connector.onConnect { $0.serverCloses(httpStatus: 404) }
        let error = await #expect(throws: EmberError.self) { try await client.message("m002", in: "room-nowhere") }
        #expect(error?.status == 404)
    }

    @Test func aSignedOutSocketIs401WithoutCallingTheSignedOutHandlers() async {
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        connector.onConnect { $0.serverCloses(httpStatus: 401) }
        let error = await #expect(throws: EmberError.self) { try await client.message("m002", in: "room-general") }
        #expect(error?.status == 401)
        #expect(signedOut.value == 0)
    }

    @Test func aSocketThatDropsIsUnreachable() async {
        connector.onConnect { $0.serverCloses() }
        let error = await #expect(throws: EmberError.self) { try await client.message("m002", in: "room-general") }
        #expect(error?.isUnreachable == true)
    }

    @Test func aServerThatNeverWelcomesTimesOutAndCloses() async throws {
        let task = Task { try await client.message("m002", in: "room-general") }
        let connection = await waitForConnection()
        for _ in 0 ..< 500 where clock.sleeperCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        clock.advance(by: .seconds(11))
        let error = await #expect(throws: EmberError.self) { try await task.value }
        #expect(error?.isUnreachable == true)
        #expect(connection.isClosedByClient)
    }

    @Test func anErrorFrameBeforeTheWelcomeFailsTheFetch() async {
        connector.onConnect { $0.serverSends(Fixtures.RoomFrames.error("Something went wrong.")) }
        let error = await #expect(throws: EmberError.self) { try await client.message("m002", in: "room-general") }
        #expect(error?.message == "Something went wrong.")
    }

    @Test func aMessageIdIsEscapedInTheSocketAddress() async throws {
        welcome([Fixtures.message("m 1/é", "Odd")])
        let message = try await client.message("m 1/é", in: "room-general")
        #expect(message.id == "m 1/é")
        #expect(connector.latest?.request.query?.hasSuffix("around=m%201%2F%C3%A9") == true)
    }

    private func waitForConnection() async -> MockSocketConnection {
        for _ in 0 ..< 500 {
            if let latest = connector.latest { return latest }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return MockSocketConnection(request: URLRequest(url: URL(string: "https://invalid.test")!))
    }
}

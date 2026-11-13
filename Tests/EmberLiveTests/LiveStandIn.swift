import EmberSDK
import Foundation
import Testing

/// Whether `EMBER_TEST_ORIGIN` is the stand-in in `Tools/mock-server` on this machine: a loopback
/// host that answers `GET /mock/outbox`. Tests that change accounts, ban people or reorder the
/// sidebar for everyone run only then, never against a real Ember. Worked out once, before any test.
let liveStandIn: Bool = {
    guard let origin = liveOrigin, let host = origin.host(percentEncoded: false),
          ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) else { return false }
    guard let data = try? Data(contentsOf: origin.appending(path: "mock/outbox")),
          let outbox = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return outbox["resetCodes"] is [Any]
}()

/// What the stand-in would have emailed. Its fields are secrets: compare them, never print them.
struct Outbox: Decodable {
    struct ResetCode: Decodable {
        let emailAddress: String
        let code: String
    }

    struct InvitationLink: Decodable {
        let emailAddress: String
        let link: String
    }

    let resetCodes: [ResetCode]
    let invitationLinks: [InvitationLink]
}

extension LiveTests {
    /// `GET /mock/outbox`, with a plain URLSession and no cookies.
    func outbox() async throws -> Outbox {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: origin.appending(path: "mock/outbox"))
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(Outbox.self, from: data)
    }

    /// A seeded account other than the one the tests use, signed in on a client of its own.
    func signedIn(as emailAddress: String, password: String? = nil) async throws -> EmberClient {
        let password = try #require(password ?? livePassword(), "Set EMBER_SEED_PASSWORD or write .dev/seed-password.")
        let client = freshClient()
        _ = try await client.signIn(emailAddress: emailAddress, password: password)
        return client
    }

    /// A started workspace for `client`, once it has loaded and its socket is open.
    @MainActor
    func loadedWorkspace(on client: EmberClient) async throws -> Workspace {
        let workspace = Workspace(client: client, me: try await client.me(), account: try await client.bootstrap().account)
        workspace.start()
        guard await eventually(within: .seconds(15), { workspace.isLoaded && workspace.connection == .open }) else {
            workspace.stop()
            Issue.record("The workspace didn't load.")
            throw CancellationError()
        }
        return workspace
    }

    /// Runs `body`, then `cleanUp` whether or not it threw.
    @MainActor
    func afterwards<T>(_ cleanUp: () async throws -> Void, _ body: () async throws -> T) async throws -> T {
        let result: T
        do {
            result = try await body()
        } catch {
            try? await cleanUp()
            throw error
        }
        try await cleanUp()
        return result
    }
}

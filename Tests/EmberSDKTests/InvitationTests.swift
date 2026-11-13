import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Inviting people by email, as an administrator.
@Suite struct InvitationTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    @Test func pendingInvitationsAreReadFromTheAccount() async throws {
        let invitations = [
            Fixtures.emailInvitation("inv_2", emailAddress: "charles@example.com"),
            Fixtures.emailInvitation("inv_1", emailAddress: "mary@example.com", delivery: .refused("Mailbox full")),
            Fixtures.emailInvitation("inv_0", emailAddress: "augusta@example.com", delivery: nil),
        ]
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON(invitations))
        #expect(try await client.invitations() == invitations)
    }

    @Test func someoneWhoIsntAnAdministratorHasNone() async throws {
        transport.stub("GET", "/api/account", json: json(without: "invitations", in: Fixtures.accountInvitationsJSON([])))
        #expect(try await client.invitations().isEmpty)
    }

    @Test func invitingSendsTheAddressesAndReadsEachOutcome() async throws {
        let emailed = Fixtures.emailInvitation("inv_1", emailAddress: "charles@example.com")
        let unsent = Fixtures.emailInvitation("inv_2", emailAddress: "mary@example.com", delivery: nil)
        let answer = json(["outcomes": [
            ["emailAddress": "grace@example.com", "member": true],
            ["emailAddress": "charles@example.com", "invitation": Fixtures.emailInvitationObject(emailed), "link": NSNull()],
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": "https://ember.test/join/invitation#token=fake-token"],
        ]])
        transport.stub("POST", "/api/invitations", json: answer)
        let outcomes = try await client.invite(emailAddresses: ["grace@example.com", "charles@example.com", "mary@example.com"])
        #expect(outcomes == [
            .member(emailAddress: "grace@example.com"),
            .invited(emailed, link: nil),
            .invited(unsent, link: Secret("https://ember.test/join/invitation#token=fake-token")),
        ])
        #expect(outcomes.map(\.emailAddress) == ["grace@example.com", "charles@example.com", "mary@example.com"])
        let request = try #require(transport.requests("POST", "/api/invitations").last)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        let body = try #require(transport.lastBody("POST", "/api/invitations"))
        #expect(body["emailAddresses"] as? [String] == ["grace@example.com", "charles@example.com", "mary@example.com"])
    }

    @Test func noneOrTooManyArentSent() async {
        for addresses in [[], (0 ... 20).map { "person\($0)@example.com" }] {
            let error = await #expect(throws: EmberError.self) { try await client.invite(emailAddresses: addresses) }
            #expect(error?.kind == .invalid)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func twentyAreSent() async throws {
        transport.stub("POST", "/api/invitations", json: #"{"outcomes":[]}"#)
        _ = try await client.invite(emailAddresses: (1 ... 20).map { "person\($0)@example.com" })
        #expect(transport.requests("POST", "/api/invitations").count == 1)
    }

    @Test func onlyAdministratorsInvite() async {
        transport.stub("POST", "/api/invitations", status: 403, json: Fixtures.errorJSON("Only administrators can invite people"))
        let error = await #expect(throws: EmberError.self) { try await client.invite(emailAddresses: ["charles@example.com"]) }
        #expect(error?.status == 403)
        #expect(error?.message == "Only administrators can invite people")
    }

    @Test func somethingThatIsntAnAddressIsRefused() async {
        transport.stub("POST", "/api/invitations", status: 422, json: Fixtures.errorJSON("Each must be an email address, such as ann@example.com"))
        let error = await #expect(throws: EmberError.self) { try await client.invite(emailAddresses: ["charles"]) }
        #expect(error?.status == 422)
        #expect(error?.message == "Each must be an email address, such as ann@example.com")
    }

    @Test func resendingAnswersTheNewLink() async throws {
        let invitation = Fixtures.emailInvitation("inv_1", delivery: nil)
        transport.stub("POST", "/api/invitations/inv_1/resend", json: json([
            "invitation": Fixtures.emailInvitationObject(invitation), "link": "https://ember.test/join/invitation#token=fake-new-token",
        ]))
        let resent = try await client.resendInvitation("inv_1")
        #expect(resent.invitation == invitation)
        #expect(resent.link?.revealed == "https://ember.test/join/invitation#token=fake-new-token")
        #expect(transport.requests("POST", "/api/invitations/inv_1/resend").last?.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
    }

    @Test func revokingDeletesIt() async throws {
        transport.stub("DELETE", "/api/invitations/inv_1", status: 204, json: "")
        try await client.revokeInvitation("inv_1")
        #expect(transport.requests("DELETE", "/api/invitations/inv_1").count == 1)
    }

    @Test func aGoneInvitationIsNotFound() async {
        transport.stub("DELETE", "/api/invitations/inv_9", status: 404, json: Fixtures.errorJSON("Not found"))
        let error = await #expect(throws: EmberError.self) { try await client.revokeInvitation("inv_9") }
        #expect(error?.status == 404)
    }

    @Test func anUnknownDeliveryStillReads() throws {
        var object = Fixtures.emailInvitationObject(Fixtures.emailInvitation())
        object["delivery"] = "queued"
        let invitation = Fixtures.decode(json(object), as: EmailInvitation.self)
        #expect(invitation.delivery == EmailInvitation.Delivery.unknown("queued"))
    }

    func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    func json(without key: String, in text: String) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        object[key] = nil
        return json(object)
    }
}

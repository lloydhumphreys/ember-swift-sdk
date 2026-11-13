import EmberSDK
import Foundation
import Testing

/// Email invitations: one made for an address of its own and revoked before the test ends.
extension LiveTests {
    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func invitesResendsAndRevokes() async throws {
        let client = try await signedIn()
        let before = try await client.invitations()
        let address = "live-\(UUID().uuidString.prefix(8).lowercased())@example.com"

        let outcomes = try await client.invite(emailAddresses: [address, liveEmail])
        #expect(outcomes.count == 2)
        let member = outcomes.contains { if case .member = $0 { $0.emailAddress == liveEmail } else { false } }
        #expect(member)
        let invited = outcomes.compactMap { outcome -> (EmailInvitation, Secret?)? in
            if case let .invited(invitation, link) = outcome { (invitation, link) } else { nil }
        }
        let (invitation, firstLink) = try #require(invited.first)
        var revoked = false
        try await afterwards({ if !revoked { try await client.revokeInvitation(invitation.id) } }) {
            #expect(invitation.emailAddress == address)
            #expect(invitation.expiresAt > invitation.createdAt)
            let link = try #require(firstLink)
            let linkIsTheOutboxs = try await outbox().invitationLinks.contains { $0.emailAddress == address && $0.link == link.revealed }
            #expect(linkIsTheOutboxs)
            let readsAsAJoinLink = link.revealed.contains("/join/invitation#token=")
            #expect(readsAsAJoinLink)

            let listed = try await client.invitations()
            #expect(listed.contains { $0.id == invitation.id && $0.emailAddress == address })
            #expect(listed.count == before.count + 1)

            let resent = try await client.resendInvitation(invitation.id)
            #expect(resent.invitation.id == invitation.id)
            let newLink = try #require(resent.link)
            let replaced = newLink != link
            #expect(replaced)
            let newLinkIsTheOutboxs = try await outbox().invitationLinks.contains { $0.emailAddress == address && $0.link == newLink.revealed }
            #expect(newLinkIsTheOutboxs)

            try await client.revokeInvitation(invitation.id)
            revoked = true
            let after = try await client.invitations()
            #expect(!after.contains { $0.id == invitation.id })
            #expect(after.map(\.id) == before.map(\.id))
            let gone = await #expect(throws: EmberError.self) { try await client.resendInvitation(invitation.id) }
            #expect(gone?.status == 404)
        }
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func onlyAdministratorsSeeAndSendInvitations() async throws {
        let client = try await signedIn()
        #expect(try await client.invitations().contains { $0.emailAddress == "first.guest@example.com" })
        let sam = try await signedIn(as: "sam@example.com")
        #expect(try await sam.invitations().isEmpty)
        let error = await #expect(throws: EmberError.self) {
            try await sam.invite(emailAddresses: ["live-\(UUID().uuidString.prefix(8).lowercased())@example.com"])
        }
        #expect(error?.status == 403)
    }
}

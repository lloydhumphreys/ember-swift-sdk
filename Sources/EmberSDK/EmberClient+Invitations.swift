import Foundation

extension EmberClient {
    /// The invitations no one has accepted yet, newest first, read from `GET /api/account`.
    /// Only administrators are shown any; everyone else gets none.
    public func invitations() async throws -> [EmailInvitation] {
        struct Settings: Decodable { var invitations: [EmailInvitation]? }
        return try await get("/api/account", as: Settings.self).invitations ?? []
    }

    /// `POST /api/invitations`: invites each address, as an administrator, answering what came of
    /// each in the order given. Ember emails each a link that works for 7 days, or answers the link
    /// for you to send when it can't.
    ///
    /// Takes 1 to `EmailInvitation.mostAtOnce` addresses; others fail `.invalid`, sending nothing.
    /// Fails 403 for anyone but an administrator, and 422 for anything that isn't an email address.
    public func invite(emailAddresses: [String]) async throws -> [InvitationOutcome] {
        guard !emailAddresses.isEmpty else {
            throw EmberError(kind: .invalid, status: 422, message: "Give an email address to invite")
        }
        guard emailAddresses.count <= EmailInvitation.mostAtOnce else {
            throw EmberError(kind: .invalid, status: 422, message: "Invite at most \(EmailInvitation.mostAtOnce) email addresses at once")
        }
        struct Body: Encodable { var emailAddresses: [String] }
        struct Invited: Decodable { var outcomes: [InvitationOutcome] }
        return try await send("POST", "/api/invitations", body: Body(emailAddresses: emailAddresses), as: Invited.self).outcomes
    }

    /// `POST /api/invitations/:id/resend`: gives the invitation a new link in place of its old one,
    /// and emails it, as an administrator.
    public func resendInvitation(_ id: InvitationID) async throws -> ResentInvitation {
        let (data, response) = try await perform(try request("POST", "/api/invitations/\(Self.segment(id))/resend"))
        return try decode(ResentInvitation.self, from: data, status: response.statusCode)
    }

    /// `DELETE /api/invitations/:id`: revokes the invitation, so its link no longer works.
    public func revokeInvitation(_ id: InvitationID) async throws {
        try await send("DELETE", "/api/invitations/\(Self.segment(id))")
    }
}

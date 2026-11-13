import Foundation

/// An email invitation's id.
public struct InvitationID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// An invitation an administrator sent to join with an email address, until it's accepted or
/// revoked. Its link works once, until it expires, and only for that address.
public struct EmailInvitation: Decodable, Hashable, Identifiable, Sendable {
    /// Whether Ember emailed the newest link.
    public enum Delivery: Hashable, Sendable {
        /// Ember emailed it.
        case sent
        /// The email provider didn't send it, for this reason.
        case refused(String)
        /// Something this build doesn't know.
        case unknown(String)
    }

    public var id: InvitationID
    /// The address it's for.
    public var emailAddress: String
    /// The name of the administrator who sent it last.
    public var invitedBy: String
    /// When its newest link was made. A resend makes a new one.
    public var createdAt: Date
    /// When that link stops working.
    public var expiresAt: Date
    /// Whether Ember emailed the newest link, or nil while Ember can't send email and the
    /// administrator sends the link themselves.
    public var delivery: Delivery?

    public init(id: InvitationID, emailAddress: String, invitedBy: String, createdAt: Date, expiresAt: Date, delivery: Delivery? = .sent) {
        self.id = id
        self.emailAddress = emailAddress
        self.invitedBy = invitedBy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey { case id, emailAddress, invitedBy, createdAt, expiresAt, delivery }
    private struct Refusal: Decodable { var refusal: String }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(InvitationID.self, forKey: .id)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        invitedBy = try container.decode(String.self, forKey: .invitedBy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        if try !container.contains(.delivery) || container.decodeNil(forKey: .delivery) {
            delivery = nil
        } else if let text = try? container.decode(String.self, forKey: .delivery) {
            delivery = text == "sent" ? .sent : .unknown(text)
        } else {
            delivery = .refused(try container.decode(Refusal.self, forKey: .delivery).refusal)
        }
    }

    /// The most addresses `EmberClient.invite(emailAddresses:)` takes at once.
    public static let mostAtOnce = 20
}

/// What came of inviting one email address.
public enum InvitationOutcome: Decodable, Hashable, Sendable {
    /// Someone has an account with that address already, so nothing was sent.
    case member(emailAddress: String)
    /// It was invited. `link` is there when Ember didn't email it, for the administrator to send.
    case invited(EmailInvitation, link: Secret?)

    /// The address it's about.
    public var emailAddress: String {
        switch self {
        case let .member(emailAddress): emailAddress
        case let .invited(invitation, _): invitation.emailAddress
        }
    }

    private enum CodingKeys: String, CodingKey { case emailAddress, member, invitation, link }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let invitation = try container.decodeIfPresent(EmailInvitation.self, forKey: .invitation) {
            self = .invited(invitation, link: try container.decodeIfPresent(Secret.self, forKey: .link))
        } else {
            self = .member(emailAddress: try container.decode(String.self, forKey: .emailAddress))
        }
    }
}

/// An invitation sent again: what `EmberClient.resendInvitation(_:)` answers. The old link no longer works.
public struct ResentInvitation: Decodable, Hashable, Sendable {
    public var invitation: EmailInvitation
    /// The new link, when Ember didn't email it, for the administrator to send.
    public var link: Secret?

    public init(invitation: EmailInvitation, link: Secret? = nil) {
        self.invitation = invitation
        self.link = link
    }
}

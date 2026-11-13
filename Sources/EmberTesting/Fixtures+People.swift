import Foundation
import EmberSDK

extension Fixtures {
    // MARK: Profiles, people and invitations

    /// A made-up sign-in link id, shaped as the server's are. It signs nobody in.
    public static let transferID = Secret("user_ada.session_1.fake0.not-a-real-signature")

    /// `me`'s profile.
    public static let profile = UserProfile(
        name: me.name, emailAddress: "ada@example.com", bio: "Poet of numbers",
        avatarUrl: avatarPath(me.id), hasAvatar: false, hasPassword: true
    )

    /// What `GET /api/users/me/profile` answers, and changing the profile or avatar.
    public static func profileJSON(_ profile: UserProfile = profile, transferID: Secret = transferID) -> String {
        json(["profile": profileObject(profile), "transferId": transferID.revealed])
    }

    /// What `GET /api/users/:id` answers: `user`, with the email address and link id an administrator gets.
    public static func personJSON(_ user: DirectoryUser, emailAddress: String? = nil, transferID: Secret? = nil) -> String {
        var person = value(user) as? [String: Any] ?? [:]
        if let emailAddress { person["emailAddress"] = emailAddress }
        var object: [String: Any] = ["person": person]
        if let transferID { object["transferId"] = transferID.revealed }
        return json(object)
    }

    /// What banning or unbanning someone answers: them, as the directory now lists them.
    public static func changedPersonJSON(_ user: DirectoryUser) -> String {
        json(["user": value(user)])
    }

    /// An invitation Ember emailed to `emailAddress`.
    public static func emailInvitation(_ id: InvitationID = "inv_1", emailAddress: String = "charles@example.com", delivery: EmailInvitation.Delivery? = .sent) -> EmailInvitation {
        EmailInvitation(
            id: id, emailAddress: emailAddress, invitedBy: me.name,
            createdAt: date("2026-10-12T10:00:00.000Z"), expiresAt: date("2026-10-19T10:00:00.000Z"), delivery: delivery
        )
    }

    /// An invitation as the server writes it.
    public static func emailInvitationObject(_ invitation: EmailInvitation) -> [String: Any] {
        let delivery: Any = switch invitation.delivery {
        case nil: NSNull()
        case .sent: "sent"
        case let .refused(reason): ["refusal": reason]
        case let .unknown(text): text
        }
        return [
            "id": invitation.id.rawValue, "emailAddress": invitation.emailAddress, "invitedBy": invitation.invitedBy,
            "createdAt": EmberJSON.string(from: invitation.createdAt), "expiresAt": EmberJSON.string(from: invitation.expiresAt),
            "delivery": delivery,
        ]
    }

    /// What `GET /api/account` answers, with just the pending invitations an administrator sees.
    public static func accountInvitationsJSON(_ invitations: [EmailInvitation]) -> String {
        var object = accountObject(account)
        object["invitations"] = invitations.map(emailInvitationObject)
        return json(object)
    }

    /// `UserProfile` only decodes, so its JSON is written out here.
    static func profileObject(_ profile: UserProfile) -> [String: Any] {
        [
            "name": profile.name, "emailAddress": profile.emailAddress ?? NSNull(), "bio": profile.bio ?? NSNull(),
            "avatarUrl": profile.avatarUrl, "avatar": profile.hasAvatar, "password": profile.hasPassword,
            "membershipNeeded": profile.membershipNeeded, "memberful": NSNull(), "assistant": NSNull(),
        ]
    }
}

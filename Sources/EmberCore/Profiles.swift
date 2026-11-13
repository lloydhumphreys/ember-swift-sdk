import Foundation

/// You, as your profile shows you: what `EmberClient.profile()` answers.
public struct UserProfile: Decodable, Hashable, Sendable {
    public var name: String
    /// Nil for someone who signed in with just a name, or who took theirs out.
    public var emailAddress: String?
    /// What you say about yourself, or nil when you haven't said.
    public var bio: String?
    /// Your avatar, as `DirectoryUser.avatarUrl` gives it.
    public var avatarUrl: String
    /// Whether you've uploaded an avatar, which `removeAvatar()` takes away.
    public var hasAvatar: Bool
    /// Whether you have a password. Changing your email address or password then asks for it.
    public var hasPassword: Bool
    /// Whether you need a Memberful membership to sign in.
    public var membershipNeeded: Bool
    /// Where you stand with Memberful, or nil when there's nothing to show.
    public var memberful: MemberfulStatus?

    public init(name: String, emailAddress: String? = nil, bio: String? = nil, avatarUrl: String, hasAvatar: Bool = false, hasPassword: Bool = true, membershipNeeded: Bool = false, memberful: MemberfulStatus? = nil) {
        self.name = name
        self.emailAddress = emailAddress
        self.bio = bio
        self.avatarUrl = avatarUrl
        self.hasAvatar = hasAvatar
        self.hasPassword = hasPassword
        self.membershipNeeded = membershipNeeded
        self.memberful = memberful
    }

    private enum CodingKeys: String, CodingKey {
        case name, emailAddress, bio, avatarUrl, hasAvatar = "avatar", hasPassword = "password", membershipNeeded, memberful
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        avatarUrl = try container.decode(String.self, forKey: .avatarUrl)
        hasAvatar = try container.decodeIfPresent(Bool.self, forKey: .hasAvatar) ?? false
        hasPassword = try container.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
        membershipNeeded = try container.decodeIfPresent(Bool.self, forKey: .membershipNeeded) ?? false
        memberful = try container.decodeIfPresent(MemberfulStatus.self, forKey: .memberful)
    }
}

/// Where you stand with Memberful.
public struct MemberfulStatus: Decodable, Hashable, Sendable {
    /// The Memberful account you've connected yours to.
    public struct Connection: Decodable, Hashable, Sendable {
        public var name: String
        public var emailAddress: String

        public init(name: String, emailAddress: String) {
            self.name = name
            self.emailAddress = emailAddress
        }
    }

    /// Whether only Memberful members can sign in.
    public var membersOnly: Bool
    /// The account you've connected, or nil before you have.
    public var connected: Connection?

    public init(membersOnly: Bool, connected: Connection? = nil) {
        self.membersOnly = membersOnly
        self.connected = connected
    }
}

/// Your profile and a new sign-in link for you: what `EmberClient.profile()` and the changes to it answer.
public struct ProfileAnswer: Decodable, Hashable, Sendable {
    public var profile: UserProfile
    /// The id in a new sign-in link for you. `SignInLink(origin:transferID:)` with it makes the link.
    public var transferID: Secret

    public init(profile: UserProfile, transferID: Secret) {
        self.profile = profile
        self.transferID = transferID
    }

    private enum CodingKeys: String, CodingKey { case profile, transferID = "transferId" }
}

/// What `EmberClient.changeProfile(_:)` changes. Anything nil stays as it is.
public struct ProfileChanges: Hashable, Sendable {
    public var name: String?
    public var emailAddress: String?
    /// What you say about yourself. An empty one takes it out.
    public var bio: String?
    /// A new password. A blank one keeps the one you have.
    public var password: String?
    /// Your password now, which changing your email address or password needs.
    public var currentPassword: String?

    public init(name: String? = nil, emailAddress: String? = nil, bio: String? = nil, password: String? = nil, currentPassword: String? = nil) {
        self.name = name
        self.emailAddress = emailAddress
        self.bio = bio
        self.password = password
        self.currentPassword = currentPassword
    }
}

extension ProfileChanges: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let changed = [("name", name), ("emailAddress", emailAddress), ("bio", bio), ("password", password), ("currentPassword", currentPassword)]
            .filter { $0.1 != nil }.map(\.0)
        return "ProfileChanges(\(changed.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["name": name as Any, "emailAddress": emailAddress as Any, "bio": bio as Any], displayStyle: .struct)
    }
}

/// Someone as their page shows them: what `EmberClient.person(_:)` answers.
public struct PersonDetails: Decodable, Hashable, Sendable {
    /// Them, as the people directory lists them, whatever their status.
    public var user: DirectoryUser
    /// Their email address. Only administrators are told it, and it's nil for anyone without one.
    public var emailAddress: String?
    /// The id in a new sign-in link for them. Administrators are given one for anyone active who
    /// isn't a bot; nil for everyone else.
    public var transferID: Secret?

    public init(user: DirectoryUser, emailAddress: String? = nil, transferID: Secret? = nil) {
        self.user = user
        self.emailAddress = emailAddress
        self.transferID = transferID
    }

    private enum CodingKeys: String, CodingKey { case person, transferID = "transferId" }
    private enum PersonKeys: String, CodingKey { case emailAddress }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(DirectoryUser.self, forKey: .person)
        emailAddress = try container.nestedContainer(keyedBy: PersonKeys.self, forKey: .person).decodeIfPresent(String.self, forKey: .emailAddress)
        transferID = try container.decodeIfPresent(Secret.self, forKey: .transferID)
    }
}

import Foundation
import EmberSDK

/// Sample people, rooms, messages and frames, as values and as the JSON the server writes, for tests
/// and previews. The JSON goes straight to `MockHTTPTransport.stub` and `MockSocketConnection.serverSends`.
public enum Fixtures {
    // MARK: People

    /// The person signed in: an administrator.
    public static let me = Me(id: "user_ada", name: "Ada Lovelace", administrator: true)
    /// `me` as a message names her.
    public static let ada = me.user
    public static let grace = User(id: "user_grace", name: "Grace Hopper")
    public static let alan = User(id: "user_alan", name: "Alan Turing")

    /// The directory: the three of them and the assistant.
    public static let people: [DirectoryUser] = [
        DirectoryUser(id: ada.id, name: ada.name, bio: "Poet of numbers", role: .administrator, avatarUrl: avatarPath(ada.id)),
        DirectoryUser(id: grace.id, name: grace.name, avatarUrl: avatarPath(grace.id)),
        DirectoryUser(id: alan.id, name: alan.name, avatarUrl: avatarPath(alan.id)),
        DirectoryUser(id: Assistant.id, name: Assistant.name, role: .bot, avatarUrl: avatarPath(Assistant.id)),
    ]

    public static let account = Account(name: "Analytical Engines", tagline: "Weaving algebraic patterns")

    // MARK: Rooms

    public static let general = Room(id: "room-general", kind: .open, name: "General")
    public static let engines = Room(id: "room-engines", kind: .closed, name: "Engines", icon: "cog")
    /// A DM between `me` and Grace.
    public static let directWithGrace = Room(
        id: "room-dm-grace", kind: .direct, members: [ada, grace], activeAt: date("2026-10-12T10:00:00.000Z")
    )

    /// The sidebar's rooms: General unread, Engines read, and the DM.
    public static let sidebarRooms: [SidebarRoom] = [
        SidebarRoom(room: general, unread: true),
        SidebarRoom(room: engines),
        SidebarRoom(room: directWithGrace),
    ]

    /// General is starred.
    public static let favorites = Favorites(rooms: [general.id], version: 1)

    // MARK: Messages

    /// A message, by Grace in General unless said otherwise, at a minute past ten plus `minute`.
    public static func message(
        _ id: String,
        _ text: String,
        by creator: User = grace,
        in roomID: RoomID = general.id,
        minute: Int = 0,
        clientMessageId: String? = nil
    ) -> Message {
        let at = date("2026-10-12T10:00:00.000Z").addingTimeInterval(TimeInterval(minute * 60))
        return Message(
            id: id, clientMessageId: clientMessageId ?? "client_\(id)", roomId: roomID, creator: creator,
            body: "<p>\(text)</p>", plainText: text, createdAt: at
        )
    }

    /// `count` messages in a room, oldest first, with ids `m001`, `m002`… that sort as the server's do.
    public static func messages(_ count: Int, in roomID: RoomID = general.id, from first: Int = 1) -> [Message] {
        (first ..< first + count).map { n in
            message(String(format: "m%03d", n), "Message \(n)", by: n.isMultiple(of: 2) ? ada : grace, in: roomID, minute: n)
        }
    }

    // MARK: HTTP answers

    /// `GET /api/me` and a sign-in's answer.
    public static func meJSON(_ me: Me = me) -> String {
        json(["user": value(me)])
    }

    /// `GET /api/bootstrap`, signed in as `user` or nobody.
    public static func bootstrapJSON(user: Me? = me, guestSignIn: Bool = false) -> String {
        json([
            "setup": "complete",
            "guestSignIn": guestSignIn,
            "signInWithMemberful": false,
            "turnstileSiteKey": NSNull(),
            "passwordResetCodes": true,
            "account": accountObject(account),
            "version": "test",
            "user": user.map { value($0) } ?? NSNull(),
        ])
    }

    /// `GET /api/sidebar`.
    public static func sidebarJSON(
        rooms: [SidebarRoom] = sidebarRooms,
        favorites: Favorites = favorites,
        sharedOrder: [RoomID] = [engines.id, general.id],
        suggestions: [User] = [grace, alan]
    ) -> String {
        json([
            "rooms": rooms.map(sidebarRoomObject),
            "favorites": value(favorites),
            "sharedOrder": sharedOrder,
            "invitation": NSNull(),
            "suggestions": suggestions.map { value($0) },
        ])
    }

    /// `GET /api/users`.
    public static func directoryJSON(_ people: [DirectoryUser] = people) -> String {
        json(["users": people.map { value($0) }])
    }

    /// `PUT /api/rooms/:id/favorite`'s answer.
    public static func favoritesJSON(_ favorites: Favorites) -> String {
        json(["favorites": value(favorites)])
    }

    /// `POST /api/directs`'s answer.
    public static func roomJSON(_ room: Room) -> String {
        json(["room": value(room)])
    }

    /// GET or POST `/api/searches`'s answer. With no `search`, it's the recent searches alone.
    public static func searchJSON(search: SearchQuery? = nil, matches: [Message] = [], next: Int? = nil, rooms: [Room] = [], recent: [SearchQuery] = []) -> String {
        json([
            "search": search.map { value($0) } ?? NSNull(),
            "matches": matches.map { ["message": value($0), "words": [String]()] },
            "next": next ?? NSNull(),
            "rooms": rooms.map { value($0) },
            "recent": recent.map { value($0) },
        ])
    }

    /// A refusal, as `{ "error": … }` with a field when there is one.
    public static func errorJSON(_ message: String, field: String? = nil) -> String {
        var object: [String: Any] = ["error": message]
        if let field { object["field"] = field }
        return json(object)
    }

    /// The `Set-Cookie` an HTTP server sets on signing in.
    public static let sessionCookieHeaders = ["Set-Cookie": "session_token=test-session; Path=/; HttpOnly; SameSite=Lax"]

    /// The `Set-Cookie` signing out sets, which forgets the session.
    public static let expiredCookieHeaders = ["Set-Cookie": "session_token=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly"]

    // MARK: Room socket frames

    /// What a room's socket sends: `welcome` and the rest, as JSON.
    public enum RoomFrames {
        public static func welcome(you: User = ada, messages: [Message] = Fixtures.messages(3), seq: Int = 10, present: [User] = [ada], hasMore: Bool = false, hasNewer: Bool = false, around: String? = nil) -> String {
            json([
                "type": "welcome", "you": value(you), "present": present.map { value($0) }, "seq": seq,
                "messages": messages.map { value($0) }, "hasMore": hasMore, "hasNewer": hasNewer, "around": around ?? NSNull(),
            ])
        }

        public static func resumed(you: User = ada, messages: [Message] = [], deletedIds: [String] = [], seq: Int, present: [User] = [ada]) -> String {
            json([
                "type": "resumed", "you": value(you), "messages": messages.map { value($0) }, "deletedIds": deletedIds,
                "present": present.map { value($0) }, "seq": seq,
            ])
        }

        public static func messageCreated(_ message: Message, seq: Int) -> String {
            json(["type": "message.created", "message": value(message), "seq": seq])
        }

        public static func messageUpdated(_ message: Message, seq: Int) -> String {
            json(["type": "message.updated", "message": value(message), "seq": seq])
        }

        public static func messageDeleted(_ messageId: String, seq: Int) -> String {
            json(["type": "message.deleted", "messageId": messageId, "seq": seq])
        }

        public static func history(before: String, messages: [Message], hasMore: Bool) -> String {
            json(["type": "history", "before": before, "messages": messages.map { value($0) }, "hasMore": hasMore])
        }

        public static func historyAfter(after: String, messages: [Message], hasNewer: Bool) -> String {
            json(["type": "history.after", "after": after, "messages": messages.map { value($0) }, "hasNewer": hasNewer])
        }

        public static func historyAround(messages: [Message], hasMore: Bool = true, hasNewer: Bool = true, around: String?) -> String {
            json([
                "type": "history.around", "messages": messages.map { value($0) }, "hasMore": hasMore, "hasNewer": hasNewer,
                "around": around ?? NSNull(),
            ])
        }

        public static func messageChecked(stored: [String], missing: [String]) -> String {
            json(["type": "message.checked", "stored": stored, "missing": missing])
        }

        public static func typing(_ user: User, _ typing: Bool) -> String {
            json(["type": "typing", "user": value(user), "typing": typing])
        }

        /// A refusal; with a `clientMessageId` it's a message's, otherwise something else's.
        public static func error(_ message: String, clientMessageId: String? = nil, failed: String? = nil) -> String {
            var object: [String: Any] = ["type": "error", "message": message]
            if let clientMessageId { object["clientMessageId"] = clientMessageId }
            if let failed { object["failed"] = failed }
            return json(object)
        }

        public static let pong = #"{"type":"pong"}"#
    }

    // MARK: Workspace socket frames

    /// What the workspace socket sends, as JSON.
    public enum WorkspaceFrames {
        public static func welcome(you: Me = me, account: Account = Fixtures.account) -> String {
            json(["type": "welcome", "you": value(you), "account": accountObject(account)])
        }

        public static func roomUnread(_ roomID: RoomID) -> String {
            json(["type": "room.unread", "roomId": roomID])
        }

        public static func roomRead(_ roomID: RoomID) -> String {
            json(["type": "room.read", "roomId": roomID])
        }

        public static func roomSaved(_ room: Room) -> String {
            json(["type": "room.saved", "room": value(room)])
        }

        public static func roomGone(_ roomID: RoomID) -> String {
            json(["type": "room.gone", "roomId": roomID])
        }

        public static func favoritesChanged(_ favorites: Favorites) -> String {
            json(["type": "favorites.changed", "favorites": value(favorites)])
        }

        public static func userUpdated(_ user: DirectoryUser) -> String {
            json(["type": "user.updated", "user": value(user)])
        }

        public static func accountUpdated(_ account: Account) -> String {
            json(["type": "account.updated", "account": accountObject(account)])
        }

        public static let roomsReordered = #"{"type":"rooms.reordered"}"#
        public static let pong = #"{"type":"pong"}"#
    }

    // MARK: Values decoded from the JSON

    /// `sidebarJSON()` as the client reads it.
    public static var sidebar: Sidebar { decode(sidebarJSON()) }
    /// `bootstrapJSON()` as the client reads it.
    public static var bootstrap: Bootstrap { decode(bootstrapJSON()) }
    /// `directoryJSON()` as the client reads it.
    public static var directory: Directory { decode(directoryJSON()) }

    /// Decodes JSON as the client does; a fixture that doesn't decode is a mistake in the fixture.
    public static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T {
        do {
            return try EmberJSON.decoder().decode(T.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("A fixture didn’t decode as \(T.self): \(error)")
        }
    }

    // MARK: Building JSON

    static func avatarPath(_ id: UserID) -> String { "/users/\(id)/avatar?v=1" }

    static func date(_ text: String) -> Date {
        EmberJSON.date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    /// An encodable value as a JSON object, to put inside another.
    static func value<T: Encodable>(_ value: T) -> Any {
        guard let data = try? EmberJSON.encoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        return object
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `Account` only decodes, so its JSON is written out here.
    static func accountObject(_ account: Account) -> [String: Any] {
        [
            "name": account.name, "tagline": account.tagline, "logo": account.logo ?? NSNull(),
            "customDomain": account.customDomain ?? NSNull(), "restrictRoomCreation": account.restrictRoomCreation,
            "hideTranslationButtons": account.hideTranslationButtons,
        ]
    }

    /// A sidebar room as the server flattens it: the room's fields, its mark and its level.
    static func sidebarRoomObject(_ room: SidebarRoom) -> [String: Any] {
        var object = value(room.room) as? [String: Any] ?? [:]
        object["unread"] = room.unread
        object["involvement"] = room.involvement.rawValue
        return object
    }
}

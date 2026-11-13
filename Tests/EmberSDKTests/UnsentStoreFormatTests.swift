@testable import EmberSDK
import Foundation
import Testing

/// What `FileUnsentMessageStore` puts on disk, pinned to literal values so messages a past build
/// saved still load: the folder and file names for a key, the JSON it writes, reading that JSON
/// back, and reading a file in the format before it, which the next save moves.
@Suite struct UnsentStoreFormatTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "UnsentStoreFormat-\(UUID().uuidString)", directoryHint: .isDirectory)
    let key = UnsentMessageKey(server: URL(string: "https://ember.test")!, userID: "user_1", roomID: "room_1")

    /// SHA-256 of 8-byte big-endian lengths and UTF-8: `https://ember.test` and `user_1`, `user_2`;
    /// `room_1`.
    static let user1Folder = "7b2f6f899e5fbc7fddbc442f28b896ff9756471d7bfecc2e155e46efd72d0ed1"
    static let user2Folder = "1708b2b1aedb294b51c722c758fddeff60a3e4bbdbd4a7ee7fde2517b00bd73f"
    static let room1File = "6bdbe631bb2ed6ebe6211ceb6013b1613f8c244039bdf526af00b3aead39d157.json"
    /// The names of the format before: the Base64 of the three parts.
    static let legacyUser1 = "aHR0cHM6Ly9lbWJlci50ZXN0CnVzZXJfMQpyb29tXzE.json"
    static let legacyUser2 = "aHR0cHM6Ly9lbWJlci50ZXN0CnVzZXJfMgpyb29tXzE.json"

    static let messages = [
        UnsentMessage(clientMessageId: "client_1", body: "<p>Hello</p>", plainText: "Hello", createdAt: Date(timeIntervalSinceReferenceDate: 1000)),
        UnsentMessage(
            clientMessageId: "client_2", body: "<p>Reply</p>", plainText: "Reply", createdAt: Date(timeIntervalSinceReferenceDate: 2000.5),
            failure: "Too long", parentId: "msg_9", delivery: .threadAndRoom
        ),
    ]

    /// The messages' JSON, as the format before wrote them and as the envelope holds them.
    static let messagesJSON = #"[{"alsoSend":false,"body":"<p>Hello<\/p>","clientMessageId":"client_1","createdAt":1000,"plainText":"Hello"},{"alsoSend":true,"body":"<p>Reply<\/p>","clientMessageId":"client_2","createdAt":2000.5,"failure":"Too long","parentId":"msg_9","plainText":"Reply"}]"#

    /// The file's JSON as this format writes it.
    static let json = #"{"key":{"roomID":"room_1","server":"https:\/\/ember.test","userID":"user_1"},"messages":"# + messagesJSON + #","version":1}"#

    func contents(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    @Test func namesAreLengthPrefixedHashes() {
        #expect(FileUnsentMessageStore.hashedName(["https://ember.test", "user_1"]) == Self.user1Folder)
        #expect(FileUnsentMessageStore.hashedName(["room_1"]) + ".json" == Self.room1File)
        // Parts that join to the same text still name different files.
        #expect(FileUnsentMessageStore.hashedName(["ab", "c"]) != FileUnsentMessageStore.hashedName(["a", "bc"]))
        #expect(FileUnsentMessageStore.hashedName(["a\n", "b"]) != FileUnsentMessageStore.hashedName(["a", "\nb"]))
    }

    @Test func folderAndFileNameForAKey() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save(Self.messages, for: key)
        #expect(try contents(folder) == [Self.user1Folder])
        #expect(try contents(folder.appending(path: Self.user1Folder)) == [Self.room1File])
        #expect(store.fileURL(for: key) == folder.appending(path: Self.user1Folder).appending(path: Self.room1File))
        #expect(store.directory(server: key.server, userID: key.userID) == folder.appending(path: Self.user1Folder, directoryHint: .isDirectory))
    }

    @Test func writtenJSON() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileUnsentMessageStore(folder: folder).save(Self.messages, for: key)
        let written = try Data(contentsOf: folder.appending(path: Self.user1Folder).appending(path: Self.room1File))
        // `JSONEncoder` puts an object's members in no fixed order, so the file is pinned as its
        // values and as its bytes in any order: the same members, written the same way.
        let object = try JSONSerialization.jsonObject(with: written) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(Self.json.utf8)) as? NSDictionary
        #expect(object != nil && object == expected)
        #expect(written.sorted() == Data(Self.json.utf8).sorted())
    }

    @Test func readsAFileInTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appending(path: Self.user1Folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = #"{"version":1,"key":{"server":"https://ember.test","userID":"user_1","roomID":"room_1"},"messages":["#
            + #"{"clientMessageId":"client_1","body":"<p>Hello</p>","plainText":"Hello","createdAt":1000},"#
            + #"{"clientMessageId":"client_2","body":"<p>Reply</p>","plainText":"Reply","createdAt":2000.5,"failure":"Too long","parentId":"msg_9","alsoSend":true}]}"#
        try Data(saved.utf8).write(to: directory.appending(path: Self.room1File))
        let read = try FileUnsentMessageStore(folder: folder).messages(for: key)
        #expect(read == Self.messages)
        #expect(read.map(\.clientMessageId.description) == ["client_1", "client_2"])
        #expect(read.map { $0.parentId?.description } == [nil, "msg_9"])
    }

    static let legacyJSON = #"[{"clientMessageId":"client_1","body":"<p>Hello</p>","plainText":"Hello","createdAt":1000},"#
        + #"{"clientMessageId":"client_2","body":"<p>Reply</p>","plainText":"Reply","createdAt":2000.5,"failure":"Too long","parentId":"msg_9","alsoSend":true}]"#

    @Test func readsAFileInTheFormatBeforeAndLeavesIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.legacyJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        let store = FileUnsentMessageStore(folder: folder)
        #expect(try store.messages(for: key) == Self.messages)
        #expect(try contents(folder) == [Self.legacyUser1])
        #expect(try Data(contentsOf: folder.appending(path: Self.legacyUser1)) == Data(Self.legacyJSON.utf8))
        #expect(try store.messages(for: key) == Self.messages)
    }

    @Test func aSaveWritesTodaysFormatAndDeletesTheFileInTheFormatBefore() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.legacyJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        let store = FileUnsentMessageStore(folder: folder)
        try store.save(try store.messages(for: key), for: key)
        #expect(try contents(folder) == [Self.user1Folder])
        let written = try Data(contentsOf: store.fileURL(for: key))
        #expect(written.sorted() == Data(Self.json.utf8).sorted())
        #expect(try store.messages(for: key) == Self.messages)
    }

    @Test func aFileInTodaysFormatShadowsOneInTheFormatBefore() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save([Self.messages[0]], for: key)
        try Data(Self.legacyJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        #expect(try store.messages(for: key) == [Self.messages[0]])
        #expect(try contents(folder) == [Self.user1Folder, Self.legacyUser1].sorted())
    }

    @Test func aFileInTheFormatBeforeThatCantBeDeletedStaysShadowed() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: folder)
        }
        let user = folder.appending(path: Self.user1Folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data(Self.legacyJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        // Nothing at the folder's top can be deleted; the user's folder can still be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        let store = FileUnsentMessageStore(folder: folder)
        #expect(try store.messages(for: key) == Self.messages)

        // A save that can't delete it isn't a failed save: the new file is read in its place.
        try store.save([Self.messages[0]], for: key)
        #expect(try store.messages(for: key) == [Self.messages[0]])
        #expect(try contents(folder) == [Self.user1Folder, Self.legacyUser1].sorted())

        // Nor is an empty one, which leaves an empty file in its way.
        try store.save([], for: key)
        #expect(try store.messages(for: key).isEmpty)
        #expect(try contents(user) == [Self.room1File])
        #expect(try contents(folder) == [Self.user1Folder, Self.legacyUser1].sorted())

        // Once it can be deleted, both go.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        try store.save([], for: key)
        #expect(try contents(folder) == [Self.user1Folder])
        #expect(try contents(user).isEmpty)
        #expect(try store.messages(for: key).isEmpty)
    }

    @Test func aFileInTheFormatBeforeThatCantBeDeletedLaterGoesAtTheNextSave() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder.appending(path: Self.user1Folder), withIntermediateDirectories: true)
        try Data(Self.legacyJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        let store = FileUnsentMessageStore(folder: folder)
        try store.save(Self.messages, for: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        try store.save(Self.messages, for: key)
        #expect(try contents(folder) == [Self.user1Folder])
        #expect(try store.messages(for: key) == Self.messages)
    }

    @Test func savingNothingOverAFileInTheFormatBeforeDeletesIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.messagesJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        let store = FileUnsentMessageStore(folder: folder)
        try store.save([], for: key)
        #expect(try contents(folder).isEmpty)
        #expect(try store.messages(for: key).isEmpty)
    }

    @Test func aReplysDeliveryIsTheSameBoolOnDisk() throws {
        let saved = #"[{"clientMessageId":"c1","body":"A","plainText":"A","createdAt":1,"parentId":"m1","alsoSend":false},"#
            + #"{"clientMessageId":"c2","body":"B","plainText":"B","createdAt":2,"parentId":"m1","alsoSend":true},"#
            + #"{"clientMessageId":"c3","body":"C","plainText":"C","createdAt":3,"parentId":"m1"},"#
            + #"{"clientMessageId":"c4","body":"D","plainText":"D","createdAt":4,"alsoSend":true}]"#
        let read = try JSONDecoder().decode([UnsentMessage].self, from: Data(saved.utf8))
        #expect(read.map(\.delivery) == [.threadOnly, .threadAndRoom, .threadOnly, .threadOnly])

        // Written back with the same keys and types: `alsoSend` always a Bool, and true only for a reply.
        let written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(read)) as? [[String: Any]]
        let rows = try #require(written)
        #expect(rows.map { Set($0.keys) } == [
            ["clientMessageId", "body", "plainText", "createdAt", "parentId", "alsoSend"],
            ["clientMessageId", "body", "plainText", "createdAt", "parentId", "alsoSend"],
            ["clientMessageId", "body", "plainText", "createdAt", "parentId", "alsoSend"],
            ["clientMessageId", "body", "plainText", "createdAt", "alsoSend"],
        ])
        #expect(rows.map { ($0["alsoSend"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } } == [true, true, true, true])
        #expect(rows.map { $0["alsoSend"] as? Bool } == [false, true, false, false])
        #expect(rows.map { $0["createdAt"] as? Double } == [1, 2, 3, 4])
    }

    @Test func removeAllFindsTheFilesOfItsUser() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save(Self.messages, for: key)
        try store.save(Self.messages, for: UnsentMessageKey(server: key.server, userID: "user_2", roomID: "room_1"))
        // And files in the format before, for each of them.
        try Data(Self.messagesJSON.utf8).write(to: folder.appending(path: Self.legacyUser1))
        try Data(Self.messagesJSON.utf8).write(to: folder.appending(path: Self.legacyUser2))
        try store.removeAll(server: key.server, userID: "user_1")
        #expect(try contents(folder) == [Self.user2Folder, Self.legacyUser2].sorted())
    }
}

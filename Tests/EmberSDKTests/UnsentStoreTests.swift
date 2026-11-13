@testable import EmberSDK
import Foundation
import Testing

/// How `FileUnsentMessageStore` and `MemoryUnsentMessageStore` fail, recover and keep their files:
/// what throws, what's kept in the quarantine, what's left for a later read, and backups.
@Suite struct UnsentStoreTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "UnsentStore-\(UUID().uuidString)", directoryHint: .isDirectory)
    let server = URL(string: "https://ember.test")!
    var key: UnsentMessageKey { UnsentMessageKey(server: server, userID: "user_1", roomID: "room_1") }

    static let message = UnsentMessage(clientMessageId: "client_1", body: "<p>Hello</p>", plainText: "Hello", createdAt: Date(timeIntervalSinceReferenceDate: 1000))
    static let other = UnsentMessage(clientMessageId: "client_2", body: "<p>Again</p>", plainText: "Again", createdAt: Date(timeIntervalSinceReferenceDate: 2000))

    var manager: FileManager { .default }

    func remove() {
        try? manager.removeItem(at: folder)
    }

    func names(_ url: URL) -> [String] {
        ((try? manager.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }

    func quarantined(_ store: FileUnsentMessageStore) -> [String] {
        names(store.quarantine(server: server, userID: "user_1"))
    }

    /// Writes `json` where `key`'s file goes.
    func write(_ json: String, for store: FileUnsentMessageStore) throws {
        let file = store.fileURL(for: key)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    func envelope(version: Int = 1, roomID: String = "room_1", messages: String) -> String {
        #"{"version":\#(version),"key":{"server":"https://ember.test","userID":"user_1","roomID":"\#(roomID)"},"messages":\#(messages)}"#
    }

    static let good = #"{"clientMessageId":"client_1","body":"<p>Hello</p>","plainText":"Hello","createdAt":1000,"alsoSend":false}"#
    static let bad = #"{"clientMessageId":"client_2","body":42}"#

    func isExcludedFromBackup(_ url: URL) throws -> Bool? {
        // A fresh URL, so nothing cached answers.
        try URL(filePath: url.path(percentEncoded: false)).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    // MARK: Writing

    @Test func aFolderThatCantBeMadeThrowsUnwritable() throws {
        defer { remove() }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "blocker")
        try Data().write(to: blocker)
        let store = FileUnsentMessageStore(folder: blocker.appending(path: "Unsent", directoryHint: .isDirectory))
        #expect {
            try store.save([Self.message], for: key)
        } throws: { ($0 as? UnsentStoreError)?.kind == .unwritable }
    }

    @Test func aRemovalThatCantMoveTheFolderThrowsAndKeepsIt() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save([Self.message], for: key)
        // Neither the user's folder can be moved out, nor `.trash` made.
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false)) }
        #expect {
            try store.removeAll(server: server, userID: "user_1")
        } throws: { ($0 as? UnsentStoreError)?.kind == .couldNotRemove }
        #expect(try store.messages(for: key) == [Self.message])
        #expect(!names(folder).contains(".trash"))
    }

    @Test func anEmptyListThatCantBeRemovedThrows() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save([Self.message], for: key)
        let directory = store.directory(server: server, userID: "user_1").path(percentEncoded: false)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }
        #expect {
            try store.save([], for: key)
        } throws: { ($0 as? UnsentStoreError)?.kind == .couldNotRemove }
        #expect(try store.messages(for: key) == [Self.message])
    }

    // MARK: Reading

    @Test func aMissingFileIsEmpty() throws {
        defer { remove() }
        #expect(try FileUnsentMessageStore(folder: folder).messages(for: key).isEmpty)
    }

    @Test func aFileThatCantBeOpenedThrowsUnreadableAndStays() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try store.save([Self.message], for: key)
        let file = store.fileURL(for: key).path(percentEncoded: false)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file) }
        #expect {
            try store.messages(for: key)
        } throws: { ($0 as? UnsentStoreError)?.kind == .unreadable }
        #expect(manager.fileExists(atPath: file))
        #expect(quarantined(store).isEmpty)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(try store.messages(for: key) == [Self.message])
    }

    @Test func aFileThatIsntJSONIsQuarantinedAndThrowsCorrupt() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try write("not json", for: store)
        var thrown: UnsentStoreError?
        do { _ = try store.messages(for: key) } catch { thrown = error as? UnsentStoreError }
        #expect(thrown?.kind == .corrupt)
        #expect(thrown?.recovered == nil)
        #expect(thrown?.file == store.fileURL(for: key))
        #expect(!manager.fileExists(atPath: store.fileURL(for: key).path(percentEncoded: false)))
        let kept = quarantined(store)
        #expect(kept.count == 1)
        #expect(kept.first?.hasSuffix(".json") == true)
        // Moved aside, so what's next reads and writes as for none.
        #expect(try store.messages(for: key).isEmpty)
        try store.save([Self.message], for: key)
        #expect(try store.messages(for: key) == [Self.message])
    }

    @Test func aFileWithSomeUnreadableMessagesRecoversTheOthers() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try write(envelope(messages: "[\(Self.good),\(Self.bad)]"), for: store)
        var thrown: UnsentStoreError?
        do { _ = try store.messages(for: key) } catch { thrown = error as? UnsentStoreError }
        #expect(thrown?.kind == .corrupt)
        #expect(thrown?.recovered == [Self.message])
        #expect(thrown?.lost == 1)
        // Copied aside, and left for the session to write again.
        #expect(manager.fileExists(atPath: store.fileURL(for: key).path(percentEncoded: false)))
        #expect(quarantined(store).count == 1)
    }

    @Test func aFileReadInPartAgainAndAgainIsQuarantinedOnce() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        // An older copy of something else, kept already.
        try write("not json", for: store)
        _ = try? store.messages(for: key)
        try write(envelope(messages: "[\(Self.good),\(Self.bad)]"), for: store)
        for _ in 0..<(FileUnsentMessageStore.quarantineLimit + 2) {
            #expect(throws: UnsentStoreError.self) { try store.messages(for: key) }
        }
        #expect(quarantined(store).count == 2)
        // Changed, it's copied again.
        try write(envelope(messages: "[\(Self.bad),\(Self.good)]"), for: store)
        #expect(throws: UnsentStoreError.self) { try store.messages(for: key) }
        #expect(quarantined(store).count == 3)
    }

    @Test func aFileOfANewerVersionIsLeftAlone() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        let json = envelope(version: 2, messages: "[\(Self.good)]")
        try write(json, for: store)
        #expect {
            try store.messages(for: key)
        } throws: { ($0 as? UnsentStoreError)?.kind == .newerVersion(2) }
        #expect(try Data(contentsOf: store.fileURL(for: key)) == Data(json.utf8))
        #expect(quarantined(store).isEmpty)
    }

    @Test func aFileForAnotherKeyIsQuarantined() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try write(envelope(roomID: "room_2", messages: "[\(Self.good)]"), for: store)
        #expect {
            try store.messages(for: key)
        } throws: { ($0 as? UnsentStoreError)?.kind == .corrupt }
        #expect(quarantined(store).count == 1)
        #expect(try store.messages(for: key).isEmpty)
    }

    @Test func onlyTheNewestQuarantinedFilesAreKept() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        for _ in 0..<(FileUnsentMessageStore.quarantineLimit + 2) {
            try write("not json", for: store)
            _ = try? store.messages(for: key)
        }
        #expect(quarantined(store).count == FileUnsentMessageStore.quarantineLimit)
    }

    @Test func veryLongIdsGetNamesOfTheSameLength() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        let long = UnsentMessageKey(server: server, userID: UserID(rawValue: String(repeating: "u", count: 1000)), roomID: RoomID(rawValue: String(repeating: "r", count: 1000)))
        try store.save([Self.message], for: long)
        #expect(try store.messages(for: long) == [Self.message])
        #expect(store.fileURL(for: long).lastPathComponent.count == 64 + 5)
        #expect(store.directory(server: server, userID: long.userID).lastPathComponent.count == 64)
        #expect(store.legacyFileURL(for: long) == nil)
        try store.removeAll(server: server, userID: long.userID)
        #expect(try store.messages(for: long).isEmpty)

        // A very long server address too.
        let longServer = try #require(URL(string: "https://" + String(repeating: "s", count: 60) + ".test/" + String(repeating: "p", count: 2000)))
        let far = UnsentMessageKey(server: longServer, userID: long.userID, roomID: long.roomID)
        try store.save([Self.message], for: far)
        #expect(try store.messages(for: far) == [Self.message])
        #expect(store.fileURL(for: far).lastPathComponent.count == 64 + 5)
        #expect(store.directory(server: longServer, userID: far.userID).lastPathComponent.count == 64)
        #expect(store.legacyFileURL(for: far) == nil)
        try store.removeAll(server: longServer, userID: far.userID)
        #expect(try store.messages(for: far).isEmpty)
    }

    @Test func removeAllTakesTheQuarantineAndFilesInTheFormatBefore() throws {
        defer { remove() }
        let store = FileUnsentMessageStore(folder: folder)
        try write("not json", for: store)
        _ = try? store.messages(for: key)
        #expect(quarantined(store).count == 1)
        let otherRoom = UnsentMessageKey(server: server, userID: "user_1", roomID: "room_2")
        let legacy = try #require(store.legacyFileURL(for: otherRoom))
        try Data("[\(Self.good)]".utf8).write(to: legacy)
        try store.removeAll(server: server, userID: "user_1")
        #expect(names(folder).isEmpty)
    }

    // MARK: Two writers

    @Test func twoStoresOnOneFolderEachWriteTheWholeList() throws {
        defer { remove() }
        let first = FileUnsentMessageStore(folder: folder)
        let second = FileUnsentMessageStore(folder: folder)
        try first.save([Self.message], for: key)
        try second.save([Self.other], for: key)
        // The last write wins: neither merges the other's.
        #expect(try first.messages(for: key) == [Self.other])
        #expect(try second.messages(for: key) == [Self.other])
    }

    @Test func concurrentWritesToOneKeyLeaveAWholeFile() throws {
        defer { remove() }
        let stores = [FileUnsentMessageStore(folder: folder), FileUnsentMessageStore(folder: folder)]
        let lists = [[Self.message], [Self.message, Self.other]]
        let key = key
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            try? stores[index % 2].save(lists[(index / 2) % 2], for: key)
        }
        let read = try stores[0].messages(for: key)
        #expect(lists.contains(read))
        #expect(quarantined(stores[0]).isEmpty)
    }

    // MARK: Backups

    @Test func aNewFolderIsLeftOutOfBackups() throws {
        defer { remove() }
        try FileUnsentMessageStore(folder: folder).save([Self.message], for: key)
        #expect(try isExcludedFromBackup(folder) == true)
    }

    @Test func aFolderThatWasThereIsLeftOutOfBackupsOnceFound() throws {
        defer { remove() }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try isExcludedFromBackup(folder) == false)
        _ = try FileUnsentMessageStore(folder: folder).messages(for: key)
        #expect(try isExcludedFromBackup(folder) == true)
    }

    @Test func aStoreIncludedInBackupsSaysSo() throws {
        defer { remove() }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try FileUnsentMessageStore(folder: folder, includedInBackup: true).save([Self.message], for: key)
        #expect(try isExcludedFromBackup(folder) == false)
    }

    // MARK: In memory

    @Test func theMemoryStoreFailsWhenToldAndKeepsWhatItHad() throws {
        let store = MemoryUnsentMessageStore()
        try store.save([Self.message], for: key)
        store.failsWrites = true
        #expect(throws: UnsentStoreError.self) { try store.save([Self.other], for: key) }
        store.failsRemovals = true
        #expect(throws: UnsentStoreError.self) { try store.removeAll(server: server, userID: "user_1") }
        store.failsReads = true
        #expect(throws: UnsentStoreError.self) { try store.messages(for: key) }
        store.failsReads = false
        #expect(try store.messages(for: key) == [Self.message])
        store.failsWrites = false
        store.failsRemovals = false
        try store.removeAll(server: server, userID: "user_1")
        #expect(store.saved.isEmpty)
    }

    @Test func theMemoryStoreIsSafeFromManyThreads() throws {
        let store = MemoryUnsentMessageStore()
        let key = key
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let key = UnsentMessageKey(server: key.server, userID: key.userID, roomID: RoomID(rawValue: "room_\(index % 10)"))
            try? store.save([Self.message], for: key)
            _ = try? store.messages(for: key)
        }
        #expect(store.saved.count == 10)
    }
}

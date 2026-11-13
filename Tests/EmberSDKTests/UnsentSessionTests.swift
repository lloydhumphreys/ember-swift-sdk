@testable import EmberSDK
import EmberTesting
import Foundation
import Synchronization
import Testing

/// A store in memory that logs each write as it's made, and can hold writes back until released.
/// A write held gives up waiting after `holdLimit`, so a test that fails before releasing it can't
/// hang the run.
final class RecordingStore: UnsentMessageStore, @unchecked Sendable {
    static let holdLimit: TimeInterval = 5

    let memory = MemoryUnsentMessageStore()
    private let condition = NSCondition()
    private var held = false
    private var allowed = 0
    private var waitingCount = 0
    private var entries: [String] = []

    /// Each save (`save room_1 [ids]`) and removal (`remove user_ada`), in the order made.
    var log: [String] { condition.withLock { entries } }
    /// How many writes are waiting to be released.
    var waiting: Int { condition.withLock { waitingCount } }

    func hold() { condition.withLock { held = true } }

    func release() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }

    /// Lets `count` writes through while still holding the rest.
    func letThrough(_ count: Int = 1) {
        condition.withLock {
            allowed += count
            condition.broadcast()
        }
    }

    private func gate() {
        condition.withLock {
            waitingCount += 1
            let deadline = Date(timeIntervalSinceNow: Self.holdLimit)
            while held, allowed == 0, condition.wait(until: deadline) {}
            if held, allowed > 0 { allowed -= 1 }
            waitingCount -= 1
        }
    }

    private func record(_ entry: String) {
        condition.withLock { entries.append(entry) }
    }

    func messages(for key: UnsentMessageKey) throws -> [UnsentMessage] {
        try memory.messages(for: key)
    }

    func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) throws {
        gate()
        record("save \(key.roomID.rawValue) \(messages.map(\.clientMessageId.description))")
        try memory.save(messages, for: key)
    }

    func removeAll(server: URL, userID: UserID) throws {
        gate()
        record("remove \(userID.rawValue)")
        try memory.removeAll(server: server, userID: userID)
    }
}

/// How a session keeps its unsent messages when the store is slow, fails or was corrupted: off the
/// main actor, in order, coalesced, retried, and never written over what couldn't be read.
@MainActor @Suite struct UnsentSessionTests {
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock
    let server = URL(string: "https://ember.test")!

    init() {
        var (timing, clock) = manualTiming()
        timing.connectTimeout = .seconds(1_000_000)
        self.timing = timing
        self.clock = clock
        connector.welcomeEverySocket()
    }

    func key(_ roomID: RoomID = Fixtures.general.id) -> UnsentMessageKey {
        UnsentMessageKey(server: server, userID: Fixtures.ada.id, roomID: roomID)
    }

    func session(_ store: any UnsentMessageStore, roomID: RoomID = Fixtures.general.id) -> RoomSession {
        RoomSession(client: .mock(connector: connector, timing: timing), roomID: roomID, unsentStore: store)
    }

    func opened(_ session: RoomSession) async throws {
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.phase == .admitted })
    }

    func message(_ id: ClientMessageID, failure: String? = nil) -> UnsentMessage {
        UnsentMessage(clientMessageId: id, body: "<p>Kept</p>", plainText: "Kept", createdAt: Date(timeIntervalSinceReferenceDate: 1000), failure: failure)
    }

    func created(_ id: MessageID, clientMessageId: ClientMessageID, seq: Int) -> String {
        Fixtures.RoomFrames.messageCreated(Fixtures.message(id, "Hello", by: Fixtures.ada, minute: 9, clientMessageId: clientMessageId), seq: seq)
    }

    // MARK: Failing

    @Test func aSessionGoesOnWorkingWhileWritesFailAndCatchesUpOnAFlush() async throws {
        let store = MemoryUnsentMessageStore()
        store.failsWrites = true
        let session = session(store)
        try await opened(session)
        let socket = try #require(connector.latest)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await eventually { socket.sent("message.create").count == 1 })
        #expect(await eventually { session.unsentState == .failed(UnsentStoreError(.unwritable)) })
        #expect(store.saved.isEmpty)

        await #expect(throws: UnsentStoreError.self) { try await session.flushUnsent() }
        store.failsWrites = false
        try await session.flushUnsent()
        #expect(store.saved[key()]?.map(\.clientMessageId) == [id])
        #expect(session.unsentState == .saved)
    }

    @Test func aFailedWriteIsTriedAgainAsTheSessionComesBack() async throws {
        let store = MemoryUnsentMessageStore()
        store.failsWrites = true
        let session = session(store)
        try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await eventually { session.unsentState != .saving })
        store.failsWrites = false
        session.holdBack()
        session.resume()
        #expect(await eventually { store.saved[key()]?.map(\.clientMessageId) == [id] })
        #expect(await eventually { session.unsentState == .saved })
    }

    @Test func whatCantBeReadIsntWrittenOverAndJoinsWhatWasSentOnceItReads() async throws {
        let store = MemoryUnsentMessageStore()
        let kept = message("kept_1")
        try store.save([kept], for: key())
        store.failsReads = true
        let session = session(store)
        try await opened(session)
        let socket = try #require(connector.latest)
        #expect(session.unsentState == .failed(UnsentStoreError(.unreadable)))
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        await settle()
        #expect(store.saved[key()] == [kept])

        store.failsReads = false
        try await session.flushUnsent()
        #expect(Set(session.timeline.pending.map(\.clientMessageId)) == ["kept_1", id])
        #expect(Set(store.saved[key()]?.map(\.clientMessageId) ?? []) == ["kept_1", id])
        // Read once the room let the socket in, so it's asked about on its own.
        #expect(socket.sent("message.check").contains(.checkMessages(clientMessageIds: ["kept_1"])))
        #expect(session.unsentState == .saved)
    }

    @Test func aFileOfANewerVersionIsNeverWrittenOver() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unsent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        let file = store.fileURL(for: key())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":9,"key":{},"messages":[]}"#
        try Data(json.utf8).write(to: file)
        let session = session(store)
        try await opened(session)
        #expect(session.unsentState == .failed(UnsentStoreError(.newerVersion(9), file: file)))
        session.send(body: "<p>Hello</p>", plainText: "Hello")
        await #expect(throws: UnsentStoreError.self) { try await session.flushUnsent() }
        #expect(try Data(contentsOf: file) == Data(json.utf8))
    }

    // MARK: Corrupt files

    @Test func aFileThatCantBeReadIsReportedLostAndSavingGoesOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unsent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        let file = store.fileURL(for: key())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let session = session(store)
        try await opened(session)
        #expect(session.unsentLoss?.kind == .corrupt)
        #expect(session.unsentLoss?.recovered == nil)
        #expect(session.timeline.pending.isEmpty)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        try await session.flushUnsent()
        #expect(try store.messages(for: key()).map(\.clientMessageId) == [id])
        #expect(session.unsentState == .saved)
    }

    @Test func whatCouldBeReadOfAFileComesBackAndIsWrittenAgainOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unsent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileUnsentMessageStore(folder: folder)
        let file = store.fileURL(for: key())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":1,"key":{"server":"https://ember.test","userID":"\#(Fixtures.ada.id.rawValue)","roomID":"\#(Fixtures.general.id.rawValue)"},"messages":["#
            + #"{"clientMessageId":"kept_1","body":"<p>Kept</p>","plainText":"Kept","createdAt":1000,"failure":"Too long"},{"clientMessageId":7}]}"#
        try Data(json.utf8).write(to: file)
        let session = session(store)
        try await opened(session)
        #expect(session.unsentLoss?.kind == .corrupt)
        #expect(session.unsentLoss?.lost == 1)
        #expect(session.timeline.pending.map(\.clientMessageId) == ["kept_1"])
        // Unchanged since it was read, and written all the same, so the file reads whole.
        try await session.flushUnsent()
        #expect(try FileUnsentMessageStore(folder: folder).messages(for: key()) == [message("kept_1", failure: "Too long")])
    }

    // MARK: The writer

    @Test func writesComeOffTheMainActorInOrderWithOnlyTheNewestWaiting() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        store.hold()
        let first = session.send(body: "<p>One</p>", plainText: "One")
        #expect(await eventually { store.waiting == 1 })
        // The main actor goes on meanwhile.
        let second = session.send(body: "<p>Two</p>", plainText: "Two")
        let third = session.send(body: "<p>Three</p>", plainText: "Three")
        #expect(session.unsentState == .saving)
        store.release()
        try await session.flushUnsent()
        let room = Fixtures.general.id.rawValue
        #expect(store.log == ["save \(room) [\"\(first)\"]", "save \(room) [\"\(first)\", \"\(second)\", \"\(third)\"]"])
        #expect(session.unsentState == .saved)
    }

    @Test func aListConfirmedWhileItsWriteIsGoingIsWrittenEmpty() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        let socket = try #require(connector.latest)
        store.hold()
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        #expect(await eventually { store.waiting == 1 })
        socket.serverSends(created("m009", clientMessageId: id, seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        store.release()
        try await session.flushUnsent()
        let room = Fixtures.general.id.rawValue
        #expect(store.log == ["save \(room) [\"\(id)\"]", "save \(room) []"])
        #expect(store.memory.saved.isEmpty)
    }

    @Test func aListConfirmedWhileItsWriteIsWaitingIsWrittenEmpty() async throws {
        let store = RecordingStore()
        let engines = session(store, roomID: Fixtures.engines.id)
        let general = session(store)
        try await opened(engines)
        try await opened(general)
        let socket = try #require(connector.latest)
        store.hold()
        // A write for another room goes first, so this one waits: confirmed [], handed [m].
        engines.send(body: "<p>Elsewhere</p>", plainText: "Elsewhere")
        #expect(await eventually { store.waiting == 1 })
        let id = general.send(body: "<p>Hello</p>", plainText: "Hello")
        socket.serverSends(created("m009", clientMessageId: id, seq: 11))
        #expect(await eventually { general.timeline.pending.isEmpty })
        store.release()
        try await general.flushUnsent()
        #expect(store.log.last == "save \(Fixtures.general.id.rawValue) []")
        #expect(store.memory.saved[key()] == nil)
    }

    @Test func aNewSessionSeesWhatAnotherHandedOverAndIsntWrittenYet() async throws {
        let store = RecordingStore()
        let first = session(store)
        try await opened(first)
        store.hold()
        let one = first.send(body: "<p>One</p>", plainText: "One")
        #expect(await eventually { store.waiting == 1 })
        let two = first.send(body: "<p>Two</p>", plainText: "Two")
        first.shutDown()

        let second = session(store)
        second.signedIn(as: Fixtures.ada.id)
        #expect(second.timeline.pending.map(\.clientMessageId) == [one, two])
        store.release()
        try await second.flushUnsent()
        #expect(store.memory.saved[key()]?.map(\.clientMessageId) == [one, two])
    }

    @Test func nothingIsWrittenOnceShutDown() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        let id = session.send(body: "<p>Hello</p>", plainText: "Hello")
        try await session.flushUnsent()
        session.shutDown()
        session.discard(id)
        try await session.client.flushUnsent()
        #expect(store.log.count == 1)
        #expect(store.memory.saved[key()]?.map(\.clientMessageId) == [id])
    }

    @Test func aFlushIsntHeldUpBySavesHandedOverAfterIt() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        store.hold()
        defer { store.release() }
        let first = session.send(body: "<p>One</p>", plainText: "One")
        #expect(await eventually { store.waiting == 1 })
        let flushing = Task { try await UnsentWriter.writer(for: store).flush() }
        await settle()
        // Handed over after the flush began, and held back.
        session.send(body: "<p>Two</p>", plainText: "Two")
        store.letThrough()
        try await flushing.value
        #expect(store.log == ["save \(Fixtures.general.id.rawValue) [\"\(first)\"]"])
        #expect(store.waiting == 1)
    }

    @Test func aFlushReturnsWhenItsTaskIsCancelled() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        store.hold()
        defer { store.release() }
        session.send(body: "<p>One</p>", plainText: "One")
        #expect(await eventually { store.waiting == 1 })
        let started = ContinuousClock.now
        let flushing = Task { try await UnsentWriter.writer(for: store).flush() }
        let flushingRoom = Task { try await session.flushUnsent() }
        await settle()
        flushing.cancel()
        flushingRoom.cancel()
        for result in [await flushing.result, await flushingRoom.result] {
            #expect(throws: CancellationError.self) { try result.get() }
        }
        #expect(ContinuousClock.now - started < .seconds(RecordingStore.holdLimit / 2))
        #expect(store.waiting == 1)
        #expect(store.log.isEmpty)
    }

    @Test func oneWriterForEachStore() {
        let store = MemoryUnsentMessageStore()
        let other = MemoryUnsentMessageStore()
        #expect(UnsentWriter.writer(for: store) === UnsentWriter.writer(for: store))
        #expect(UnsentWriter.writer(for: store) !== UnsentWriter.writer(for: other))
    }

    // MARK: Discarding

    @Test func discardingDropsSavesStillWaitingSoNothingComesBack() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        store.hold()
        let one = session.send(body: "<p>One</p>", plainText: "One")
        #expect(await eventually { store.waiting == 1 })
        session.send(body: "<p>Two</p>", plainText: "Two")
        session.shutDown()
        let discarding = Task { try await store.discardUnsent(server: server, userID: Fixtures.ada.id) }
        await settle()
        store.release()
        try await discarding.value
        #expect(store.log == ["save \(Fixtures.general.id.rawValue) [\"\(one)\"]", "remove \(Fixtures.ada.id.rawValue)"])
        #expect(store.memory.saved.isEmpty)
    }

    @Test func aSaveGoingAsTheAccountIsDiscardedThatFailsIsntWrittenAfter() async throws {
        let store = RecordingStore()
        let session = session(store)
        try await opened(session)
        let old = session.send(body: "<p>Old</p>", plainText: "Old")
        try await session.flushUnsent()
        store.hold()
        defer { store.release() }
        let going = session.send(body: "<p>Going</p>", plainText: "Going")
        #expect(await eventually { store.waiting == 1 })
        session.shutDown()
        let discarding = Task { try await store.discardUnsent(server: server, userID: Fixtures.ada.id) }
        await settle()
        // The save going fails; the removal after it goes.
        store.memory.failsWrites = true
        store.release()
        try await discarding.value
        #expect(store.memory.saved.isEmpty)

        // Nothing of it is kept to go again.
        store.memory.failsWrites = false
        try await UnsentWriter.writer(for: store).flush()
        let room = Fixtures.general.id.rawValue
        #expect(store.log == ["save \(room) [\"\(old)\"]", "save \(room) [\"\(old)\", \"\(going)\"]", "remove \(Fixtures.ada.id.rawValue)"])
        #expect(store.memory.saved.isEmpty)
        #expect(UnsentWriter.writer(for: store).handed(for: key()) == nil)
    }

    @Test func aFailedRemovalIsTriedAgainBeforeLaterSaves() async throws {
        let store = MemoryUnsentMessageStore()
        let first = session(store)
        try await opened(first)
        let old = first.send(body: "<p>Old</p>", plainText: "Old")
        try await first.flushUnsent()
        first.shutDown()
        store.failsRemovals = true
        await #expect(throws: UnsentStoreError.self) { try await store.discardUnsent(server: server, userID: Fixtures.ada.id) }
        #expect(store.saved[key()]?.map(\.clientMessageId) == [old])

        // Signed in again: what was discarded doesn't come back, and nothing's written before it goes.
        let second = session(store)
        try await opened(second)
        #expect(second.timeline.pending.isEmpty)
        let new = second.send(body: "<p>New</p>", plainText: "New")
        #expect(await eventually { second.unsentState == .failed(UnsentStoreError(.couldNotRemove)) })
        #expect(store.saved[key()]?.map(\.clientMessageId) == [old])

        store.failsRemovals = false
        try await second.flushUnsent()
        #expect(store.saved[key()]?.map(\.clientMessageId) == [new])
        #expect(second.unsentState == .saved)
    }

    // MARK: State

    @Test func statesCompareByKindAndFile() {
        let file = URL(filePath: "/tmp/a.json")
        #expect(UnsentState.failed(UnsentStoreError(.unwritable, file: file)) == .failed(UnsentStoreError(.unwritable, file: file, underlying: CocoaError(.fileWriteOutOfSpace))))
        #expect(UnsentState.failed(UnsentStoreError(.unwritable, file: file)) != .failed(UnsentStoreError(.couldNotRemove, file: file)))
        #expect(UnsentState.failed(UnsentStoreError(.unwritable, file: file)) != .failed(UnsentStoreError(.unwritable)))
        #expect(UnsentState.saved != .saving)
    }
}

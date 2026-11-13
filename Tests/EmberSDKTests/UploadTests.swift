import EmberTesting
import Foundation
import Synchronization
import Testing
@testable import EmberSDK

/// A file of `bytes` in a folder of its own, deleted with the folder when the test is done.
struct TestFile {
    let url: URL

    init(_ bytes: [UInt8], name: String = "notes.txt") throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ember-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
    }

    /// A file of `size` zero bytes that takes no room on disk, for one too large to write out.
    init(sparse size: Int, name: String = "notes.txt") throws {
        try self.init([], name: name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The file as a source the SDK leaves where it is.
    func source(contentType: String = "text/plain", preview: UploadPreview? = nil) throws -> UploadSource {
        try UploadSource(fileURL: url, contentType: contentType, preview: preview)
    }

    /// The file as a source the SDK deletes once it's done with it.
    func temporarySource(contentType: String = "text/plain", preview: UploadPreview? = nil) throws -> UploadSource {
        try UploadSource.temporary(fileURL: url, contentType: contentType, preview: preview)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

let uploads = "/api/rooms/room-general/uploads"

/// The path of part `n` of upload `id`.
func partPath(_ n: Int, of id: String = "upload_1") -> String { "\(uploads)/\(id)/parts/\(n)" }

/// The client's side: the three routes, in order.
@Suite struct UploadRouteTests {
    let transport = MockHTTPTransport()
    let timing: EmberTiming
    let clock: ManualClock
    let client: EmberClient

    init() {
        (timing, clock) = manualTiming()
        client = .mock(transport: transport, timing: timing)
    }

    @Test func partsGoInOrderWithThePreviewBeforeTheLast() async throws {
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        let preview = UploadPreview(data: Data([1, 2, 3]), contentType: "image/webp")
        let posted = Fixtures.fileMessage("m100", clientMessageId: "c1")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: posted)

        let message = try await client.upload(try file.source(preview: preview), in: Fixtures.general.id, clientMessageId: "c1")
        #expect(message == posted)

        let sent = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(sent == [
            "POST \(uploads)",
            "PUT \(partPath(1))",
            "PUT \(partPath(2))",
            "PUT \(uploads)/upload_1/preview",
            "PUT \(partPath(3))",
        ])
        let start = try #require(transport.lastBody("POST", uploads))
        #expect(start["name"] as? String == "notes.txt")
        #expect(start["type"] as? String == "text/plain")
        #expect(start["size"] as? Int == 10)
        #expect(start["clientMessageId"] as? String == "c1")
        #expect(start["parentId"] == nil)
        #expect(start["alsoSend"] == nil)

        #expect(transport.bodies("PUT", partPath(1)) == [Data([0, 1, 2, 3])])
        #expect(transport.bodies("PUT", partPath(2)) == [Data([4, 5, 6, 7])])
        #expect(transport.bodies("PUT", partPath(3)) == [Data([8, 9])])
        #expect(transport.bodies("PUT", "\(uploads)/upload_1/preview") == [preview.data])

        let parts = (1 ... 3).compactMap { transport.requests("PUT", partPath($0)).first }
        #expect(parts.map { $0.value(forHTTPHeaderField: "Content-Length") } == ["4", "4", "2"])
        for request in parts + transport.requests("POST", uploads) {
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://ember.test")
            #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        }
        let previewRequest = try #require(transport.requests("PUT", "\(uploads)/upload_1/preview").first)
        #expect(previewRequest.value(forHTTPHeaderField: "Content-Type") == "image/webp")
        #expect(previewRequest.value(forHTTPHeaderField: "Content-Length") == "3")
    }

    @Test func aOnePartFileSendsItsPreviewFirst() async throws {
        let file = try TestFile([7, 7])
        defer { file.remove() }
        let preview = UploadPreview(data: Data([1]), contentType: "image/png")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))

        _ = try await client.upload(try file.source(preview: preview), in: Fixtures.general.id, clientMessageId: "c1")
        #expect(transport.requests.map { $0.url?.path ?? "" } == [uploads, "\(uploads)/upload_1/preview", partPath(1)])
    }

    @Test func anEmptyFileStillSendsOnePart() async throws {
        let file = try TestFile([])
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))

        _ = try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1")
        #expect(transport.bodies("PUT", partPath(1)) == [Data()])
        #expect(transport.requests("PUT", partPath(1)).first?.value(forHTTPHeaderField: "Content-Length") == "0")
    }

    @Test func aPartAnswersNothingOr201Or200() async throws {
        let posted = Fixtures.fileMessage("m100", clientMessageId: "c1")
        transport.stub("PUT", partPath(1), status: 204, json: "")
        transport.stub("PUT", partPath(2), status: 201, json: Fixtures.messageJSON(posted))
        transport.stub("PUT", partPath(3), status: 200, json: Fixtures.messageJSON(posted))
        let room = Fixtures.general.id

        #expect(try await client.uploadPart(in: room, upload: "upload_1", part: 1, data: Data([1])) == nil)
        #expect(try await client.uploadPart(in: room, upload: "upload_1", part: 2, data: Data([1])) == posted)
        #expect(try await client.uploadPart(in: room, upload: "upload_1", part: 3, data: Data([1])) == posted)
    }

    @Test func aFinishedUploadEndsAtThePartThatSaysSo() async throws {
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        let posted = Fixtures.fileMessage("m100", clientMessageId: "c1")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: posted)
        // Posted already, as when a retry follows an answer that was lost.
        transport.stub("PUT", partPath(1), status: 200, json: Fixtures.messageJSON(posted))

        #expect(try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1") == posted)
        #expect(transport.requests("PUT", partPath(2)).isEmpty)
    }

    @Test func aRefusedPreviewDoesntStopTheFile() async throws {
        let file = try TestFile([1, 2])
        defer { file.remove() }
        let posted = Fixtures.fileMessage("m100", clientMessageId: "c1")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        transport.stub("PUT", "\(uploads)/upload_1/preview", status: 422, json: Fixtures.errorJSON("A preview fits within 1200×800"))

        let preview = UploadPreview(data: Data([1]), contentType: "image/png")
        #expect(try await client.upload(try file.source(preview: preview), in: Fixtures.general.id, clientMessageId: "c1") == posted)
    }

    @Test func aPartTheNetworkDroppedIsSentAgain() async throws {
        let failures = Mutex(1)
        transport.stub("PUT", partPath(1)) { _ in
            if failures.withLock({ count in defer { count -= 1 }; return count > 0 }) { throw URLError(.networkConnectionLost) }
            return (204, "")
        }
        let client = client
        let task = Task { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1])) }
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(transport.requests("PUT", partPath(1)).count == 1)
        clock.advance(by: timing.backoff(attempt: 0))
        #expect(try await task.value == nil)
        #expect(transport.requests("PUT", partPath(1)).count == 2)
    }

    @Test func aFirstPartSentAgainRidesOutTheServersAlreadyUploading() async throws {
        // The first try's answer is lost while the server still has it; the try after loses the race
        // to it and hears 409; the one after that is taken as the first part again.
        let answers = Mutex(0)
        transport.stub("PUT", partPath(1)) { _ in
            switch answers.withLock({ count in count += 1; return count }) {
            case 1: throw URLError(.networkConnectionLost)
            case 2: return (409, Fixtures.errorJSON("The first part is already uploading"))
            default: return (204, "")
            }
        }
        let client = client
        let task = Task { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1])) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: timing.backoff(attempt: 0))
        #expect(try await task.value == nil)
        #expect(transport.requests("PUT", partPath(1)).count == 3)
    }

    @Test func aFirstPartStill409AfterItsTriesSaysUploadFailed() async throws {
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))
        transport.stub("PUT", partPath(1), status: 409, json: Fixtures.errorJSON("The first part is already uploading"))
        await #expect { try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1") } throws: {
            ($0 as? EmberError)?.message == Uploads.failed
        }
        // Within the same budget as a dropped part.
        #expect(transport.requests("PUT", partPath(1)).count == EmberClient.partRetries + 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aPartIsTriedSevenTimesAtMost() async throws {
        transport.stub("PUT", partPath(1)) { _ in throw URLError(.notConnectedToInternet) }
        let client = client
        let task = Task { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1])) }
        #expect(EmberClient.partRetries == 6)
        for attempt in 0 ..< EmberClient.partRetries {
            #expect(await eventually { clock.sleeperCount == 1 })
            clock.advance(by: timing.backoff(attempt: attempt))
        }
        await #expect { try await task.value } throws: { ($0 as? EmberError)?.isUnreachable == true }
        #expect(transport.requests("PUT", partPath(1)).count == 7)
    }

    @Test(arguments: [408, 429, 500, 503])
    func aPartTheServerCouldntTakeJustThenIsSentAgain(_ status: Int) async throws {
        let failures = Mutex(1)
        transport.stub("PUT", partPath(1)) { _ in
            failures.withLock { count in defer { count -= 1 }; return count > 0 } ? (status, Fixtures.errorJSON("Busy")) : (204, "")
        }
        let client = client
        let task = Task { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1])) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: timing.backoff(attempt: 0))
        #expect(try await task.value == nil)
        #expect(transport.requests("PUT", partPath(1)).count == 2)
    }

    @Test func aRefusedPartIsntSentAgain() async throws {
        transport.stub("PUT", partPath(2), status: 409, json: Fixtures.errorJSON("The first part goes first"))
        await #expect { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 2, data: Data([1])) } throws: {
            ($0 as? EmberError) == EmberError(status: 409, message: "The first part goes first")
        }
        #expect(transport.requests("PUT", partPath(2)).count == 1)
        transport.stub("PUT", partPath(1), status: 413, json: Fixtures.errorJSON("Part 1 is 2 bytes"))
        await #expect { try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1])) } throws: {
            ($0 as? EmberError)?.status == 413
        }
        #expect(transport.requests("PUT", partPath(1)).count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test(arguments: [
        UploadTicket(id: "upload_1", partSize: -4, parts: 3),
        UploadTicket(id: "upload_1", partSize: 0, parts: 1),
        UploadTicket(id: "upload_1", partSize: 4, parts: 0),
        UploadTicket(id: "upload_1", partSize: 4, parts: -1),
        UploadTicket(id: "upload_1", partSize: 4, parts: 2),
        UploadTicket(id: "upload_1", partSize: 4, parts: 4),
        UploadTicket(id: "upload_1", partSize: 1, parts: 1_000_000_000),
        UploadTicket(id: "upload_1", partSize: Int.max, parts: 1),
        UploadTicket(id: "upload_1", partSize: Int.max / 2, parts: Int.max),
    ])
    func aTicketThatDoesntFitTheFileStopsBeforeAnyPart(_ ticket: UploadTicket) async throws {
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))
        transport.stub("POST", uploads, status: 201, json: Fixtures.uploadTicketJSON(ticket))
        await #expect { try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1") } throws: {
            ($0 as? EmberError) == EmberError(kind: .undecodable, status: 201, message: "The server’s answer couldn’t be read.")
        }
        #expect(transport.requests.map { $0.httpMethod ?? "" } == ["POST"])
    }

    @Test func cancellingStopsTheUpload() async throws {
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))
        let gate = transport.hold("PUT", partPath(1))
        let client = client
        let source = try file.source()
        let task = Task { try await client.upload(source, in: Fixtures.general.id, clientMessageId: "c1") }
        await gate.waitForRequest()
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests("PUT", partPath(2)).isEmpty)
    }

    @Test func aFileOver250MBIsRefusedBeforeAnythingIsSent() async throws {
        let file = try TestFile(sparse: Limits.fileBytes + 1)
        defer { file.remove() }
        let source = try file.source()
        #expect(source.isTooLarge)
        await #expect { try await client.upload(source, in: Fixtures.general.id, clientMessageId: "c1") } throws: {
            ($0 as? EmberError)?.message == "notes.txt is too large. Choose a file that’s 250 MB or smaller."
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func aFileThatCantBeReadIsntASource() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ember-missing-\(UUID().uuidString)")
        #expect(throws: EmberError.self) { try UploadSource(fileURL: missing, contentType: "text/plain") }
    }

    @Test func aFileThatCantBeReadIsntTheNetworksFault() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ember-missing-\(UUID().uuidString)")
        let error = try #require(#expect(throws: EmberError.self) { try UploadSource(fileURL: missing, contentType: "text/plain") })
        #expect(error.kind == .unreadableFile)
        #expect(!error.isUnreachable)
    }

    @Test func aFileGoneBeforeItsSentIsntTheNetworksFault() async throws {
        let file = try TestFile([1])
        let source = try file.source()
        file.remove()
        let error = await #expect(throws: EmberError.self) { try await client.upload(source, in: Fixtures.general.id, clientMessageId: "c1") }
        #expect(error?.kind == .unreadableFile)
        #expect(error?.isUnreachable == false)
        #expect(transport.requests.isEmpty)
    }

    @Test func aSuccessThatCantBeReadIsntAnHTTPFailure() async throws {
        transport.stub("PUT", partPath(1), status: 201, json: "{\"not\": \"a message\"}")
        let error = await #expect(throws: EmberError.self) {
            try await client.uploadPart(in: Fixtures.general.id, upload: "upload_1", part: 1, data: Data([1]))
        }
        #expect(error?.kind == .undecodable)
        #expect(error?.status == 201)
        #expect(error?.isUnreachable == false)
    }

    @Test func aRefusalIsAnHTTPFailureAndNoAnswerIsUnreachable() {
        #expect(EmberError(status: 422, message: "No.").kind == .http)
        #expect(EmberError(status: 0, message: "Gone.").kind == .unreachable)
        #expect(EmberError(status: 0, message: "Gone.").isUnreachable)
        #expect(!EmberError(kind: .refused, message: "No.").isUnreachable)
        #expect(EmberError(status: 401, message: "Who?").isSignedOut)
    }

    @Test func aNameOrTypeTheServerWouldRefuseIsntASource() throws {
        let file = try TestFile([1])
        defer { file.remove() }
        func refusal(name: String? = nil, contentType: String = "text/plain") -> String? {
            do {
                _ = try UploadSource(fileURL: file.url, name: name, contentType: contentType)
                return nil
            } catch {
                return (error as? EmberError)?.message
            }
        }
        #expect(refusal(name: "") == "A file needs a name.")
        #expect(refusal(name: " \n\u{FEFF}") == "A file needs a name.")
        #expect(refusal(name: String(repeating: "a", count: 256)) == "That file’s name is too long.")
        // Counted in UTF-16 units, as the server counts: 128 emoji are 256 of them.
        #expect(refusal(name: String(repeating: "😀", count: 128)) == "That file’s name is too long.")
        #expect(refusal(contentType: String(repeating: "a", count: 256)) == "That file’s type is too long.")
        #expect(refusal(name: String(repeating: "a", count: 255), contentType: String(repeating: "a", count: 255)) == nil)
        #expect(refusal(contentType: "") == nil)
        #expect(refusal() == nil)
    }

    @Test func aReplysFileSaysWhichThread() async throws {
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", parentID: "m001", alsoSent: true, clientMessageId: "c1"))

        _ = try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1", parentId: "m001", delivery: .threadAndRoom)
        let start = try #require(transport.lastBody("POST", uploads))
        #expect(start["parentId"] as? String == "m001")
        #expect(start["alsoSend"] as? Bool == true)
    }

    @Test func aFileForTheThreadOnlyOrOutsideAThreadLeavesAlsoSendOut() async throws {
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", parentID: "m001", clientMessageId: "c1"))
        _ = try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c1", parentId: "m001")
        let reply = try #require(transport.lastBody("POST", uploads))
        #expect(reply["parentId"] as? String == "m001")
        #expect(reply["alsoSend"] == nil)

        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m101", clientMessageId: "c2"))
        _ = try await client.upload(try file.source(), in: Fixtures.general.id, clientMessageId: "c2", delivery: .threadAndRoom)
        let message = try #require(transport.lastBody("POST", uploads))
        #expect(message["parentId"] == nil)
        #expect(message["alsoSend"] == nil)
    }
}

/// The session's side: pending, progress, and what's posted.
@MainActor @Suite struct SessionUploadTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let timing: EmberTiming
    let clock: ManualClock

    init() {
        (timing, clock) = manualTiming()
    }

    func opened() async throws -> (RoomSession, MockSocketConnection) {
        connector.welcomeEverySocket()
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return (session, try #require(connector.latest))
    }

    @Test func aFileIsPendingUntilPosted() async throws {
        let (session, _) = try await opened()
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(2))
        let ids = session.send(files: [try file.source()])
        let id = try #require(ids.first)
        let posted = Fixtures.fileMessage("m100", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: posted)

        let pending = try #require(session.timeline.pending.first)
        #expect(pending.clientMessageId == id)
        #expect(pending.upload == PendingUpload(name: "notes.txt", contentType: "text/plain", byteSize: 10))
        #expect(pending.plainText == "notes.txt")

        await gate.waitForRequest()
        #expect(await eventually { session.timeline.pending.first?.upload?.sentBytes == 4 })
        gate.release()
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(session.timeline.messages.last == posted)
    }

    @Test func aFilePostedIsShownOnceWhicheverLandsFirst() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(session.send(files: [try file.source()]).first)
        let posted = Fixtures.fileMessage("m100", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)

        await gate.waitForRequest()
        socket.serverSends(Fixtures.RoomFrames.messageCreated(posted, seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        gate.release()
        #expect(await eventually { !session.isBusy })
        #expect(session.timeline.messages.filter { $0.id == "m100" }.count == 1)
    }

    @Test func aFileTheRoomConfirmedIsntFailedByALostAnswer() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(session.send(files: [try file.temporarySource()]).first)
        let posted = Fixtures.fileMessage("m100", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        // The part's answer is a failure that isn't tried again, though the room posted the file.
        transport.stub("PUT", partPath(1), status: 400, json: Fixtures.errorJSON("Bad request"))

        await gate.waitForRequest()
        socket.serverSends(Fixtures.RoomFrames.messageCreated(posted, seq: 11))
        #expect(await eventually { session.timeline.pending.isEmpty })
        gate.release()
        #expect(await eventually { !session.isBusy })
        #expect(session.failedUploads.isEmpty)
        #expect(session.timeline.pending.isEmpty)
        #expect(session.timeline.messages.last == posted)
        #expect(socket.sent("message.check").isEmpty)
        #expect(!file.exists)
    }

    @Test func aThreadsFileTheRoomConfirmedIsntFailedByALostAnswer() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(thread.send(files: [try file.temporarySource()]).first)
        let posted = Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        transport.stub("PUT", partPath(1), status: 400, json: Fixtures.errorJSON("Bad request"))

        await gate.waitForRequest()
        socket.serverSends(Fixtures.RoomFrames.messageCreated(posted, seq: 11))
        #expect(await eventually { thread.timeline.pending.isEmpty })
        gate.release()
        #expect(await eventually { session.running == nil })
        #expect(session.failedUploads.isEmpty)
        #expect(thread.timeline.pending.isEmpty)
        #expect(thread.timeline.replies.map(\.id) == ["r100"])
        #expect(!file.exists)
        lease.close()
    }

    @Test func aFailedFileWaitingForARetryKeepsTheSessionBusy() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads, status: 500, json: Fixtures.errorJSON("Something went wrong"))
        let id = try #require(session.send(files: [try file.temporarySource()]).first)
        #expect(await eventually { session.timeline.pending.first?.failure != nil })
        #expect(session.isBusy)

        // The check finds it was posted after all: nothing is left to retry.
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [id], missing: []))
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(!session.isBusy)
        // Let go of, with its temporary file, as the answer lands.
        #expect(session.failedUploads[id] == nil)
        #expect(!file.exists)
    }

    @Test func aFailedFileTheRoomConfirmsGoesAtOnce() async throws {
        let (session, socket) = try await opened()
        let confirmed = try TestFile([1], name: "confirmed.txt")
        let waiting = try TestFile([2], name: "waiting.txt")
        defer { [confirmed, waiting].forEach { $0.remove() } }
        transport.stub("POST", uploads, status: 500, json: Fixtures.errorJSON("Something went wrong"))
        let ids = session.send(files: [try confirmed.temporarySource(), try waiting.temporarySource()])
        #expect(await eventually { session.timeline.pending.allSatisfy { $0.failure != nil } && session.failedUploads.count == 2 })

        socket.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.fileMessage("m100", clientMessageId: ids[0]), seq: 11))
        #expect(await eventually { session.failedUploads[ids[0]] == nil })
        #expect(!confirmed.exists)
        // The other is still failed, so it stays for a retry, whatever else the room says.
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [ids[1]]))
        await settle()
        #expect(session.failedUploads[ids[1]] != nil)
        #expect(waiting.exists)
        #expect(session.isBusy)
    }

    @Test func aThreadsFailedFileTheRoomConfirmsGoesAtOnce() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads, status: 500, json: Fixtures.errorJSON("Something went wrong"))
        let id = try #require(thread.send(files: [try file.temporarySource()]).first)
        #expect(await eventually { session.failedUploads[id] != nil })

        socket.serverSends(Fixtures.RoomFrames.messageCreated(Fixtures.fileMessage("r100", parentID: "m001", clientMessageId: id), seq: 11))
        #expect(await eventually { thread.timeline.pending.isEmpty })
        #expect(session.failedUploads.isEmpty)
        #expect(!file.exists)
        lease.close()
    }

    @Test func aShutDownSessionSendsNoFiles() async throws {
        let (session, socket) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let roomFile = try TestFile([1], name: "room.txt")
        let threadFile = try TestFile([2], name: "thread.txt")
        let kept = try TestFile([3], name: "kept.txt")
        defer { [roomFile, threadFile, kept].forEach { $0.remove() } }
        session.shutDown()

        let ids = session.send(files: [try roomFile.temporarySource(), try kept.source()], body: "<p>Hi</p>", plainText: "Hi")
        let threadIDs = thread.send(files: [try threadFile.temporarySource()], body: "<p>Hi</p>", plainText: "Hi")
        // Nothing went, so no id stands for anything.
        #expect(ids.isEmpty && threadIDs.isEmpty)
        #expect(session.timeline.pending.isEmpty && thread.timeline.pending.isEmpty)
        #expect(session.running == nil && session.outgoing.isEmpty && session.failedUploads.isEmpty)
        // The thread isn't tied to the room again.
        #expect(session.threads.isEmpty)
        #expect(!roomFile.exists && !threadFile.exists)
        #expect(kept.exists)
        await settle()
        #expect(transport.requests("POST", uploads).isEmpty)
        #expect(socket.sent("message.create").isEmpty)
        lease.close()
    }

    // MARK: Temporary files

    @Test func aSourceIsPreservedUnlessItSaysOtherwise() throws {
        let file = try TestFile([1])
        defer { file.remove() }
        let plain = try UploadSource(fileURL: file.url, contentType: "text/plain")
        #expect(plain.disposition == .preserve)
        let preserved = try UploadSource(fileURL: file.url, contentType: "text/plain", disposition: .preserve)
        #expect(preserved == plain)
        let temporary = try UploadSource.temporary(fileURL: file.url, name: "n.txt", contentType: "text/plain")
        #expect(temporary.disposition == .deleteWhenFinished)
        let spelledOut = try UploadSource(fileURL: file.url, name: "n.txt", contentType: "text/plain", disposition: .deleteWhenFinished)
        #expect(temporary == spelledOut)
        #expect(temporary.name == "n.txt" && temporary.byteSize == 1 && temporary.fileURL == file.url)
    }

    @Test func onlyATemporarySourceIsDeleted() throws {
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        let file = try TestFile([1])
        defer { file.remove() }
        session.removeIfTemporary(try file.source())
        #expect(file.exists)
        session.removeIfTemporary(try file.temporarySource())
        #expect(!file.exists)
    }

    @Test func aPreservedFileStaysOncePostedOrDiscarded() async throws {
        let (session, _) = try await opened()
        let posted = try TestFile([1])
        let discarded = try TestFile(Array(0 ..< 10))
        defer { posted.remove(); discarded.remove() }
        let first = transport.hold("PUT", partPath(1))
        let id = try #require(session.send(files: [try posted.source()]).first)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: id))
        await first.waitForRequest()
        first.release()
        #expect(await eventually { session.timeline.pending.isEmpty && !session.isBusy })
        #expect(posted.exists)

        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: Fixtures.fileMessage("m101", clientMessageId: "c1"))
        let gate = transport.hold("PUT", partPath(1))
        let held = try #require(session.send(files: [try discarded.source()]).first)
        await gate.waitForRequest()
        session.discard(held)
        gate.release()
        await settle()
        #expect(discarded.exists)
    }

    @Test func aTemporaryFileAloneInItsFolderTakesTheFolder() throws {
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        let file = try TestFile([1])
        defer { file.remove() }
        session.removeIfTemporary(try file.temporarySource())
        #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }

    @Test func aFolderWithAnotherFileInItStays() throws {
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        let file = try TestFile([1])
        defer { file.remove() }
        let other = file.url.deletingLastPathComponent().appendingPathComponent("other.txt")
        try Data([2]).write(to: other)
        session.removeIfTemporary(try file.temporarySource())
        #expect(!file.exists)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aFileInTheTemporaryDirectoryLeavesTheDirectory() throws {
        let session = RoomSession(client: .mock(transport: transport, connector: connector, timing: timing), roomID: Fixtures.general.id)
        let temporary = FileManager.default.temporaryDirectory
        let url = temporary.appendingPathComponent("ember-tests-\(UUID().uuidString).txt")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        session.removeIfTemporary(try UploadSource.temporary(fileURL: url, contentType: "text/plain"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func aRefusedFileSaysWhyAndIsChecked() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads, status: 422, json: Fixtures.errorJSON("Files must be 250 MB or smaller."))
        let id = try #require(session.send(files: [try file.source()]).first)

        #expect(await eventually { session.timeline.pending.first?.failure == "Files must be 250 MB or smaller." })
        #expect(await eventually { socket.sent("message.check") == [.checkMessages(clientMessageIds: [id])] })
        #expect(session.notice == nil)
    }

    @Test func aFileTheNetworkLostSaysUploadFailed() async throws {
        let (session, _) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads) { _ in throw URLError(.notConnectedToInternet) }
        session.send(files: [try file.source()])
        #expect(await eventually { session.timeline.pending.first?.failure == Uploads.failed })
    }

    @Test func aFailedFileGoesAgainFromTheStart() async throws {
        let (session, _) = try await opened()
        let file = try TestFile([1], name: "photo.jpg")
        defer { file.remove() }
        transport.stub("POST", uploads, status: 500, json: Fixtures.errorJSON("Something went wrong"))
        let id = try #require(session.send(files: [try file.temporarySource(contentType: "image/jpeg")]).first)
        #expect(await eventually { session.timeline.pending.first?.failure != nil })
        #expect(file.exists)

        let posted = Fixtures.fileMessage("m100", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        session.retry(id)
        #expect(session.timeline.pending.first?.failure == nil)
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(session.timeline.messages.last == posted)
        #expect(transport.requests("POST", uploads).count == 2)
        #expect(object(transport.requests("POST", uploads).last?.httpBody)?["clientMessageId"] as? String == id.rawValue)
        // A temporary file goes once it's posted, not before.
        #expect(!file.exists)
    }

    /// A three-part file whose second part is refused once (413), then answered by `later` in turn.
    func stubResumable(later: [Int]) {
        let ticket = Fixtures.uploadTicket(partSize: 4, parts: 3)
        transport.stub("POST", uploads, status: 201, json: Fixtures.uploadTicketJSON(ticket))
        transport.stub("PUT", partPath(1), status: 204, json: "")
        let answers = Mutex([413] + later)
        transport.stub("PUT", partPath(2)) { _ in
            let status = answers.withLock { $0.isEmpty ? 204 : $0.removeFirst() }
            return (status, status == 204 ? "" : Fixtures.errorJSON("No"))
        }
    }

    @Test func aRetriedFileGoesOnFromThePartsTheServerTook() async throws {
        let (session, _) = try await opened()
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        stubResumable(later: [])
        let sent = try #require(session.send(files: [try file.source()]).first)
        #expect(await eventually { session.timeline.pending.first?.failure != nil })
        #expect(transport.requests("PUT", partPath(1)).count == 1)
        transport.stub("PUT", partPath(3), status: 201, json: Fixtures.messageJSON(Fixtures.fileMessage("m100", clientMessageId: sent)))

        session.retry(sent)
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(transport.requests("POST", uploads).count == 1)
        #expect(transport.requests("PUT", partPath(1)).count == 1)
        #expect(transport.requests("PUT", partPath(2)).count == 2)
        #expect(transport.requests("PUT", partPath(3)).count == 1)
    }

    @Test func aRetriedFileTheServerForgotStartsAgain() async throws {
        let (session, _) = try await opened()
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        stubResumable(later: [404])
        let sent = try #require(session.send(files: [try file.source()]).first)
        #expect(await eventually { session.timeline.pending.first?.failure != nil })
        transport.stub("PUT", partPath(3), status: 201, json: Fixtures.messageJSON(Fixtures.fileMessage("m100", clientMessageId: sent)))

        session.retry(sent)
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(transport.requests("PUT", partPath(3)).count == 1)
        #expect(transport.requests("POST", uploads).count == 2)
        #expect(transport.requests("PUT", partPath(1)).count == 2)
        #expect(transport.requests("PUT", partPath(2)).count == 3)
    }

    @Test func aFileGoingUpAsksForBackgroundTimeUntilItsDone() async throws {
        let (session, _) = try await opened()
        let asked = Mutex<[String]>([])
        let ended = Mutex(0)
        session.backgroundTime = BackgroundTime { reason in
            asked.withLock { $0.append(reason) }
            return { ended.withLock { $0 += 1 } }
        }
        let file = try TestFile([1], name: "photo.jpg")
        defer { file.remove() }
        let gate = transport.hold("POST", uploads)
        let id = try #require(session.send(files: [try file.source(contentType: "image/jpeg")]).first)
        await gate.waitForRequest()
        #expect(asked.withLock { $0 } == ["Sending photo.jpg"])
        #expect(ended.withLock { $0 } == 0)

        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: id))
        gate.release()
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(ended.withLock { $0 } == 1)
    }

    @Test func discardingAFileStopsItAndDeletesATemporaryOne() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile(Array(0 ..< 10))
        defer { file.remove() }
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(partSize: 4, parts: 3), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(session.send(files: [try file.temporarySource()]).first)

        await gate.waitForRequest()
        session.discard(id)
        #expect(session.timeline.pending.isEmpty)
        #expect(!file.exists)
        gate.release()
        await settle()
        #expect(transport.requests("PUT", partPath(2)).isEmpty)
        #expect(session.timeline.pending.isEmpty)
        #expect(socket.sent("message.check").isEmpty)
        #expect(!session.isBusy)
    }

    @Test func filesGoFirstThenTheText() async throws {
        let (session, socket) = try await opened()
        let first = try TestFile([1], name: "a.txt")
        let second = try TestFile([2], name: "b.txt")
        defer { first.remove(); second.remove() }
        let gate = transport.hold("PUT", partPath(1, of: "upload_1"))
        let ids = session.send(files: [try first.source(), try second.source()], body: "<p>Both</p>", plainText: "Both")
        #expect(ids.count == 3)
        let tickets = Mutex(0)
        transport.stub("POST", uploads) { _ in
            let n = tickets.withLock { count in count += 1; return count }
            return (201, Fixtures.uploadTicketJSON(Fixtures.uploadTicket("upload_\(n)")))
        }
        transport.stub("PUT", partPath(1, of: "upload_1"), status: 201, json: Fixtures.messageJSON(Fixtures.fileMessage("m100", clientMessageId: ids[0])))
        transport.stub("PUT", partPath(1, of: "upload_2"), status: 201, json: Fixtures.messageJSON(Fixtures.fileMessage("m101", clientMessageId: ids[1])))
        #expect(session.timeline.pending.map(\.clientMessageId) == ids)
        #expect(session.timeline.pending.map(\.plainText) == ["a.txt", "b.txt", "Both"])

        await gate.waitForRequest()
        #expect(transport.requests("POST", uploads).count == 1)
        #expect(socket.sent("message.create").isEmpty)
        gate.release()
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: ids[2], body: "<p>Both</p>")] })
        #expect(transport.requests("POST", uploads).compactMap { object($0.httpBody)?["clientMessageId"] as? String } == [ids[0].rawValue, ids[1].rawValue])
        #expect(session.timeline.messages.suffix(2).map(\.id) == ["m100", "m101"])
    }

    @Test func aHeldTextIsntSentEarlyByAReconnectsCheck() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let ids = session.send(files: [try file.source()], body: "<p>After</p>", plainText: "After")
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: ids[0]))
        await gate.waitForRequest()

        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [ids[1]]))
        await settle()
        #expect(socket.sent("message.create").isEmpty)
        gate.release()
        #expect(await eventually { socket.sent("message.create").count == 1 })
    }

    @Test func aTextWithNoFilesGoesAtOnce() async throws {
        let (session, socket) = try await opened()
        let ids = session.send(files: [], body: "<p>Hi</p>", plainText: "Hi")
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: ids[0], body: "<p>Hi</p>")] })
    }

    @Test func aFileOver250MBIsntSent() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile(sparse: Limits.fileBytes + 1)
        defer { file.remove() }
        let ids = session.send(files: [try file.temporarySource()], body: "<p>Hi</p>", plainText: "Hi")
        // The refused file keeps its place among the ids.
        #expect(ids.count == 2)
        #expect(session.notice == "notes.txt is too large. Choose a file that’s 250 MB or smaller.")
        #expect(session.timeline.pending.map(\.clientMessageId) == [ids[1]])
        #expect(session.timeline.pending.map(\.plainText) == ["Hi"])
        #expect(await eventually { socket.sent("message.create") == [.createMessage(clientMessageId: ids[1], body: "<p>Hi</p>")] })
        #expect(transport.requests.isEmpty)
        // A temporary file that never becomes a job is deleted here, as nothing else would.
        #expect(!file.exists)
    }

    @Test func aRefusedFileKeepsTheOthersIdsInPlace() async throws {
        let (session, _) = try await opened()
        let small = try TestFile([1], name: "a.txt")
        let huge = try TestFile(sparse: Limits.fileBytes + 1, name: "huge.mov")
        let vast = try TestFile(sparse: Limits.fileBytes + 1, name: "vast.iso")
        let last = try TestFile([2], name: "b.txt")
        defer { [small, huge, vast, last].forEach { $0.remove() } }
        let gate = transport.hold("PUT", partPath(1))
        let sources = [try small.source(), try huge.source(), try vast.temporarySource(), try last.source()]
        let ids = session.send(files: sources)

        #expect(ids.count == 4)
        #expect(sources.map(\.isTooLarge) == [false, true, true, false])
        // Paired by position, as the app pairs them, the files that went line up with their pendings.
        #expect(session.timeline.pending.map(\.clientMessageId) == [ids[0], ids[3]])
        #expect(session.timeline.pending.map(\.plainText) == ["a.txt", "b.txt"])
        #expect(session.notice == "huge.mov is too large. Choose a file that’s 250 MB or smaller. vast.iso is too large. Choose a file that’s 250 MB or smaller.")
        // Only the temporary one is the SDK's to delete.
        #expect(huge.exists)
        #expect(!vast.exists)
        gate.release()
    }

    @Test func aThreadsRefusedFileKeepsItsPlaceAndIsDeleted() async throws {
        let (session, _) = try await opened()
        let thread = session.thread("m001")
        let lease = thread.open()
        let huge = try TestFile(sparse: Limits.fileBytes + 1, name: "huge.mov")
        let small = try TestFile([1], name: "a.txt")
        defer { [huge, small].forEach { $0.remove() } }
        let gate = transport.hold("POST", uploads)
        let ids = thread.send(files: [try huge.temporarySource(), try small.source()])

        #expect(ids.count == 2)
        #expect(thread.timeline.pending.map(\.clientMessageId) == [ids[1]])
        // The thread's screen shows it, not the room's under it.
        #expect(thread.notice == Uploads.tooLarge("huge.mov"))
        #expect(session.notice == nil)
        #expect(!huge.exists)
        gate.release()
        lease.close()
    }

    @Test func aFileCarriesOnWhileTheSocketReconnects() async throws {
        let (session, socket) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        let gate = transport.hold("PUT", partPath(1))
        let id = try #require(session.send(files: [try file.source()]).first)
        let posted = Fixtures.fileMessage("m100", clientMessageId: id)
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: posted)
        await gate.waitForRequest()

        socket.serverCloses(code: 1006)
        #expect(await eventually { session.status == .connecting })
        gate.release()
        #expect(await eventually { session.timeline.pending.isEmpty })
        #expect(session.timeline.messages.last == posted)
    }

    @Test func aBusySessionIsntLetGoOf() async throws {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
        let file = try TestFile([1])
        defer { file.remove() }
        let busy = workspace.session(for: Fixtures.general.id)
        let gate = transport.hold("POST", uploads)
        busy.send(files: [try file.source()])
        await gate.waitForRequest()
        for n in 0 ... Workspace.idleSessionLimit {
            _ = workspace.session(for: "room-\(n)")
        }
        #expect(workspace.session(for: Fixtures.general.id) === busy)
        gate.release()
    }

    @Test func shuttingDownDeletesTemporaryFilesGoingOrWaiting() async throws {
        let (session, _) = try await opened()
        let going = try TestFile([1], name: "going.txt")
        let waiting = try TestFile([2], name: "waiting.txt")
        let kept = try TestFile([3], name: "kept.txt")
        defer { [going, waiting, kept].forEach { $0.remove() } }
        let gate = transport.hold("PUT", partPath(1))
        transport.stubUpload(in: Fixtures.general.id, ticket: Fixtures.uploadTicket(), message: Fixtures.fileMessage("m100", clientMessageId: "c1"))
        session.send(files: [try going.temporarySource(), try waiting.temporarySource(), try kept.source()])
        await gate.waitForRequest()

        session.shutDown()
        #expect(!going.exists)
        #expect(!waiting.exists)
        // Not the SDK's to delete.
        #expect(kept.exists)
        gate.release()
        await settle()
        #expect(!session.isBusy)
    }

    @Test func shuttingDownDeletesATemporaryFileThatFailed() async throws {
        let (session, _) = try await opened()
        let file = try TestFile([1])
        defer { file.remove() }
        transport.stub("POST", uploads, status: 422, json: Fixtures.errorJSON("No."))
        session.send(files: [try file.temporarySource()])
        #expect(await eventually { session.timeline.pending.first?.failure == "No." })
        #expect(file.exists)
        session.shutDown()
        #expect(!file.exists)
    }
}

import Foundation

/// A file to send. `fileURL` is a file the SDK can read; it's read a part at a time, never whole.
/// Its properties are fixed once `init` has checked them.
public struct UploadSource: Sendable, Hashable {
    /// Where the file is on disk.
    public let fileURL: URL
    /// The name it's posted under.
    public let name: String
    /// Its type as the app knows it, such as `image/jpeg`; the server sniffs its own from the bytes.
    public let contentType: String
    /// How many bytes it has, as read from disk when the source was made.
    public let byteSize: Int
    /// A picture of the file for the timeline, made by the app. Optional.
    public let preview: UploadPreview?
    /// Whether the SDK deletes `fileURL` once the file is posted or discarded, and the folder it's in
    /// if that's left empty (unless it's the temporary directory itself).
    public let isTemporary: Bool

    /// Whether it's over `Limits.fileBytes`, so `send(files:…)` refuses it rather than sending it.
    public var isTooLarge: Bool { byteSize > Limits.fileBytes }

    /// Reads the size from disk; throws when the file can't be read, or when the server would
    /// refuse its name or type (`Uploads.refusal(name:contentType:)`): a blank name, or either
    /// over 255 UTF-16 code units. `name` is the file's own unless given.
    public init(fileURL: URL, name: String? = nil, contentType: String, preview: UploadPreview? = nil, isTemporary: Bool = false) throws {
        let name = name ?? fileURL.lastPathComponent
        if let refusal = Uploads.refusal(name: name, contentType: contentType) {
            throw EmberError(kind: .invalid, status: 422, message: refusal)
        }
        let size: Int?
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            size = values.isRegularFile == true ? values.fileSize : nil
        } catch {
            size = nil
        }
        guard let size, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw EmberError.unreadableFile
        }
        self.fileURL = fileURL
        self.name = name
        self.contentType = contentType
        self.byteSize = size
        self.preview = preview
        self.isTemporary = isTemporary
    }
}

/// A WebP, JPEG or PNG that fits 1200×800 and 5 MiB.
public struct UploadPreview: Sendable, Hashable {
    /// The picture's bytes.
    public var data: Data
    /// `image/webp`, `image/jpeg` or `image/png`.
    public var contentType: String

    /// A preview of `data`, a picture of type `contentType`.
    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

extension EmberClient {
    /// `POST /api/rooms/:id/uploads`: says what's coming, and answers where its parts go.
    public func startUpload(in roomID: RoomID, _ upload: NewUpload) async throws -> UploadTicket {
        try await send("POST", "\(Self.uploadsPath(roomID))", body: upload, as: UploadTicket.self)
    }

    /// PUTs one part. Answers the posted message when this part completed the upload (201, or 200
    /// for a repeat), nil otherwise (204).
    ///
    /// A part the network failed to deliver, or the server couldn't take just then (408, 429 or a
    /// 5xx), is sent again, `partRetries` times at most, after a wait as a socket waits to
    /// reconnect; one the server refused isn't. The exception is a 409 for part 1: the first part
    /// sent again while the server still had the try before it, whose answer was lost. It's sent
    /// again at once within the same budget, and if the 409 lasts, it fails as `Uploads.failed`
    /// rather than with the server's words.
    public func uploadPart(
        in roomID: RoomID, upload uploadID: String, part: Int, data: Data,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Message? {
        let path = "\(Self.uploadsPath(roomID))/\(Self.segment(uploadID))/parts/\(part)"
        var attempt = 0
        while true {
            do {
                let (body, response) = try await perform(bytes(path, data.count), uploading: data, progress: progress)
                guard response.statusCode != 204, !body.isEmpty else { return nil }
                return try decode(Message.self, from: body, status: response.statusCode)
            } catch let error as EmberError where Self.isPassing(error) && attempt < Self.partRetries {
                try await timing.sleep(for: timing.backoff(attempt: attempt))
                attempt += 1
            } catch let error as EmberError where part == 1 && error.status == 409 {
                // The server answers "The first part is already uploading" only once the other try
                // has recorded its first part, so the next one is taken as the first part again,
                // and needs no wait.
                guard attempt < Self.partRetries else { throw EmberError(status: 409, message: Uploads.failed) }
                attempt += 1
            }
        }
    }

    /// PUTs the picture the timeline shows for the file. It has to come before the last part, since
    /// a posted file takes no more.
    public func uploadPreview(in roomID: RoomID, upload uploadID: String, _ preview: UploadPreview) async throws {
        var request = try bytes("\(Self.uploadsPath(roomID))/\(Self.segment(uploadID))/preview", preview.data.count)
        request.setValue(preview.contentType, forHTTPHeaderField: "Content-Type")
        _ = try await perform(request, uploading: preview.data, progress: { _ in })
    }

    /// The whole of it for one file: start, parts in order, the preview just before the last part
    /// (before part 1 for a one-part file; its failure is ignored), and the message the last part
    /// answers with. `progress` hears the file's bytes sent so far.
    ///
    /// A file over `Limits.fileBytes` throws before anything is sent. Cancelling the task stops the
    /// upload; the server clears what it was sent by itself.
    public func upload(
        _ source: UploadSource, in roomID: RoomID, clientMessageId: String,
        parentId: String? = nil, alsoSend: Bool = false,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Message {
        try await upload(
            source, in: roomID, clientMessageId: clientMessageId, parentId: parentId, alsoSend: alsoSend,
            resuming: nil, checkpoint: { _ in }, progress: progress
        )
    }

    /// `upload(_:in:clientMessageId:parentId:alsoSend:progress:)`, going on from `resuming`, an
    /// earlier try's last `checkpoint`: its ticket, without the parts the server took. The server
    /// can't say which parts it has, so the checkpoint is what does; one it no longer knows (404)
    /// starts again from the start. `checkpoint` hears each part the server takes.
    func upload(
        _ source: UploadSource, in roomID: RoomID, clientMessageId: String,
        parentId: String?, alsoSend: Bool, resuming: UploadCheckpoint?,
        checkpoint: @escaping @Sendable (UploadCheckpoint) async -> Void,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Message {
        guard source.byteSize <= Limits.fileBytes else { throw EmberError(kind: .invalid, status: 413, message: Uploads.tooLarge(source.name)) }
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: source.fileURL)
        } catch {
            throw EmberError.unreadableFile
        }
        defer { try? file.close() }

        var resuming = resuming.flatMap { $0.fits(size: source.byteSize) ? $0 : nil }
        while true {
            let ticket: UploadTicket
            if let resuming {
                ticket = resuming.ticket
            } else {
                ticket = try await startUpload(in: roomID, NewUpload(
                    name: source.name, type: source.contentType, size: source.byteSize,
                    clientMessageId: clientMessageId, parentId: parentId, alsoSend: alsoSend
                ))
                // Checked before any part goes: a ticket that doesn't fit the file would trap reading it,
                // or send parts for a very long time.
                guard ticket.fits(size: source.byteSize) else { throw EmberError.unreadable(status: 201) }
            }
            let done = resuming?.partsDone ?? 0
            var sent = done == 0 ? 0 : ticket.range(ofPart: done, size: source.byteSize).upperBound
            if done > 0 { progress(sent) }
            do {
                for part in done + 1 ... ticket.parts {
                    try Task.checkCancellation()
                    if part == ticket.parts, let preview = source.preview {
                        // A file without its picture is still the file, so a refused preview doesn't stop it.
                        try? await uploadPreview(in: roomID, upload: ticket.id, preview)
                        try Task.checkCancellation()
                    }
                    let data = try Self.read(file, ticket.range(ofPart: part, size: source.byteSize))
                    let before = sent
                    let message = try await uploadPart(in: roomID, upload: ticket.id, part: part, data: data) { progress(before + $0) }
                    sent += data.count
                    // An earlier part can answer the message too, when the upload was finished already.
                    if let message { return message }
                    await checkpoint(UploadCheckpoint(ticket: ticket, partsDone: part))
                }
            } catch let error as EmberError where resuming != nil && error.status == 404 {
                resuming = nil
                continue
            }
            throw EmberError(kind: .undecodable, status: 204, message: Uploads.failed)
        }
    }

    /// How many times a part the network dropped is sent again.
    static let partRetries = 6

    /// Whether a part's failure may pass if it's sent again: no answer, a timeout, too many at once,
    /// or the server's own trouble.
    static func isPassing(_ error: EmberError) -> Bool {
        error.isUnreachable || error.status == 408 || error.status == 429 || (500 ... 599).contains(error.status)
    }

    private static func uploadsPath(_ roomID: RoomID) -> String {
        "/api/rooms/\(segment(roomID))/uploads"
    }

    /// A PUT of `length` raw bytes to `path`.
    private func bytes(_ path: String, _ length: Int) throws -> URLRequest {
        var request = try request("PUT", path)
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        return request
    }

    /// The bytes of `range` from `file`, which must all be there.
    private static func read(_ file: FileHandle, _ range: Range<Int>) throws -> Data {
        guard !range.isEmpty else { return Data() }
        do {
            try file.seek(toOffset: UInt64(range.lowerBound))
            let data = try file.read(upToCount: range.count) ?? Data()
            guard data.count == range.count else { throw CocoaError(.fileReadCorruptFile) }
            return data
        } catch {
            throw EmberError.unreadableFile
        }
    }
}

/// How far an upload got: its ticket, and how many parts from the first the server took.
struct UploadCheckpoint: Hashable, Sendable {
    let ticket: UploadTicket
    let partsDone: Int

    /// Whether an upload of a file of `size` bytes can go on from here: the ticket fits it, and a
    /// part is left to send.
    func fits(size: Int) -> Bool {
        ticket.fits(size: size) && (1 ..< ticket.parts).contains(partsDone)
    }
}

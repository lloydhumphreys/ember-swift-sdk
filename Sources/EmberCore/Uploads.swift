import Foundation

// The wire shapes and rules of packages/protocol/src/files.ts, for sending a file in parts.

/// What `POST /api/rooms/:id/uploads` takes.
public struct NewUpload: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var size: Int
    public var clientMessageId: ClientMessageID
    /// The message in whose thread the file is a reply.
    public var parentId: MessageID?
    /// True for a reply that goes to the room too (a `parentId` and `.threadAndRoom`); left out
    /// otherwise, as the room keeps it only then.
    public var alsoSend: Bool?

    public init(name: String, type: String, size: Int, clientMessageId: ClientMessageID, parentId: MessageID? = nil, delivery: ReplyDelivery = .threadOnly) {
        self.name = name
        self.type = type
        self.size = size
        self.clientMessageId = clientMessageId
        self.parentId = parentId
        self.alsoSend = parentId != nil && delivery == .threadAndRoom ? true : nil
    }
}

/// What starting an upload answers: where the parts go. Every part but the last carries `partSize`
/// bytes, the last the rest, and there's always at least one, even for an empty file.
public struct UploadTicket: Codable, Hashable, Sendable {
    public var id: UploadID
    public var partSize: Int
    public var parts: Int

    public init(id: UploadID, partSize: Int, parts: Int) {
        self.id = id
        self.partSize = partSize
        self.parts = parts
    }

    /// The bytes of the file that part `number` (from 1) carries; empty for a part past the end.
    /// Never traps, whatever the numbers: a ticket the server got wrong has no bytes to give.
    public func range(ofPart number: Int, size: Int) -> Range<Int> {
        let size = max(0, size)
        guard partSize > 0 else { return 0 ..< 0 }
        // `number - 1` alone would overflow for Int.min.
        let (offset, overflowed) = (number > 1 ? number - 1 : 0).multipliedReportingOverflow(by: partSize)
        let start = overflowed ? size : min(offset, size)
        // `size - start` is never negative, so this can't overflow as `start + partSize` could.
        return start ..< start + min(partSize, size - start)
    }

    /// Whether the ticket fits a file of `size` bytes as the server works one out: parts of at
    /// least one byte and at most `Limits.uploadPartBytes`, at least one part and at most
    /// `Limits.uploadParts`, and exactly as many as it takes to carry `size` bytes. Anything else
    /// would trap, read past the file, or send for a very long time.
    public func fits(size: Int) -> Bool {
        guard (0 ... Limits.fileBytes).contains(size),
              (1 ... Limits.uploadPartBytes).contains(partSize),
              (1 ... Limits.uploadParts).contains(parts)
        else { return false }
        // Division, so no multiplying the two can overflow.
        let needed = max(1, size / partSize + (size % partSize == 0 ? 0 : 1))
        return parts == needed
    }
}

/// The rules for files that the app and the session share.
public enum Uploads {
    /// The pictures the server resizes (Active Storage's variable types, less BMP, ICO and PSD).
    private static let variableTypes: Set = ["image/png", "image/gif", "image/jpeg", "image/tiff", "image/webp", "image/avif", "image/heic", "image/heif"]

    /// Whether the server keeps a preview for this type (png, gif, jpeg, tiff, webp, avif, heic,
    /// heif, and anything starting `video`). Parameters and case are set aside, as the server sets
    /// them aside from a declared type.
    public static func hasPreview(contentType: String) -> Bool {
        let type = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let essence = type.trimmingCharacters(in: .whitespaces).lowercased()
        return variableTypes.contains(essence) || essence.hasPrefix("video")
    }

    /// The largest size that fits a preview's bounds without growing the picture, as the web's
    /// `fitted` works it out: rounded, and never below 1.
    public static func previewSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(Limits.previewWidth) / Double(width), Double(Limits.previewHeight) / Double(height))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Why `name` isn't sent: it's over `Limits.fileBytes`. The web's words, a file at a time.
    public static func tooLarge(_ name: String) -> String {
        "\(name) is too large. Choose a file that’s 250 MB or smaller."
    }

    public static let failed = "Upload failed"

    /// Why the server would refuse a file named `name` of type `contentType` (packages/protocol's
    /// `parseNewUpload`), or nil when it takes them: a name that's blank once trimmed, or either
    /// over 255 UTF-16 code units.
    public static func refusal(name: String, contentType: String) -> String? {
        // The server trims with JavaScript's `trim()`, as it trims a boost.
        if Limits.trimmedBoost(name).isEmpty { return "A file needs a name." }
        if name.utf16.count > Limits.fileName { return "That file’s name is too long." }
        if contentType.utf16.count > Limits.fileType { return "That file’s type is too long." }
        return nil
    }
}

extension Limits {
    /// The largest file, in bytes (250 MB, decimal).
    public static let fileBytes = 250_000_000
    /// The largest preview, in bytes (5 MiB).
    public static let previewBytes = 5 * 1024 * 1024
    public static let previewWidth = 1200
    public static let previewHeight = 800
    /// The longest file name the server keeps, in UTF-16 code units.
    public static let fileName = 255
    /// The longest content type the server takes, in UTF-16 code units.
    public static let fileType = 255
    /// The largest part a ticket can ask for: a Worker takes at most 100 MB a request. The server's
    /// own parts are 10 MiB.
    public static let uploadPartBytes = 100_000_000
    /// The most parts a ticket can ask for: every part but the last is at least R2's least, 5 MiB,
    /// so no file of `fileBytes` or less needs more than 48.
    public static let uploadParts = 48
}

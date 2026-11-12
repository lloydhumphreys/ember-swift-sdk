import EmberRichText
import Foundation

/// Text typed in plain, as it's sent: the body escaped into a paragraph with `<br>` between lines,
/// and the plain text with its line endings made `\n` and blank lines at the end dropped.
struct PlainTextMessage {
    let body: String
    let plainText: String

    /// What a message over `Limits.message` is refused with, as the room words it.
    static let tooLong = "Messages can be up to 10,000 characters."
    /// What a message with nothing in it is refused with.
    static let empty = "Write something first."

    /// Throws `.invalid` for text that's blank or over `Limits.message` characters.
    init(_ text: String) throws(EmberError) {
        var lines = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        let plainText = lines.joined(separator: "\n")
        guard !plainText.allSatisfy(\.isWhitespace) else { throw EmberError(kind: .invalid, message: Self.empty) }
        guard plainText.utf16.count <= Limits.message else { throw EmberError(kind: .invalid, message: Self.tooLong) }
        self.plainText = plainText
        body = RichText.body(fromPlainText: plainText)
    }

    /// Nil for nil or blank text; otherwise as `init`.
    static func caption(_ text: String?) throws(EmberError) -> PlainTextMessage? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return try PlainTextMessage(text)
    }
}

extension RoomSession {
    /// Sends text typed in plain: escaped, so `<b>` shows as typed, with each line on its own.
    /// Throws `.invalid`, sending nothing, for text that's blank or over `Limits.message`
    /// characters. Answers its client message id, as `send(body:plainText:)` does.
    @discardableResult
    public func send(text: String) throws(EmberError) -> String {
        let message = try PlainTextMessage(text)
        return send(body: message.body, plainText: message.plainText)
    }

    /// Posts `files` with a caption typed in plain, as `send(files:body:plainText:)` does. Throws
    /// `.invalid`, sending nothing, for a caption over `Limits.message` characters; a blank one
    /// sends the files alone.
    @discardableResult
    public func send(files: [UploadSource], text: String?) throws(EmberError) -> [String] {
        let caption = try PlainTextMessage.caption(text)
        return send(files: files, body: caption?.body, plainText: caption?.plainText)
    }
}

extension ThreadSession {
    /// Replies with text typed in plain, as `RoomSession.send(text:)` escapes it, and with
    /// `alsoSend` in the room too. Throws `.invalid`, sending nothing, for text that's blank or
    /// over `Limits.message` characters.
    @discardableResult
    public func reply(text: String, alsoSend: Bool = false) throws(EmberError) -> String {
        let message = try PlainTextMessage(text)
        return reply(body: message.body, plainText: message.plainText, alsoSend: alsoSend)
    }

    /// Posts `files` into the thread with a caption typed in plain, as
    /// `RoomSession.send(files:text:)` does.
    @discardableResult
    public func send(files: [UploadSource], text: String?, alsoSend: Bool = false) throws(EmberError) -> [String] {
        let caption = try PlainTextMessage.caption(text)
        return send(files: files, body: caption?.body, plainText: caption?.plainText, alsoSend: alsoSend)
    }
}

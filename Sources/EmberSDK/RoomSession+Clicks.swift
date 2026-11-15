import Foundation

extension RoomSession {
    /// What `click(_:on:)` throws when the room lets the socket in again before answering: the
    /// click may have reached the bot, but its answer is lost.
    public static let clickLost = "The room reconnected before answering the click. It may have gone through."

    /// Clicks a button that acts, on the card under `messageID`, returning once the room says the
    /// bot that posted it took the click. There's no time limit: the room answers once the bot has.
    /// Throws the room's refusal (`kind` `.refused`), such as "That button is no longer there";
    /// `.invalid`, before sending, for an action the room wouldn't take (`CardAction.isValid`);
    /// `.unreachable` with `notConnected` when the room hasn't let the socket in, and when the socket
    /// drops before the answer; and `.unreachable` with `clickLost` when the room lets the socket
    /// in again before answering. Nothing is kept to send later.
    public func click(_ action: CardAction, on messageID: MessageID) async throws {
        guard action.isValid, !messageID.rawValue.isEmpty, messageID.rawValue.utf16.count <= Self.maxClickIDLength else {
            throw EmberError(kind: .invalid, message: "That button can’t be clicked.")
        }
        let clickID = ClickID(UUID().uuidString.lowercased())
        let frame = ClientFrame.clickCard(clickId: clickID, messageId: messageID, actionId: action.id, blockId: action.blockId, value: action.value)
        guard isAdmitted, transmit(sending: frame) else {
            throw EmberError(kind: .unreachable, message: Self.notConnected)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            clicks[clickID] = continuation
        }
    }

    /// The longest message id the room takes in a click.
    static let maxClickIDLength = 64

    /// Finishes the click a `card.clicked` or an error frame names. Answers whether the frame was
    /// about a click, which a refusal's notice and the `async` changes leave alone.
    func clickAnswered(_ frame: ServerFrame) -> Bool {
        switch frame {
        case let .cardClicked(clickID):
            clicks.removeValue(forKey: clickID)?.resume()
            return true
        case let .error(message, _, _, clickID?, _):
            clicks.removeValue(forKey: clickID)?.resume(throwing: EmberError(kind: .refused, message: message))
            return true
        default:
            return false
        }
    }

    /// Fails every click waiting for an answer, which won't come on this connection.
    func clicksLost(_ message: String) {
        let waiting = clicks
        clicks = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: EmberError(kind: .unreachable, message: message))
        }
    }
}

extension ThreadSession {
    /// Clicks a button that acts, on the card of the parent or a reply, `messageID`. The thread is
    /// on the room's socket, so this is `room.click(_:on:)`, and throws as that does.
    public func click(_ action: CardAction, on messageID: MessageID) async throws {
        try await room.click(action, on: messageID)
    }
}

import Foundation

extension EmberClient {
    /// One message of a room, fetched once.
    ///
    /// The server has no route that answers a single message to a signed-in session, so this uses the
    /// nearest real one: a room socket opened with `around=<id>`, whose welcome carries the page around
    /// that message. It reads the welcome, finds the message in it and closes the socket, so nothing is
    /// left running and nothing is cached. The socket is not visible (`visible=0`), so it doesn't mark
    /// the room read.
    ///
    /// Only a message in the room's own timeline is found: a reply that wasn't also sent to the room is
    /// in its thread's page, not the room's. A message the room doesn't have, or has deleted, fails with
    /// status 404. A refused socket fails with the status the server refused it with, and a 401 is
    /// thrown as it is without calling `addSignedOutHandler`'s handlers.
    public func message(_ id: MessageID, in roomID: RoomID) async throws -> Message {
        let connection = connector.connect(roomSocketRequest(roomID: roomID, visible: false, since: nil, around: id))
        defer { connection.close() }
        let page: TimelinePage
        do {
            page = try await withThrowingTaskGroup(of: TimelinePage.self) { group in
                group.addTask { try await Self.welcomePage(of: connection) }
                group.addTask {
                    try await self.timing.sleep(for: self.timing.connectTimeout)
                    throw EmberError.unreachable(self.origin)
                }
                defer {
                    connection.close()
                    group.cancelAll()
                }
                return try await group.next()!
            }
        } catch let error as SocketClosed {
            throw error.httpStatus.map { EmberError(status: $0, message: HTTPURLResponse.localizedString(forStatusCode: $0).capitalized) }
                ?? EmberError.unreachable(origin)
        }
        guard let message = page.messages.first(where: { $0.id == id && !$0.isDeleted }) else {
            throw EmberError(status: 404, message: "That message isn’t in this room.")
        }
        return message
    }

    /// The first welcome the room sends, its page, skipping any frame before it.
    private static func welcomePage(of connection: any SocketConnection) async throws -> TimelinePage {
        try await connection.waitUntilOpen()
        while true {
            switch ServerFrame(text: try await connection.receive()) {
            case .welcome(_, _, _, let page): return page
            case .error(let message, _, _, _): throw EmberError(status: 422, message: message)
            default: continue
            }
        }
    }
}

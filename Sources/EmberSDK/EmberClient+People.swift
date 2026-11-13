import Foundation

extension EmberClient {
    /// `GET /api/users/:id`: someone, whatever their status. Administrators are also told their
    /// email address and given a new sign-in link for them. 404 for an id nobody has.
    public func person(_ userID: UserID) async throws -> PersonDetails {
        try await get("/api/users/\(Self.segment(userID))")
    }

    /// `POST /api/users/:id/ban`: bans someone, as an administrator, answering them as the directory
    /// now lists them (`status` is `.banned`).
    ///
    /// A ban blocks the IP addresses they've signed in from, ends their sessions, and deletes their
    /// messages in every room. Lifting it doesn't bring the messages back. Fails 403 for anyone but
    /// an administrator and for banning yourself, and 422 when one of their addresses can't be
    /// blocked, such as yours.
    public func ban(_ userID: UserID) async throws -> DirectoryUser {
        let (data, response) = try await perform(try request("POST", "/api/users/\(Self.segment(userID))/ban"))
        return try decode(ChangedPerson.self, from: data, status: response.statusCode).user
    }

    /// `DELETE /api/users/:id/ban`: lifts someone's ban, as an administrator, making them active
    /// again. Their deleted messages stay deleted.
    public func unban(_ userID: UserID) async throws -> DirectoryUser {
        let (data, response) = try await perform(try request("DELETE", "/api/users/\(Self.segment(userID))/ban"))
        return try decode(ChangedPerson.self, from: data, status: response.statusCode).user
    }
}

/// What changing someone answers: them, as the directory now lists them.
private struct ChangedPerson: Decodable {
    var user: DirectoryUser
}

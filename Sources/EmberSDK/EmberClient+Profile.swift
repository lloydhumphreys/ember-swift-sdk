import Foundation

extension EmberClient {
    /// The most bytes an avatar can be, as Ember takes them.
    public static let avatarByteLimit = 16_000_000

    /// `GET /api/users/me/profile`: your profile, and a new sign-in link for you.
    public func profile() async throws -> ProfileAnswer {
        try await get("/api/users/me/profile")
    }

    /// `PATCH /api/users/me/profile`: changes what `changes` sets, answering your profile then.
    ///
    /// Changing your email address or password needs `currentPassword` when you have one: without
    /// it, or with a wrong one, it fails 422. Too many wrong ones fail 429.
    public func changeProfile(_ changes: ProfileChanges) async throws -> ProfileAnswer {
        struct Body: Encodable {
            var name: String?
            var emailAddress: String?
            var bio: String?
            var password: String?
            var currentPassword: String?
        }
        let body = Body(name: changes.name, emailAddress: changes.emailAddress, bio: changes.bio, password: changes.password, currentPassword: changes.currentPassword)
        return try await send("PATCH", "/api/users/me/profile", body: body)
    }

    /// `PUT /api/users/me/avatar`: makes the picture in `data` your avatar, answering your profile then.
    ///
    /// Ember serves `variant` in its place: a WebP, PNG or JPEG within 512×512. Without one, it's made
    /// here with ImageIO, and a picture ImageIO can't read goes without, which Ember shows as your
    /// initials. A picture over `avatarByteLimit` fails `.invalid`, sending nothing.
    public func changeAvatar(_ data: Data, filename: String = "avatar", contentType: String, variant: AvatarVariant? = nil) async throws -> ProfileAnswer {
        guard data.count <= Self.avatarByteLimit else {
            throw EmberError(kind: .invalid, status: 413, message: "Photos must be 16 MB or smaller.")
        }
        var parts: [MultipartForm.Part] = [.file("avatar", filename: filename, contentType: contentType, data: data)]
        if let variant = variant ?? AvatarVariant(of: data) {
            let name = variant.contentType == "image/png" ? "variant.png" : variant.contentType == "image/webp" ? "variant.webp" : "variant.jpg"
            parts.append(.file("variant", filename: name, contentType: variant.contentType, data: variant.data))
        }
        let form = MultipartForm(parts)
        var request = try request("PUT", "/api/users/me/avatar")
        form.describe(&request)
        let (answer, response) = try await perform(request, uploading: form.body, progress: { _ in })
        return try decode(ProfileAnswer.self, from: answer, status: response.statusCode)
    }

    /// `DELETE /api/users/me/avatar`: takes your avatar away, answering your profile then.
    public func removeAvatar() async throws -> ProfileAnswer {
        let (data, response) = try await perform(try request("DELETE", "/api/users/me/avatar"))
        return try decode(ProfileAnswer.self, from: data, status: response.statusCode)
    }
}

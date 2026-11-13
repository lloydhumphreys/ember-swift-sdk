import Foundation

/// A `multipart/form-data` body, as a browser's `FormData` sends one: each part a file or a field.
struct MultipartForm: Sendable {
    /// One part of the form.
    struct Part: Sendable {
        var name: String
        /// The file's name, or nil for a plain field.
        var filename: String?
        /// The file's type, or nil for a plain field.
        var contentType: String?
        var data: Data

        /// A file part.
        static func file(_ name: String, filename: String, contentType: String, data: Data) -> Part {
            Part(name: name, filename: filename, contentType: contentType, data: data)
        }

        /// A plain text field.
        static func field(_ name: String, _ value: String) -> Part {
            Part(name: name, filename: nil, contentType: nil, data: Data(value.utf8))
        }
    }

    /// The `Content-Type` to send, with its boundary.
    let contentType: String
    /// The whole body.
    let body: Data

    init(_ parts: [Part], boundary: String = "ember-\(UUID().uuidString)") {
        contentType = "multipart/form-data; boundary=\(boundary)"
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\""
            if let filename = part.filename { disposition += "; filename=\"\(Self.quoted(filename))\"" }
            body.append(Data("\(disposition)\r\n".utf8))
            if let type = part.contentType {
                body.append(Data("Content-Type: \(type.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        self.body = body
    }

    /// Sets `request`'s `Content-Type` and `Content-Length` for this form. Ember refuses a picture
    /// without its length (411).
    func describe(_ request: inout URLRequest) {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }

    /// `text` escaped for a quoted header value, as browsers escape a file's name.
    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

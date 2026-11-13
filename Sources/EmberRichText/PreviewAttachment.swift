import Foundation

// A port of `previewContent` in packages/richtext/src/previews.ts.

extension RichText {
    /// A link's preview as the web composer writes it into a body: an attachment whose content is the
    /// preview's markup, its title and description shortened and stripped as the server stores them.
    package static func previewAttachment(title: String, url: String, description: String, image: String?) -> String {
        let twitter = image?.hasPrefix("https://pbs.twimg.com/profile_images") == true ? " og-embed--twitter-avatar" : ""
        let name = htmlEscape(PreviewReader.strip(PreviewReader.truncate(title, 280)))
        let linked = #"<a href="\#(htmlEscape(url))" rel="noreferrer" target="_blank">\#(name)</a>"#
        let picture = image.map { #"<div class="og-embed__image"><img src="\#(htmlEscape($0))" class="image center" alt=""></div>"# } ?? ""
        let content = #"<actiontext-opengraph-embed><div class="og-embed gap\#(twitter)"><div class="og-embed__content">"#
            + #"<div class="og-embed__title">\#(linked)</div>"#
            + #"<div class="og-embed__description">\#(htmlEscape(PreviewReader.strip(PreviewReader.truncate(description, 560))))</div></div>"#
            + #"\#(picture)</div></actiontext-opengraph-embed>"#
        // The attribute escaped as the server's serializer writes it, so storing it changes nothing.
        return #"<\#(PreviewReader.attachmentTag) content-type="\#(PreviewReader.embedContentType)" content="\#(attributeEscape(content))"></\#(PreviewReader.attachmentTag)>"#
    }

    /// `ERB::Util.html_escape`.
    static func htmlEscape(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// An attribute's value as the server's serializer escapes it, brackets included: `'` stays as it is.
    private static func attributeEscape(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "\u{A0}": escaped += "&nbsp;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

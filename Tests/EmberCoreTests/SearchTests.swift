import Foundation
import Testing
@testable import EmberCore

@Suite struct SearchTests {
    @Test(arguments: [
        ("hello  world", "q=hello++world"),
        ("café_1 日本", "q=caf%C3%A9_1+%E6%97%A5%E6%9C%AC"),
        ("C++ & co", "q=C%2B%2B+%26+co"),
        ("", "q="),
    ])
    func wordsAreFormEncoded(_ q: String, _ expected: String) {
        #expect(SearchQuery(q: q).queryString() == expected)
    }

    @Test func filtersFollowInTheirOrder() {
        let query = SearchQuery(q: "eel", roomID: "room1", from: "ada", withMe: true, hasLink: true, hasFile: true, inThread: true)
        #expect(query.queryString() == "q=eel&in=room1&from=ada&with=me&has=link&has=file&is=thread")
    }

    @Test func sortOnlyWhenOldestAndCursorLast() {
        #expect(SearchQuery(q: "eel", hasFile: true).queryString(sort: .oldest) == "q=eel&has=file&sort=oldest")
        #expect(SearchQuery(q: "eel").queryString(sort: .newest, cursor: 42) == "q=eel&cursor=42")
        #expect(SearchQuery(q: "eel").queryString(sort: .oldest, cursor: 42) == "q=eel&sort=oldest&cursor=42")
    }

    @Test(arguments: ["", "   ", "!!!", "😀 ❤", "\0"])
    func nothingToFind(_ q: String) {
        #expect(!SearchQuery(q: q).isSearchable)
    }

    @Test(arguments: ["eels", "日本", "42", "_", "e\u{301}"])
    func wordsToFind(_ q: String) {
        #expect(SearchQuery(q: q).isSearchable)
    }

    @Test func anyFilterIsEnough() {
        #expect(SearchQuery(q: "!!!", roomID: "r1").isSearchable)
        #expect(SearchQuery(q: "!!!", from: "u1").isSearchable)
        #expect(SearchQuery(q: "!!!", withMe: true).isSearchable)
        #expect(SearchQuery(q: "!!!", hasLink: true).isSearchable)
        #expect(SearchQuery(q: "!!!", hasFile: true).isSearchable)
        #expect(SearchQuery(q: "!!!", inThread: true).isSearchable)
    }

    @Test func bodyHasFlagsOnlyWhenSetAndSortOnlyWhenOldest() throws {
        let encoder = EmberJSON.encoder()
        let plain = try encoder.encode(SearchQuery(q: "eel").body())
        #expect(json(String(decoding: plain, as: UTF8.self)) == json(#"{"q":"eel"}"#))
        let full = try encoder.encode(SearchQuery(q: "eel", roomID: "r1", from: "u1", withMe: true, hasLink: true, hasFile: true, inThread: true).body(sort: .oldest))
        #expect(json(String(decoding: full, as: UTF8.self))
            == json(#"{"q":"eel","in":"r1","from":"u1","withMe":true,"hasLink":true,"hasFile":true,"inThread":true,"sort":"oldest"}"#))
    }

    @Test func decodesResults() throws {
        let text = #"""
        {"search":{"q":"hi","in":"r1","hasLink":true},
         "matches":[{"message":\#(messageJSON),"words":["hi"]}],
         "next":100,
         "rooms":[{"id":"r1","kind":"open","name":"general","icon":null}],
         "recent":[{"q":"hi"},{"q":"","from":"u2"}]}
        """#
        let results = try EmberJSON.decoder().decode(SearchResults.self, from: Data(text.utf8))
        #expect(results.search == SearchQuery(q: "hi", roomID: "r1", hasLink: true))
        #expect(results.matches.map(\.id) == ["m001"])
        #expect(results.matches.first?.words == ["hi"])
        #expect(results.next == 100)
        #expect(results.rooms.map(\.id) == ["r1"])
        #expect(results.recent == [SearchQuery(q: "hi"), SearchQuery(q: "", from: "u2")])
    }

    @Test func decodesNoSearch() throws {
        let results = try EmberJSON.decoder().decode(SearchResults.self, from: Data(#"{"search":null,"matches":[],"next":null,"rooms":[],"recent":[]}"#.utf8))
        #expect(results.search == nil && results.matches.isEmpty && results.next == nil)
    }

    @Test func limits() {
        #expect(Limits.search == 1000 && Limits.searchPage == 100 && Limits.recentSearches == 10)
    }
}

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("ember.example.com", "https://ember.example.com"),
        ("  Ember.Example.COM/rooms/1?x=1#y  ", "https://ember.example.com"),
        ("https://ember.example.com/", "https://ember.example.com"),
        ("http://ember.example.com", "http://ember.example.com"),
        ("ember.example.com:8443", "https://ember.example.com:8443"),
        ("localhost:8787", "http://localhost:8787"),
        ("localhost", "http://localhost"),
        ("ember.localhost:8787/x", "http://ember.localhost:8787"),
        ("127.0.0.1:8787", "http://127.0.0.1:8787"),
        ("[::1]:8787", "http://[::1]:8787"),
        ("https://localhost:8787", "https://localhost:8787"),
        ("HTTPS://Ember.Example.com", "https://ember.example.com"),
    ])
    func origins(_ typed: String, _ expected: String) {
        #expect(ServerAddress.origin(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "https://", "ftp://ember.example.com", "javascript:alert(1)", "http://:8787"])
    func noOrigin(_ typed: String) {
        #expect(ServerAddress.origin(from: typed) == nil)
    }

    @Test func display() throws {
        #expect(ServerAddress.display(try #require(URL(string: "https://ember.example.com"))) == "ember.example.com")
        #expect(ServerAddress.display(try #require(URL(string: "http://localhost:8787"))) == "localhost:8787")
        #expect(ServerAddress.display(try #require(URL(string: "http://[::1]:8787"))) == "[::1]:8787")
    }
}

@Suite struct AvatarStyleTests {
    @Test func crc32IsZlibs() {
        #expect(AvatarStyle.crc32("1") == 0x83DC_EFB7)
        #expect(AvatarStyle.crc32("é") == 0x0E04_8D3E)
        #expect(AvatarStyle.crc32("€") == 0x83F2_C8D6)
        #expect(AvatarStyle.crc32("😀") == 0x054D_B544)
        #expect(AvatarStyle.crc32("") == 0)
    }

    @Test(arguments: [
        ("1", "#BF7C2A"), ("2", "#698F9C"), ("42", "#D07B53"), ("1000", "#BFA07A"),
        ("127326141", "#736356"), ("773523956", "#5D618F"),
    ])
    func colours(_ id: String, _ hex: String) {
        #expect(AvatarStyle.hex(for: id) == hex)
    }

    @Test func colourComponents() {
        let colour = AvatarStyle.colour(for: "1")
        #expect(colour.red == Double(0xBF) / 255 && colour.green == Double(0x7C) / 255 && colour.blue == Double(0x2A) / 255)
        #expect(AvatarStyle.colours.count == 18)
    }

    @Test(arguments: [
        ("David Heinemeier Hansson", "DHH"),
        ("Élodie Ünal-Smith o'Brien 3po _x ñ", "SoB3_"),
        ("grace", "g"),
        ("Élodie", ""),
        ("Ada Byron King Lovelace Countess", "ABKLC"),
        ("", ""),
        ("日本 Tokyo", "T"),
    ])
    func initials(_ name: String, _ expected: String) {
        #expect(AvatarStyle.initials(of: name) == expected)
    }
}

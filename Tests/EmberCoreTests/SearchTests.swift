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
        #expect(SearchQuery(q).queryString() == expected)
    }

    @Test func filtersFollowInTheirOrder() {
        let query = SearchQuery("eel").inRoom("room1").from("ada").involvingMe().havingLinks().havingFiles().inThreads()
        #expect(query.queryString() == "q=eel&in=room1&from=ada&with=me&has=link&has=file&is=thread")
    }

    @Test func eachModifierSetsItsFilterAndLeavesTheRest() {
        let base = SearchQuery("eel")
        #expect(base.q == "eel" && base.roomID == nil && base.from == nil && !base.withMe && !base.hasLink && !base.hasFile && !base.inThread)
        #expect(SearchQuery().q == "")
        #expect(base.inRoom("r1").roomID == "r1")
        #expect(base.from("u1").from == "u1")
        #expect(base.involvingMe().withMe)
        #expect(base.havingLinks().hasLink)
        #expect(base.havingFiles().hasFile)
        #expect(base.inThreads().inThread)
        #expect(base.inRoom("r1").queryString() == "q=eel&in=r1")
        #expect(base.from("u1").queryString() == "q=eel&from=u1")
        #expect(base.involvingMe().queryString() == "q=eel&with=me")
        #expect(base.havingLinks().queryString() == "q=eel&has=link")
        #expect(base.havingFiles().queryString() == "q=eel&has=file")
        #expect(base.inThreads().queryString() == "q=eel&is=thread")
        // Each gives a copy: the query it was called on is unchanged.
        #expect(base == SearchQuery("eel"))
        // A later call replaces an earlier one's value.
        #expect(base.inRoom("r1").inRoom("r2").roomID == "r2")
    }

    @Test func chainingMakesTheSameRequestAsSettingTheProperties() throws {
        var set = SearchQuery()
        set.q = "eel"
        set.roomID = "r1"
        set.from = "u1"
        set.withMe = true
        set.hasLink = true
        set.hasFile = true
        set.inThread = true
        let chained = SearchQuery("eel").inRoom("r1").from("u1").involvingMe().havingLinks().havingFiles().inThreads()
        #expect(chained == set)
        #expect(chained.queryString(sort: .oldest, cursor: 9) == set.queryString(sort: .oldest, cursor: 9))
        #expect(chained.body(sort: .oldest) == set.body(sort: .oldest))
        let encoder = EmberJSON.encoder()
        let chainedBody = String(decoding: try encoder.encode(chained.body(sort: .oldest)), as: UTF8.self)
        let setBody = String(decoding: try encoder.encode(set.body(sort: .oldest)), as: UTF8.self)
        #expect(json(chainedBody) != nil && json(chainedBody) == json(setBody))
    }

    @Test func sortOnlyWhenOldestAndCursorLast() {
        #expect(SearchQuery("eel").havingFiles().queryString(sort: .oldest) == "q=eel&has=file&sort=oldest")
        #expect(SearchQuery("eel").queryString(sort: .newest, cursor: 42) == "q=eel&cursor=42")
        #expect(SearchQuery("eel").queryString(sort: .oldest, cursor: 42) == "q=eel&sort=oldest&cursor=42")
    }

    @Test(arguments: ["", "   ", "!!!", "😀 ❤", "\0"])
    func nothingToFind(_ q: String) {
        #expect(!SearchQuery(q).isSearchable)
    }

    @Test(arguments: ["eels", "日本", "42", "_", "e\u{301}"])
    func wordsToFind(_ q: String) {
        #expect(SearchQuery(q).isSearchable)
    }

    @Test func anyFilterIsEnough() {
        #expect(SearchQuery("!!!").inRoom("r1").isSearchable)
        #expect(SearchQuery("!!!").from("u1").isSearchable)
        #expect(SearchQuery("!!!").involvingMe().isSearchable)
        #expect(SearchQuery("!!!").havingLinks().isSearchable)
        #expect(SearchQuery("!!!").havingFiles().isSearchable)
        #expect(SearchQuery("!!!").inThreads().isSearchable)
    }

    @Test func bodyHasFlagsOnlyWhenSetAndSortOnlyWhenOldest() throws {
        let encoder = EmberJSON.encoder()
        let plain = try encoder.encode(SearchQuery("eel").body())
        #expect(json(String(decoding: plain, as: UTF8.self)) == json(#"{"q":"eel"}"#))
        let full = try encoder.encode(SearchQuery("eel").inRoom("r1").from("u1").involvingMe().havingLinks().havingFiles().inThreads().body(sort: .oldest))
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
        #expect(results.search == SearchQuery("hi").inRoom("r1").havingLinks())
        #expect(results.matches.map(\.id) == ["m001"])
        #expect(results.matches.first?.words == ["hi"])
        #expect(results.next == 100)
        #expect(results.rooms.map(\.id) == ["r1"])
        #expect(results.recent == [SearchQuery("hi"), SearchQuery().from("u2")])
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
        #expect(AvatarStyle.hex(for: UserID(id)) == hex)
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

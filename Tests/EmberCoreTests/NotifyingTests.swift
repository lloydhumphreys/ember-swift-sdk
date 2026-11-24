import Foundation
import Testing
@testable import EmberCore

// Who a message notifies: @here, @channel and @everyone, the rooms and workspaces that hold them
// back, and the people who've paused their notifications.

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try EmberJSON.decoder().decode(type, from: Data(json.utf8))
}

@Suite struct SpecialMentionTests {
    @Test func theKnownOnesAreNarrowestFirstAndAnotherIsKept() throws {
        #expect(SpecialMention.known == [.here, .channel, .everyone])
        #expect(SpecialMention.known.map(\.rawValue) == ["here", "channel", "everyone"])
        #expect(try decoded([SpecialMention].self, #"["here","channel","everyone","team"]"#) == [.here, .channel, .everyone, .unknown("team")])
        #expect(SpecialMention("everyone") == .everyone)
    }

    @Test func aMessageSaysWhatItNotifiedTheRoomWith() throws {
        let said = try decoded(Message.self, #"""
        {"id":"m1","clientMessageId":"c1","roomId":"r1","creator":{"id":"u1","name":"Ada"},"body":"","plainText":"@channel lunch","notifies":"channel",
         "createdAt":"2026-10-12T12:00:00.000Z","updatedAt":"2026-10-12T12:00:00.000Z"}
        """#)
        #expect(said.notifies == .channel)
        #expect(message("m001").notifies == nil)
        var louder = message("m001")
        louder.notifies = .everyone
        let again = try EmberJSON.decoder().decode(Message.self, from: EmberJSON.encoder().encode(louder))
        #expect(again.notifies == .everyone && again == louder)
        // One this version doesn't know is kept, and one that isn't a name is left out.
        let newer = #"{"id":"m1","clientMessageId":"c1","roomId":"r1","creator":{"id":"u1","name":"Ada"},"body":"","plainText":"","notifies":"team","createdAt":"2026-10-12T12:00:00.000Z","updatedAt":"2026-10-12T12:00:00.000Z"}"#
        #expect(try decoded(Message.self, newer).notifies == .unknown("team"))
        #expect(try decoded(Message.self, newer.replacingOccurrences(of: #""team""#, with: "7")).notifies == nil)
    }

    @Test func aRoomAllowsThemUnlessItsSettingsSayNot() throws {
        #expect(Room(id: "r1", kind: .open, name: "general").allowsChannelMentions)
        #expect(Room(id: "r1", kind: .closed, name: "Engines", channelMentions: true).allowsChannelMentions)
        #expect(!Room(id: "r1", kind: .open, name: "general", channelMentions: false).allowsChannelMentions)
        // They notify nobody in a DM.
        #expect(!Room(id: "d1", kind: .direct).allowsChannelMentions)
        let quiet = try decoded(Room.self, #"{"id":"r1","kind":"open","name":"general","channelMentions":false}"#)
        #expect(quiet.channelMentions == false && !quiet.allowsChannelMentions)
        #expect(try decoded(Room.self, #"{"id":"r1","kind":"open","name":"general"}"#).channelMentions == nil)
    }

    @Test func theWorkspaceSaysWhoMayUseThemAndWhetherToAskFirst() throws {
        let account = try decoded(Account.self, #"{"name":"Acme","restrictChannelMentions":true,"restrictEveryoneMention":true,"warnBeforeNotifying":false}"#)
        #expect(account.restrictChannelMentions && account.restrictEveryoneMention && !account.warnBeforeNotifying)
        // A server from before them restricts nobody, and asks, as one that says nothing does.
        let older = try decoded(Account.self, #"{"name":"Acme"}"#)
        #expect(!older.restrictChannelMentions && !older.restrictEveryoneMention && older.warnBeforeNotifying)
        #expect(Account(name: "Acme").warnBeforeNotifying)
        #expect(older == Account(name: "Acme"))
    }
}

@Suite struct NotifiedCountsTests {
    private let busy = NotifiedCounts(members: 8, mentions: [.here: 3, .channel: 7, .everyone: 12])

    @Test func readsTheRoomsCounts() throws {
        #expect(try decoded(NotifiedCounts.self, #"{"members":8,"mentions":{"here":3,"channel":7,"everyone":12}}"#) == busy)
        // In a DM, or where they're turned off, none is listed.
        #expect(try decoded(NotifiedCounts.self, #"{"members":2,"mentions":{}}"#) == NotifiedCounts(members: 2))
        #expect(try decoded(NotifiedCounts.self, #"{"mentions":{"here":"three"}}"#) == NotifiedCounts(members: 0))
        #expect(try decoded(NotifiedCounts.self, #"{"members":8,"mentions":{"team":4}}"#) == NotifiedCounts(members: 8, mentions: [.unknown("team"): 4]))
    }

    @Test func asksForTheWidestMentionMade() {
        #expect(busy.notifying([.here]) == Notifying(mention: .here, people: 3))
        #expect(busy.notifying([.here, .channel]) == Notifying(mention: .channel, people: 7))
        #expect(busy.notifying([.everyone, .here]) == Notifying(mention: .everyone, people: 12))
        #expect(busy.notifying([]) == nil)
        #expect(busy.notifying([.unknown("team")]) == nil)
    }

    @Test func aSmallRoomIsNotAskedAbout() {
        #expect(Limits.warnedRoom == 6)
        #expect(NotifiedCounts(members: 5, mentions: [.channel: 4]).notifying([.channel]) == nil)
        #expect(NotifiedCounts(members: 6, mentions: [.channel: 5]).notifying([.channel]) == Notifying(mention: .channel, people: 5))
    }

    @Test func aMentionThatNotifiesNobodyIsNotAskedAbout() {
        // Only administrators may use @everyone here, so it's the @channel beside it that notifies.
        let restricted = NotifiedCounts(members: 8, mentions: [.here: 3, .channel: 7])
        #expect(restricted.notifying([.everyone]) == nil)
        #expect(restricted.notifying([.everyone, .channel]) == Notifying(mention: .channel, people: 7))
        // Nobody else is active now.
        #expect(NotifiedCounts(members: 8, mentions: [.here: 0, .channel: 7]).notifying([.here]) == nil)
        #expect(NotifiedCounts(members: 8).notifying([.channel, .here, .everyone]) == nil)
    }
}

@Suite struct PauseTests {
    @Test func aPauseLastsUntilItsTime() throws {
        let paused = try decoded(DirectoryUser.self, #"{"id":"u2","name":"Grace","role":"member","status":"active","avatarUrl":"/a","pausedUntil":"2026-10-12T12:30:00.000Z"}"#)
        #expect(paused.pausedUntil == noon(30))
        #expect(paused.pause(at: noon()) == noon(30))
        #expect(paused.pause(at: noon(29)) == noon(30))
        // One that has ended since the directory listed it counts as none.
        #expect(paused.pause(at: noon(30)) == nil)
        #expect(paused.pause(at: noon(45)) == nil)
    }

    @Test func nobodyIsPausedUntilTheySay() throws {
        let grace = try decoded(DirectoryUser.self, #"{"id":"u2","name":"Grace","role":"member","status":"active","avatarUrl":"/a"}"#)
        #expect(grace.pausedUntil == nil && grace.pause(at: noon()) == nil)
        #expect(DirectoryUser(id: "u2", name: "Grace", avatarUrl: "/a").pause() == nil)
        #expect(Limits.longestPause == 7 * 86_400)
    }

    @Test func aPauseSurvivesBeingWrittenAndReadBack() throws {
        let paused = DirectoryUser(id: "u2", name: "Grace", avatarUrl: "/a", pausedUntil: noon(30))
        let again = try EmberJSON.decoder().decode(DirectoryUser.self, from: EmberJSON.encoder().encode(paused))
        #expect(again == paused)
        #expect(WorkspaceFrame(text: #"{"type":"user.updated","user":{"id":"u2","name":"Grace","role":"member","status":"active","avatarUrl":"/a","pausedUntil":"2026-10-12T12:30:00.000Z"}}"#)
            == .userUpdated(paused))
    }
}

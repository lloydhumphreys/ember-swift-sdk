import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// `SearchSession`: the state a search screen holds, and answers that arrive out of order.
@MainActor @Suite struct SearchSessionTests {
    let transport = MockHTTPTransport()
    let session: SearchSession

    init() {
        session = SearchSession(client: EmberClient.mock(transport: transport))
    }

    private func answer(_ query: SearchQuery, matches: [Message], next: Int? = nil, recent: [SearchQuery] = []) -> String {
        Fixtures.searchJSON(search: query, matches: matches, next: next, rooms: [Fixtures.general], recent: recent)
    }

    @Test func aNewSessionIsIdle() {
        #expect(session.phase == .idle)
        #expect(session.matches.isEmpty)
        #expect(session.canLoadMore == false)
    }

    @Test func runningASearchLoadsItsMatchesAndRecordsItWhenTyped() async {
        let query = SearchQuery(q: "engine")
        transport.stub("POST", "/api/searches", status: 201, json: answer(query, matches: Fixtures.messages(2), next: 2, recent: [query]))
        session.query = SearchQuery(q: "  engine ")
        session.run(record: true)
        #expect(session.phase == .searching)
        #expect(await eventually { session.phase == .loaded })
        #expect(session.matches.map(\.id) == ["m001", "m002"])
        #expect(session.rooms[Fixtures.general.id] == Fixtures.general)
        #expect(session.next == 2)
        #expect(session.recent == [query])
        let body = transport.lastBody("POST", "/api/searches")
        #expect((body?["search"] as? [String: Any])?["q"] as? String == "engine" || body?["q"] as? String == "engine")
    }

    @Test func runningWithoutRecordingReadsTheResults() async {
        let query = SearchQuery(q: "engine")
        transport.stub("GET", "/api/searches?q=engine", json: answer(query, matches: Fixtures.messages(1)))
        session.query = query
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
        #expect(transport.requests("POST", "/api/searches").isEmpty)
    }

    @Test func theSortIsSentWithTheSearch() async {
        transport.stub("GET", "/api/searches?q=engine&sort=oldest", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1)))
        session.query = SearchQuery(q: "engine")
        session.sort = .oldest
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
    }

    @Test func aQueryWithNothingToSearchForResetsInsteadOfSearching() async {
        transport.stub("GET", "/api/searches?q=engine", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1)))
        session.query = SearchQuery(q: "engine")
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
        session.query = SearchQuery(q: "   ")
        session.run(record: true)
        #expect(session.phase == .idle)
        #expect(session.matches.isEmpty)
        #expect(session.next == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func aFilterAloneIsEnoughToSearch() async {
        let query = SearchQuery(q: "", hasFile: true)
        transport.stub("GET", "/api/searches?q=&has=file", json: answer(query, matches: Fixtures.messages(1)))
        session.query = query
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
    }

    @Test func aFailureShowsTheServersWordsAndRetryRunsItAgain() async {
        transport.stub("GET", "/api/searches?q=engine", status: 500, json: Fixtures.errorJSON("Search is down."))
        session.query = SearchQuery(q: "engine")
        session.run(record: false)
        #expect(await eventually { session.phase == .failed("Search is down.") })
        transport.stub("GET", "/api/searches?q=engine", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1)))
        session.retry()
        #expect(session.phase == .searching)
        #expect(await eventually { session.phase == .loaded })
        #expect(session.matches.count == 1)
    }

    @Test func aSlowAnswerToAnEarlierSearchIsDropped() async {
        let slow = transport.hold("GET", "/api/searches?q=first")
        transport.stub("GET", "/api/searches?q=first", json: answer(SearchQuery(q: "first"), matches: [Fixtures.message("old", "First")]))
        transport.stub("GET", "/api/searches?q=second", json: answer(SearchQuery(q: "second"), matches: [Fixtures.message("new", "Second")]))
        session.query = SearchQuery(q: "first")
        session.run(record: false)
        await slow.waitForRequest()
        session.query = SearchQuery(q: "second")
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
        slow.release()
        await settle()
        #expect(session.matches.map(\.id) == ["new"])
        #expect(session.phase == .loaded)
    }

    @Test func aFurtherPageContinuesTheShownSearchEvenIfTheQueryWasEdited() async {
        let first = SearchQuery(q: "engine")
        transport.stub("GET", "/api/searches?q=engine", json: answer(first, matches: Fixtures.messages(2), next: 40))
        transport.stub("GET", "/api/searches?q=engine&cursor=40", json: answer(first, matches: Fixtures.messages(2, from: 2), next: nil))
        session.query = first
        session.run(record: false)
        #expect(await eventually { session.canLoadMore })
        session.query = SearchQuery(q: "something else")
        session.loadMore()
        #expect(session.isLoadingMore)
        #expect(await eventually { !session.isLoadingMore })
        #expect(session.matches.map(\.id) == ["m001", "m002", "m003"])
        #expect(session.next == nil)
        #expect(session.canLoadMore == false)
    }

    @Test func aFurtherPageIsNotAskedForTwice() async {
        let query = SearchQuery(q: "engine")
        transport.stub("GET", "/api/searches?q=engine", json: answer(query, matches: Fixtures.messages(1), next: 40))
        let gate = transport.hold("GET", "/api/searches?q=engine&cursor=40")
        transport.stub("GET", "/api/searches?q=engine&cursor=40", json: answer(query, matches: Fixtures.messages(1, from: 2)))
        session.query = query
        session.run(record: false)
        #expect(await eventually { session.canLoadMore })
        session.loadMore()
        session.loadMore()
        await gate.waitForRequest()
        gate.release()
        #expect(await eventually { !session.isLoadingMore })
        #expect(transport.requests("GET", "/api/searches?q=engine&cursor=40").count == 1)
    }

    @Test func aFailedPageKeepsTheMatchesAndSaysWhy() async {
        let query = SearchQuery(q: "engine")
        transport.stub("GET", "/api/searches?q=engine", json: answer(query, matches: Fixtures.messages(1), next: 40))
        transport.stub("GET", "/api/searches?q=engine&cursor=40", status: 500, json: Fixtures.errorJSON("Try again."))
        session.query = query
        session.run(record: false)
        #expect(await eventually { session.canLoadMore })
        session.loadMore()
        #expect(await eventually { session.moreFailure == "Try again." })
        #expect(session.matches.count == 1)
        #expect(session.phase == .loaded)
        #expect(session.canLoadMore)
    }

    @Test func runningARecentSearchPutsItInTheQueryAndRecordsIt() async {
        let recent = SearchQuery(q: "launch", roomID: Fixtures.general.id)
        transport.stub("POST", "/api/searches", status: 201, json: answer(recent, matches: Fixtures.messages(1), recent: [recent]))
        session.run(recent)
        #expect(session.query == recent)
        #expect(await eventually { session.phase == .loaded })
        #expect(transport.requests("POST", "/api/searches").count == 1)
    }

    @Test func recentSearchesLoadOnceAndOnlyWhileIdle() async {
        let recent = [SearchQuery(q: "launch")]
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON(recent: recent))
        await session.loadRecent()
        #expect(session.recent == recent)
        transport.stub("GET", "/api/searches?q=engine", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1)))
        session.query = SearchQuery(q: "engine")
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
        let before = transport.requests.count
        await session.loadRecent()
        #expect(transport.requests.count == before)
    }

    @Test func clearingTheRecentSearchesEmptiesThemOnlyOnceTheServerHas() async {
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON(recent: [SearchQuery(q: "launch")]))
        await session.loadRecent()
        transport.stub("DELETE", "/api/searches", status: 500, json: Fixtures.errorJSON("No."))
        await session.clearRecent()
        #expect(session.recent.count == 1)
        transport.stub("DELETE", "/api/searches", status: 204, json: "")
        await session.clearRecent()
        #expect(session.recent.isEmpty)
    }

    @Test func clearingTheFiltersKeepsTheWords() {
        session.query = SearchQuery(q: "engine", roomID: "room-general", from: "user_ada", withMe: true, hasLink: true, hasFile: true, inThread: true)
        session.clearFilters()
        #expect(session.query == SearchQuery(q: "engine"))
    }

    @Test func resettingCancelsASearchOnItsWayAndKeepsTheQuery() async {
        let gate = transport.hold("GET", "/api/searches?q=engine")
        transport.stub("GET", "/api/searches?q=engine", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1)))
        session.query = SearchQuery(q: "engine")
        session.run(record: false)
        await gate.waitForRequest()
        session.reset()
        gate.release()
        await settle()
        #expect(session.phase == .idle)
        #expect(session.matches.isEmpty)
        #expect(session.query.q == "engine")
    }

    @Test func resettingDropsTheRoomsOfTheResultsWithThem() async {
        transport.stub("GET", "/api/searches?q=engine", json: answer(SearchQuery(q: "engine"), matches: Fixtures.messages(1), next: 2))
        session.query = SearchQuery(q: "engine")
        session.run(record: false)
        #expect(await eventually { session.phase == .loaded })
        #expect(!session.rooms.isEmpty)

        session.reset()
        #expect(session.matches.isEmpty)
        #expect(session.rooms.isEmpty)
        #expect(session.next == nil)
    }
}

import EmberTesting
import Foundation
import Testing

/// The clock the tests move: which sleeps a move would wake, and moving it only once they're waiting.
@MainActor @Suite struct ManualClockTests {
    @Test func countsTheSleepsAMoveWouldWake() async throws {
        let clock = ManualClock()
        let soon = Task { try await clock.sleep(for: .seconds(1)) }
        let later = Task { try await clock.sleep(for: .seconds(10)) }
        #expect(await eventually { clock.sleeperCount == 2 })
        #expect(clock.sleeperCount(dueWithin: .milliseconds(999)) == 0)
        #expect(clock.sleeperCount(dueWithin: .seconds(1)) == 1)
        #expect(clock.sleeperCount(dueWithin: .seconds(10)) == 2)

        clock.advance(by: .seconds(1))
        try await soon.value
        #expect(clock.sleeperCount(dueWithin: .seconds(8)) == 0)
        #expect(clock.sleeperCount(dueWithin: .seconds(9)) == 1)

        later.cancel()
        await #expect(throws: CancellationError.self) { try await later.value }
        #expect(clock.sleeperCount(dueWithin: .seconds(9)) == 0)
    }

    @Test func passingTimeWaitsForASleepThatStartsLate() async throws {
        let clock = ManualClock()
        // As the SDK's timers do, the sleep starts a while after whatever set it going.
        let sleep = Task.detached {
            try await Task.sleep(for: .milliseconds(50))
            try await clock.sleep(for: .seconds(1))
        }
        #expect(await clock.pass(.seconds(5)))
        try await sleep.value
        #expect(clock.now == ManualClock.Instant(offset: .seconds(5)))
    }
}

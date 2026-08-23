import Foundation
import Testing

@testable import TmuxSwitcherCore

struct SessionRingTests {
    @Test("antipodal repeat with even N")
    func testAntipodalRepeatEvenN() {
        let sessions = ["Dotfiles", "omniwm", "tmux", "vigia"]
        let currentIndex = 1  // omniwm
        let maxRadius = 4

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        #expect(rows.count == 5)
        let names = rows.map { $0.name }
        #expect(names == ["vigia", "Dotfiles", "omniwm", "tmux", "vigia"])

        let offsets = rows.map { $0.offset }
        #expect(offsets == [-2, -1, 0, 1, 2])

        // Verify the middle row is current
        #expect(rows[2].isCurrent == true)
    }

    @Test("no repeat with odd N")
    func testNoRepeatOddN() {
        let sessions = ["a", "b", "c", "d", "e"]
        let currentIndex = 0
        let maxRadius = 4

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        #expect(rows.count == 5)
        let names = rows.map { $0.name }
        #expect(names == ["d", "e", "a", "b", "c"])

        let offsets = rows.map { $0.offset }
        #expect(offsets == [-2, -1, 0, 1, 2])

        // Assert all 5 names are unique
        let uniqueNames = Set(names)
        #expect(uniqueNames.count == 5)
    }

    @Test("single other session appears above and below")
    func testTwoSessionsWraparound() {
        let sessions = ["a", "b"]
        let currentIndex = 0
        let maxRadius = 4

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        #expect(rows.count == 3)
        let names = rows.map { $0.name }
        #expect(names == ["b", "a", "b"])

        let offsets = rows.map { $0.offset }
        #expect(offsets == [-1, 0, 1])
    }

    @Test("single session")
    func testSingleSession() {
        let sessions = ["only"]
        let currentIndex = 0

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: 4)

        #expect(result != nil)
        guard let rows = result else { return }

        #expect(rows.count == 1)
        #expect(rows[0].name == "only")
        #expect(rows[0].offset == 0)
        #expect(rows[0].isCurrent == true)
    }

    @Test("empty sessions returns nil")
    func testEmptySessions() {
        let result = SessionRing.rows(sessions: [], currentIndex: 0, maxRadius: 4)
        #expect(result == nil)
    }

    @Test("out of bounds currentIndex returns nil")
    func testOutOfBoundsIndex() {
        let sessions = ["a", "b", "c"]

        let result1 = SessionRing.rows(sessions: sessions, currentIndex: 9, maxRadius: 4)
        #expect(result1 == nil)

        let result2 = SessionRing.rows(sessions: sessions, currentIndex: -1, maxRadius: 4)
        #expect(result2 == nil)
    }

    @Test("wraparound at last index")
    func testWraparoundLastIndex() {
        let sessions = ["a", "b", "c"]
        let currentIndex = 2  // last element (c)
        let maxRadius = 4

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        // N=3 (odd), radius k = (3-1)/2 = 1
        // So we get offsets [-1, 0, 1]
        // At i=2: (2-1)%3 = 1 (b), (2+0)%3 = 2 (c), (2+1)%3 = 0 (a)
        let names = rows.map { $0.name }
        #expect(names == ["b", "c", "a"])

        let offsets = rows.map { $0.offset }
        #expect(offsets == [-1, 0, 1])
    }

    @Test("clamping with many sessions")
    func testClampingLargeSessions() {
        let sessions = (0..<20).map { String($0) }
        let currentIndex = 10
        let maxRadius = 2

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        // maxRadius=2, should get exactly 5 rows: offsets [-2, -1, 0, 1, 2]
        #expect(rows.count == 5)

        let offsets = rows.map { $0.offset }
        #expect(offsets == [-2, -1, 0, 1, 2])

        // No name repeats (even though N is even, maxRadius is clamped to 2, which is < 10)
        let names = rows.map { $0.name }
        let uniqueNames = Set(names)
        #expect(uniqueNames.count == 5)
    }

    @Test("order preservation with mixed case")
    func testOrderPreservation() {
        let sessions = ["Zebra", "apple", "Banana"]
        let currentIndex = 1  // apple
        let maxRadius = 4

        let result = SessionRing.rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius)

        #expect(result != nil)
        guard let rows = result else { return }

        // N=3 (odd), radius k = 1
        // Offsets: [-1, 0, 1]
        // At i=1: (1-1)%3 = 0 (Zebra), (1+0)%3 = 1 (apple), (1+1)%3 = 2 (Banana)
        let names = rows.map { $0.name }
        #expect(names == ["Zebra", "apple", "Banana"])

        // Guard that order is preserved (no sorting occurred)
        #expect(names[0] == "Zebra")  // Capital Z comes before lowercase a in the original list
        #expect(names[1] == "apple")
        #expect(names[2] == "Banana")
    }

    @Test("Row equality and Sendable conformance")
    func testRowEquality() {
        let row1 = Row(name: "test", offset: 0)
        let row2 = Row(name: "test", offset: 0)
        let row3 = Row(name: "test", offset: 1)

        #expect(row1 == row2)
        #expect(row1 != row3)
    }

    @Test("isCurrent flag")
    func testIsCurrentFlag() {
        let row0 = Row(name: "session", offset: 0)
        let row1 = Row(name: "session", offset: 1)
        let rowNeg1 = Row(name: "session", offset: -1)

        #expect(row0.isCurrent == true)
        #expect(row1.isCurrent == false)
        #expect(rowNeg1.isCurrent == false)
    }
}

@Suite("ringStep")
struct RingStepTests {
    @Test("adjacent forward is +1")
    func adjacentForward() {
        #expect(SessionRing.ringStep(from: 0, to: 1, count: 4) == 1)
        #expect(SessionRing.ringStep(from: 2, to: 3, count: 4) == 1)
    }

    @Test("adjacent backward is -1")
    func adjacentBackward() {
        #expect(SessionRing.ringStep(from: 1, to: 0, count: 4) == -1)
        #expect(SessionRing.ringStep(from: 3, to: 2, count: 4) == -1)
    }

    @Test("wraparound forward: last to first is +1, not -(count-1)")
    func wrapForward() {
        #expect(SessionRing.ringStep(from: 3, to: 0, count: 4) == 1)
        #expect(SessionRing.ringStep(from: 4, to: 0, count: 5) == 1)
    }

    @Test("wraparound backward: first to last is -1")
    func wrapBackward() {
        #expect(SessionRing.ringStep(from: 0, to: 3, count: 4) == -1)
        #expect(SessionRing.ringStep(from: 0, to: 4, count: 5) == -1)
    }

    @Test("same index is 0")
    func same() {
        #expect(SessionRing.ringStep(from: 2, to: 2, count: 4) == 0)
    }

    @Test("non-adjacent jumps are not +/-1 so they suppress animation")
    func nonAdjacent() {
        #expect(SessionRing.ringStep(from: 0, to: 2, count: 5) == 2)
        #expect(SessionRing.ringStep(from: 0, to: 3, count: 6) == 3)
        #expect(abs(SessionRing.ringStep(from: 0, to: 2, count: 5)) != 1)
    }

    @Test("degenerate counts do not trap")
    func degenerate() {
        #expect(SessionRing.ringStep(from: 0, to: 0, count: 1) == 0)
        #expect(SessionRing.ringStep(from: 0, to: 0, count: 0) == 0)
    }
}

@Suite("RingWindow bleed rows")
struct RingWindowTests {
    @Test("bleed rows match the concrete Dotfiles/omniwm/tmux/vigia case")
    func concreteCase() {
        let sessions = ["Dotfiles", "omniwm", "tmux", "vigia"]
        let w = SessionRing.window(sessions: sessions, currentIndex: 1, maxRadius: 4)!
        #expect(w.visible.map(\.name) == ["vigia", "Dotfiles", "omniwm", "tmux", "vigia"])
        // pressing j lands on "tmux"; the row entering from the bottom is "Dotfiles"
        #expect(w.bleedBelow?.name == "Dotfiles")
        // pressing k lands on "Dotfiles"; the row entering from the top is "tmux"
        #expect(w.bleedAbove?.name == "tmux")
    }

    /// The invariant the whole gapless-scroll animation rests on: whatever sits in
    /// a bleed slot must be exactly the row that ends up at that edge after the
    /// step. If this ever fails, sliding shows the wrong name entering.
    @Test("bleed row equals the edge row of the next/previous window")
    func bleedMatchesNextWindow() {
        for n in 2...9 {
            let sessions = (0..<n).map { "s\($0)" }
            for i in 0..<n {
                let current = SessionRing.window(sessions: sessions, currentIndex: i, maxRadius: 4)!
                let afterNext = SessionRing.window(sessions: sessions, currentIndex: (i + 1) % n, maxRadius: 4)!
                let afterPrev = SessionRing.window(sessions: sessions, currentIndex: (i - 1 + n) % n, maxRadius: 4)!

                #expect(current.bleedBelow?.name == afterNext.visible.last?.name,
                        "n=\(n) i=\(i): bottom bleed must become the new bottom row")
                #expect(current.bleedAbove?.name == afterPrev.visible.first?.name,
                        "n=\(n) i=\(i): top bleed must become the new top row")
            }
        }
    }

    @Test("a single session has nowhere to scroll, so no bleed")
    func singleSession() {
        let w = SessionRing.window(sessions: ["only"], currentIndex: 0, maxRadius: 4)!
        #expect(w.visible.count == 1)
        #expect(w.bleedAbove == nil)
        #expect(w.bleedBelow == nil)
    }

    @Test("empty or out-of-range yields nil")
    func invalid() {
        #expect(SessionRing.window(sessions: [], currentIndex: 0, maxRadius: 4) == nil)
        #expect(SessionRing.window(sessions: ["a", "b"], currentIndex: 7, maxRadius: 4) == nil)
    }

    @Test("radius matches the documented odd/even rule and clamps")
    func radiusRule() {
        #expect(SessionRing.radius(count: 5, maxRadius: 4) == 2)   // odd
        #expect(SessionRing.radius(count: 4, maxRadius: 4) == 2)   // even -> antipodal repeat
        #expect(SessionRing.radius(count: 20, maxRadius: 4) == 4)  // clamped
        #expect(SessionRing.radius(count: 1, maxRadius: 4) == 0)
    }
}

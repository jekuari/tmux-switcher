import Foundation
import Testing

@testable import TmuxSwitcherCore

struct TmuxClientTests {
    @Test("parseSessionList empty output")
    func testParseSessionListEmpty() {
        let result = TmuxClient.parseSessionList("")
        #expect(result == [])
    }

    @Test("parseSessionList single session")
    func testParseSessionListSingle() {
        let output = "mysession\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["mysession"])
    }

    @Test("parseSessionList multiple sessions")
    func testParseSessionListMultiple() {
        let output = "session1\nsession2\nsession3\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session1", "session2", "session3"])
    }

    @Test("parseSessionList preserves order")
    func testParseSessionListOrder() {
        let output = "zebra\napple\nbanana\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["zebra", "apple", "banana"])
    }

    @Test("parseSessionList trims whitespace")
    func testParseSessionListTrimsWhitespace() {
        let output = "  session1  \n\t session2 \t\n session3  \n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session1", "session2", "session3"])
    }

    @Test("parseSessionList drops empty lines")
    func testParseSessionListDropsEmpty() {
        let output = "session1\n\n\nsession2\n\nsession3\n\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session1", "session2", "session3"])
    }

    @Test("parseSessionList handles no trailing newline")
    func testParseSessionListNoTrailingNewline() {
        let output = "session1\nsession2\nsession3"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session1", "session2", "session3"])
    }

    @Test("parseSessionList only newlines")
    func testParseSessionListOnlyNewlines() {
        let output = "\n\n\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == [])
    }

    @Test("parseSessionList with special characters in names")
    func testParseSessionListSpecialCharacters() {
        let output = "my-session-1\nsession_2\nsession.3\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["my-session-1", "session_2", "session.3"])
    }

    @Test("parseSessionList preserves whitespace in session names")
    func testParseSessionListPreservesInternalWhitespace() {
        let output = "session with spaces\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session with spaces"])
    }

    @Test("parseSessionList unicode")
    func testParseSessionListUnicode() {
        let output = "session-日本語\nsession-éàü\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session-日本語", "session-éàü"])
    }

    @Test("parseSessionList only whitespace is dropped")
    func testParseSessionListOnlyWhitespace() {
        let output = "session1\n   \n\t\nsession2\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == ["session1", "session2"])
    }

    @Test("parseSessionList large number of sessions")
    func testParseSessionListLarge() {
        let sessions = (0..<100).map { "session-\($0)" }
        let output = sessions.joined(separator: "\n") + "\n"
        let result = TmuxClient.parseSessionList(output)
        #expect(result == sessions)
    }

    @Test("parseSessionList order after mixed whitespace")
    func testParseSessionListOrderAfterWhitespace() {
        let output = "  a  \n  b  \n  c  \n"
        let result = TmuxClient.parseSessionList(output)
        // Order must be preserved even with whitespace variations
        #expect(result == ["a", "b", "c"])
    }
}

import Foundation
import Testing

@testable import TmuxSwitcherCore

struct ConfigTests {
    @Test("defaults are correct")
    func testDefaults() {
        let config = Config.defaults

        #expect(config.dwellMs == 150)
        #expect(config.idleHideMs == 2000)
        #expect(config.maxDisplayMs == 0)   // hard cap disabled by default
        #expect(config.modifierPollMs == 100)
        #expect(config.maxRadius == 4)
        #expect(config.tmuxBin == "/opt/homebrew/bin/tmux")
        #expect(config.ghosttyBundleID == "com.mitchellh.ghostty")
        #expect(config.showDirectionHints == true)
        #expect(config.animate == true)
    }

    @Test("parse empty string returns defaults")
    func testParseEmpty() {
        let config = Config.parse("")

        #expect(config.dwellMs == 150)
        #expect(config.idleHideMs == 2000)
        #expect(config.maxDisplayMs == 0)   // hard cap disabled by default
        #expect(config.modifierPollMs == 100)
        #expect(config.maxRadius == 4)
        #expect(config.tmuxBin == "/opt/homebrew/bin/tmux")
        #expect(config.ghosttyBundleID == "com.mitchellh.ghostty")
        #expect(config.showDirectionHints == true)
        #expect(config.animate == true)
    }

    @Test("parse int values")
    func testParseInts() {
        let text = """
        DWELL_MS=300
        IDLE_HIDE_MS=5000
        MAX_DISPLAY_MS=20000
        MODIFIER_POLL_MS=50
        MAX_RADIUS=8
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
        #expect(config.maxDisplayMs == 20000)
        #expect(config.modifierPollMs == 50)
        #expect(config.maxRadius == 8)
    }

    @Test("parse string values")
    func testParseStrings() {
        let text = """
        TMUX_BIN=/usr/local/bin/tmux
        GHOSTTY_BUNDLE_ID=com.example.app
        """

        let config = Config.parse(text)

        #expect(config.tmuxBin == "/usr/local/bin/tmux")
        #expect(config.ghosttyBundleID == "com.example.app")
    }

    @Test("parse boolean values (true)")
    func testParseBoolTrue() {
        let text = """
        SHOW_DIRECTION_HINTS=true
        ANIMATE=1
        """

        let config = Config.parse(text)

        #expect(config.showDirectionHints == true)
        #expect(config.animate == true)
    }

    @Test("parse boolean values (false)")
    func testParseBoolFalse() {
        let text = """
        SHOW_DIRECTION_HINTS=false
        ANIMATE=0
        """

        let config = Config.parse(text)

        #expect(config.showDirectionHints == false)
        #expect(config.animate == false)
    }

    @Test("parse boolean values (yes/no)")
    func testParseBoolYesNo() {
        let text = """
        SHOW_DIRECTION_HINTS=yes
        ANIMATE=no
        """

        let config = Config.parse(text)

        #expect(config.showDirectionHints == true)
        #expect(config.animate == false)
    }

    @Test("parse boolean values (case insensitive)")
    func testParseBoolCaseInsensitive() {
        let text = """
        SHOW_DIRECTION_HINTS=TRUE
        ANIMATE=False
        """

        let config = Config.parse(text)

        #expect(config.showDirectionHints == true)
        #expect(config.animate == false)
    }

    @Test("parse with quotes")
    func testParseWithQuotes() {
        let text = """
        TMUX_BIN="/opt/homebrew/bin/tmux"
        GHOSTTY_BUNDLE_ID='com.mitchellh.ghostty'
        """

        let config = Config.parse(text)

        #expect(config.tmuxBin == "/opt/homebrew/bin/tmux")
        #expect(config.ghosttyBundleID == "com.mitchellh.ghostty")
    }

    @Test("parse ignores comments")
    func testParseIgnoresComments() {
        let text = """
        # This is a comment
        DWELL_MS=300
        # Another comment
        IDLE_HIDE_MS=5000
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
    }

    @Test("parse ignores blank lines")
    func testParseIgnoresBlankLines() {
        let text = """

        DWELL_MS=300

        IDLE_HIDE_MS=5000

        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
    }

    @Test("parse ignores unknown keys")
    func testParseIgnoresUnknown() {
        let text = """
        DWELL_MS=300
        UNKNOWN_KEY=value
        IDLE_HIDE_MS=5000
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
    }

    @Test("parse ignores malformed lines")
    func testParseMalformedLines() {
        let text = """
        DWELL_MS=300
        this line has no equals sign
        IDLE_HIDE_MS=5000
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
    }

    @Test("parse later duplicates win")
    func testParseDuplicatesWin() {
        let text = """
        DWELL_MS=300
        DWELL_MS=500
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 500)
    }

    @Test("parse invalid int keeps default")
    func testParseInvalidIntKeepsDefault() {
        let text = """
        DWELL_MS=not_a_number
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 150)  // default
    }

    @Test("parse int clamping to 0")
    func testParseClampingNegative() {
        let text = """
        DWELL_MS=-100
        IDLE_HIDE_MS=-50
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 0)
        #expect(config.idleHideMs == 0)
    }

    @Test("parse maxRadius clamping to 1")
    func testParseClampingMaxRadius() {
        let text = """
        MAX_RADIUS=0
        """

        let config = Config.parse(text)

        #expect(config.maxRadius == 1)
    }

    @Test("parse whitespace trimming")
    func testParseWhitespaceTrimming() {
        let text = """
          DWELL_MS  =  300
          TMUX_BIN = /usr/bin/tmux
        """

        let config = Config.parse(text)

        #expect(config.dwellMs == 300)
        #expect(config.tmuxBin == "/usr/bin/tmux")
    }

    @Test("configURL property exists and is not empty")
    func testConfigURLExists() {
        let url = Config.configURL
        #expect(!url.path.isEmpty)
        #expect(url.path.contains(".config/tmux-switcher/config.env"))
    }

    @Test("socketPath property exists and is not empty")
    func testSocketPathExists() {
        let path = Config.socketPath
        #expect(!path.isEmpty)
        #expect(path.contains(".config/tmux-switcher/notify.sock"))
    }

    @Test("equality")
    func testEquality() {
        let config1 = Config.parse("DWELL_MS=300")
        let config2 = Config.parse("DWELL_MS=300")
        let config3 = Config.parse("DWELL_MS=500")

        #expect(config1 == config2)
        #expect(config1 != config3)
    }
}

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
        #expect(config.scrollAnimationMs == 200)
        #expect(config.useLiquidGlass == true)
    }

    // MARK: - Empty and minimal documents

    @Test("empty string returns defaults")
    func testParseEmpty() throws {
        // Not valid JSON, but the most natural way to say "no overrides", so
        // it is answered before the decoder ever sees it.
        #expect(try Config.parse("") == Config.defaults)
    }

    @Test("whitespace-only returns defaults")
    func testParseWhitespaceOnly() throws {
        #expect(try Config.parse("\n\n   \t\n") == Config.defaults)
    }

    @Test("empty object returns defaults")
    func testParseEmptyObject() throws {
        #expect(try Config.parse("{}") == Config.defaults)
    }

    // MARK: - Values

    @Test("parse int values")
    func testParseInts() throws {
        let config = try Config.parse("""
        {
          "dwellMs": 300,
          "idleHideMs": 5000,
          "maxDisplayMs": 20000,
          "modifierPollMs": 50,
          "maxRadius": 8,
          "scrollAnimationMs": 0
        }
        """)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
        #expect(config.maxDisplayMs == 20000)
        #expect(config.modifierPollMs == 50)
        #expect(config.maxRadius == 8)
        #expect(config.scrollAnimationMs == 0)
    }

    @Test("parse string values")
    func testParseStrings() throws {
        let config = try Config.parse("""
        {
          "tmuxBin": "/usr/local/bin/tmux",
          "ghosttyBundleID": "com.example.app"
        }
        """)

        #expect(config.tmuxBin == "/usr/local/bin/tmux")
        #expect(config.ghosttyBundleID == "com.example.app")
    }

    @Test("parse boolean values")
    func testParseBools() throws {
        let allTrue = try Config.parse("""
        { "showDirectionHints": true, "animate": true, "useLiquidGlass": true }
        """)
        #expect(allTrue.showDirectionHints == true)
        #expect(allTrue.animate == true)
        #expect(allTrue.useLiquidGlass == true)

        let allFalse = try Config.parse("""
        { "showDirectionHints": false, "animate": false, "useLiquidGlass": false }
        """)
        #expect(allFalse.showDirectionHints == false)
        #expect(allFalse.animate == false)
        #expect(allFalse.useLiquidGlass == false)
    }

    @Test("a partial document overrides only the keys it names")
    func testPartialOverride() throws {
        let config = try Config.parse(#"{ "dwellMs": 42 }"#)

        #expect(config.dwellMs == 42)
        // Everything else must be untouched -- this is the property that lets a
        // config file mention only the knobs the user actually cares about.
        #expect(config.idleHideMs == Config.defaults.idleHideMs)
        #expect(config.maxRadius == Config.defaults.maxRadius)
        #expect(config.tmuxBin == Config.defaults.tmuxBin)
        #expect(config.animate == Config.defaults.animate)
    }

    @Test("unknown keys are ignored")
    func testParseIgnoresUnknown() throws {
        // Forward compatibility: a config written for a newer build must not
        // break an older binary.
        let config = try Config.parse("""
        { "dwellMs": 300, "someFutureKey": "whatever", "idleHideMs": 5000 }
        """)

        #expect(config.dwellMs == 300)
        #expect(config.idleHideMs == 5000)
    }

    // MARK: - JSON5 affordances

    @Test("comments are accepted")
    func testParseComments() throws {
        let config = try Config.parse("""
        {
          // Raise this if quick Meh chords flash the HUD.
          "dwellMs": 250,
          /* block comments too */
          "maxRadius": 6
        }
        """)

        #expect(config.dwellMs == 250)
        #expect(config.maxRadius == 6)
    }

    @Test("trailing commas are accepted")
    func testParseTrailingComma() throws {
        let config = try Config.parse("""
        {
          "dwellMs": 250,
          "maxRadius": 6,
        }
        """)

        #expect(config.dwellMs == 250)
        #expect(config.maxRadius == 6)
    }

    @Test("unquoted keys are accepted")
    func testParseUnquotedKeys() throws {
        let config = try Config.parse("{ dwellMs: 250 }")
        #expect(config.dwellMs == 250)
    }

    // MARK: - Clamping

    @Test("negative durations clamp to 0")
    func testParseClampingNegative() throws {
        let config = try Config.parse("""
        {
          "dwellMs": -100,
          "idleHideMs": -50,
          "maxDisplayMs": -1,
          "modifierPollMs": -5,
          "scrollAnimationMs": -200
        }
        """)

        #expect(config.dwellMs == 0)
        #expect(config.idleHideMs == 0)
        #expect(config.maxDisplayMs == 0)
        #expect(config.modifierPollMs == 0)
        #expect(config.scrollAnimationMs == 0)
    }

    @Test("maxRadius clamps to 1")
    func testParseClampingMaxRadius() throws {
        // A radius of 0 would render a HUD with no rows in it at all.
        #expect(try Config.parse(#"{ "maxRadius": 0 }"#).maxRadius == 1)
        #expect(try Config.parse(#"{ "maxRadius": -3 }"#).maxRadius == 1)
    }

    // MARK: - Malformed input

    @Test("invalid JSON throws")
    func testParseInvalidJSONThrows() {
        // The KEY=value parser skipped bad lines silently. It cannot work that
        // way here: a JSON document is parsed whole, so ignoring the failure
        // would silently revert every other setting in the file too.
        #expect(throws: ConfigError.self) {
            try Config.parse("{ this is not json")
        }
    }

    @Test("a non-object document throws")
    func testParseNonObjectThrows() {
        #expect(throws: ConfigError.self) {
            try Config.parse("[1, 2, 3]")
        }
    }

    @Test("a wrongly typed value throws and names the key")
    func testParseTypeMismatchThrows() {
        let error = #expect(throws: ConfigError.self) {
            try Config.parse(#"{ "dwellMs": "not a number" }"#)
        }

        // The stock DecodingError message says only that the data "isn't in the
        // correct format", which is useless for finding the typo. Naming the
        // offending key is the whole reason describe() exists.
        #expect(error?.description.contains("dwellMs") == true)
    }

    @Test("a wrongly typed bool throws")
    func testParseBoolTypeMismatchThrows() {
        // Notably `"animate": "yes"` was valid in the old format and is not
        // valid here -- worth a test so the break is deliberate, not incidental.
        #expect(throws: ConfigError.self) {
            try Config.parse(#"{ "animate": "yes" }"#)
        }
    }

    @Test("an explicit null falls back to the default")
    func testParseNullUsesDefault() throws {
        // Decoding into `Int?` maps an explicit JSON null to nil, which merges
        // as "no override". That reads correctly -- null and an absent key mean
        // the same thing to a reader -- so it is pinned here as intended
        // behaviour rather than left as an accident of Codable.
        let config = try Config.parse(#"{ "dwellMs": null, "maxRadius": 7 }"#)

        #expect(config.dwellMs == Config.defaults.dwellMs)
        #expect(config.maxRadius == 7)
    }

    // MARK: - Locations

    @Test("configURL points at config.json")
    func testConfigURLExists() {
        let url = Config.configURL
        #expect(!url.path.isEmpty)
        #expect(url.path.contains(".config/tmux-switcher/config.json"))
    }

    @Test("legacyConfigURL still points at the pre-JSON config.env")
    func testLegacyConfigURLExists() {
        // Nothing reads this; it exists so a leftover file can be detected and
        // reported instead of appearing to be silently ignored.
        #expect(Config.legacyConfigURL.path.contains(".config/tmux-switcher/config.env"))
    }

    @Test("socketPath property exists and is not empty")
    func testSocketPathExists() {
        let path = Config.socketPath
        #expect(!path.isEmpty)
        #expect(path.contains(".config/tmux-switcher/notify.sock"))
    }

    @Test("equality")
    func testEquality() throws {
        let config1 = try Config.parse(#"{ "dwellMs": 300 }"#)
        let config2 = try Config.parse(#"{ "dwellMs": 300 }"#)
        let config3 = try Config.parse(#"{ "dwellMs": 500 }"#)

        #expect(config1 == config2)
        #expect(config1 != config3)
    }

    @Test("formatting differences do not change the result")
    func testEqualityAcrossFormatting() throws {
        let compact = try Config.parse(#"{"dwellMs":300,"maxRadius":6}"#)
        let sprawling = try Config.parse("""
        {
            "maxRadius":   6,

            // order and whitespace are irrelevant
            "dwellMs":     300,
        }
        """)

        #expect(compact == sprawling)
    }
}

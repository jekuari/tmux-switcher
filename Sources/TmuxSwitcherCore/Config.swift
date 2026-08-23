import Foundation

/// Something went wrong reading a config file that *does* exist.
///
/// A missing file is deliberately not an error — it just means "use defaults" —
/// so this is only ever raised for a file the user has actually written and got
/// wrong, which is exactly the case worth telling them about.
public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let detail): return detail
        }
    }
}

/// Configuration for the HUD, read from `~/.config/tmux-switcher/config.json`.
///
/// Parsing is JSON5-tolerant: `//` comments, unquoted keys and trailing commas
/// are all accepted. Plain JSON has no comment syntax, which would have made
/// this a strictly worse format than the `KEY=value` file it replaced for a
/// file whose whole purpose is to be hand-edited and annotated.
///
/// Every key is optional and falls back to `Config.defaults`, so a config file
/// only ever has to name the knobs it actually changes. Unknown keys are
/// ignored, which keeps a config written for a newer version from breaking an
/// older binary.
public struct Config: Equatable, Sendable {
    public var dwellMs: Int
    public var idleHideMs: Int
    /// Absolute cap on how long the HUD may stay up. 0 disables it entirely.
    public var maxDisplayMs: Int
    public var modifierPollMs: Int
    public var maxRadius: Int
    public var tmuxBin: String
    public var ghosttyBundleID: String
    public var showDirectionHints: Bool
    public var animate: Bool
    /// Duration of the one-row slide when the session changes. 0 disables it.
    public var scrollAnimationMs: Int
    /// Use macOS 26 Liquid Glass for the pills. Falls back to a translucent
    /// capsule when off, or on systems older than macOS 26.
    public var useLiquidGlass: Bool

    public init(
        dwellMs: Int = 150,
        idleHideMs: Int = 2000,
        maxDisplayMs: Int = 0,
        modifierPollMs: Int = 100,
        maxRadius: Int = 4,
        tmuxBin: String = "/opt/homebrew/bin/tmux",
        ghosttyBundleID: String = "com.mitchellh.ghostty",
        showDirectionHints: Bool = true,
        animate: Bool = true,
        scrollAnimationMs: Int = 200,
        useLiquidGlass: Bool = true
    ) {
        self.dwellMs = dwellMs
        self.idleHideMs = idleHideMs
        self.maxDisplayMs = maxDisplayMs
        self.modifierPollMs = modifierPollMs
        self.maxRadius = maxRadius
        self.tmuxBin = tmuxBin
        self.ghosttyBundleID = ghosttyBundleID
        self.showDirectionHints = showDirectionHints
        self.animate = animate
        self.scrollAnimationMs = scrollAnimationMs
        self.useLiquidGlass = useLiquidGlass
    }

    public static let defaults = Config()

    // MARK: - Parsing

    /// Mirrors `Config` with every field optional. Decoding into this and then
    /// merging onto `defaults` is what gives a partial file the meaning
    /// "override only these keys" — decoding straight into `Config` would
    /// require every key to be present in every file.
    private struct Overrides: Decodable {
        var dwellMs: Int?
        var idleHideMs: Int?
        var maxDisplayMs: Int?
        var modifierPollMs: Int?
        var maxRadius: Int?
        var tmuxBin: String?
        var ghosttyBundleID: String?
        var showDirectionHints: Bool?
        var animate: Bool?
        var scrollAnimationMs: Int?
        var useLiquidGlass: Bool?
    }

    /// Parse configuration from JSON text, starting from defaults and applying
    /// whatever the document overrides. Pure function; no filesystem access.
    ///
    /// Unlike the `KEY=value` parser this replaced, a bad value is *not*
    /// skipped silently. A JSON document is parsed as a whole, so quietly
    /// ignoring a mistyped key would mean silently reverting every other
    /// setting in the file too. Throwing lets the caller keep what it already
    /// had and say why.
    public static func parse(_ text: String) throws -> Config {
        // An empty file is a legitimate "use all defaults", but it is not a
        // valid JSON document, so it is answered before the decoder sees it.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .defaults
        }

        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true

        let overrides: Overrides
        do {
            overrides = try decoder.decode(Overrides.self, from: Data(text.utf8))
        } catch let error as DecodingError {
            throw ConfigError.malformed(describe(error))
        } catch {
            throw ConfigError.malformed(error.localizedDescription)
        }

        return merge(overrides)
    }

    /// Applies overrides onto the defaults, clamping the values whose ranges
    /// the rest of the app relies on (a negative delay or a zero radius would
    /// produce a HUD that can never appear).
    private static func merge(_ overrides: Overrides) -> Config {
        var config = Config.defaults

        if let value = overrides.dwellMs { config.dwellMs = max(0, value) }
        if let value = overrides.idleHideMs { config.idleHideMs = max(0, value) }
        if let value = overrides.maxDisplayMs { config.maxDisplayMs = max(0, value) }
        if let value = overrides.modifierPollMs { config.modifierPollMs = max(0, value) }
        if let value = overrides.maxRadius { config.maxRadius = max(1, value) }
        if let value = overrides.scrollAnimationMs { config.scrollAnimationMs = max(0, value) }
        if let value = overrides.tmuxBin { config.tmuxBin = value }
        if let value = overrides.ghosttyBundleID { config.ghosttyBundleID = value }
        if let value = overrides.showDirectionHints { config.showDirectionHints = value }
        if let value = overrides.animate { config.animate = value }
        if let value = overrides.useLiquidGlass { config.useLiquidGlass = value }

        return config
    }

    /// Turns a `DecodingError` into something worth putting in a log line.
    /// The stock `localizedDescription` for these is "The data couldn't be
    /// read because it isn't in the correct format", which tells the user
    /// nothing about *which* key they got wrong.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "\(keyPath(context)): expected \(type), got something else"
        case .valueNotFound(let type, let context):
            return "\(keyPath(context)): expected \(type), got null"
        case .keyNotFound(let key, let context):
            return "\(keyPath(context)): missing key '\(key.stringValue)'"
        case .dataCorrupted(let context):
            let location = context.codingPath.isEmpty ? "" : "\(keyPath(context)): "
            return "\(location)\(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func keyPath(_ context: DecodingError.Context) -> String {
        context.codingPath.isEmpty
            ? "<root>"
            : context.codingPath.map(\.stringValue).joined(separator: ".")
    }

    // MARK: - Loading

    /// Reads and parses `configURL`.
    ///
    /// Throws only for a file that exists but cannot be read or parsed; a
    /// missing file returns `defaults`. That distinction is the point: at
    /// startup a missing file is normal, while a broken file the user just
    /// saved is worth surfacing rather than silently papering over.
    public static func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .defaults
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigError.malformed(
                "cannot read \(configURL.path): \(error.localizedDescription)"
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.malformed("\(configURL.path) is not valid UTF-8")
        }

        return try parse(text)
    }

    // MARK: - Locations

    /// `~/.config/tmux-switcher`
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tmux-switcher")
    }

    /// `~/.config/tmux-switcher/config.json`
    public static var configURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// `~/.config/tmux-switcher/config.env` — the pre-JSON location.
    ///
    /// Nothing reads this any more. It exists so the app can notice a stale
    /// file still sitting there and say so, rather than appearing to ignore
    /// settings the user believes are in effect.
    public static var legacyConfigURL: URL {
        configDirectory.appendingPathComponent("config.env")
    }

    /// `~/.config/tmux-switcher/notify.sock`
    public static var socketPath: String {
        configDirectory.appendingPathComponent("notify.sock").path
    }
}

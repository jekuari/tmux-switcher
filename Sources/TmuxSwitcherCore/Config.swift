import Foundation

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

    /// Parse configuration from text, starting with defaults and applying overrides.
    /// Pure function; no filesystem access.
    public static func parse(_ text: String) -> Config {
        var config = Config.defaults
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Ignore blank lines and comments
            if trimmed.isEmpty || trimmed.first == "#" {
                continue
            }

            // Split on first =
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                // Malformed line (no =), ignore silently
                continue
            }

            let keyPart = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let valuePart = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes if present
            var value = valuePart
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            // Map key to field and apply
            switch keyPart {
            case "DWELL_MS":
                if let intVal = Int(value) {
                    config.dwellMs = max(0, intVal)
                }
            case "IDLE_HIDE_MS":
                if let intVal = Int(value) {
                    config.idleHideMs = max(0, intVal)
                }
            case "MAX_DISPLAY_MS":
                if let intVal = Int(value) {
                    config.maxDisplayMs = max(0, intVal)
                }
            case "MODIFIER_POLL_MS":
                if let intVal = Int(value) {
                    config.modifierPollMs = max(0, intVal)
                }
            case "MAX_RADIUS":
                if let intVal = Int(value) {
                    config.maxRadius = max(1, intVal)
                }
            case "TMUX_BIN":
                config.tmuxBin = value
            case "GHOSTTY_BUNDLE_ID":
                config.ghosttyBundleID = value
            case "SHOW_DIRECTION_HINTS":
                config.showDirectionHints = parseBool(value)
            case "ANIMATE":
                config.animate = parseBool(value)
            case "USE_LIQUID_GLASS":
                config.useLiquidGlass = parseBool(value)
            case "SCROLL_ANIMATION_MS":
                if let intVal = Int(value) {
                    config.scrollAnimationMs = max(0, intVal)
                }
            default:
                // Unknown keys are ignored silently
                break
            }
        }

        return config
    }

    /// Load configuration from the config file. Returns defaults if file is missing or unreadable.
    public static func load() -> Config {
        do {
            let data = try Data(contentsOf: configURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            return parse(text)
        } catch {
            return Config.defaults
        }
    }

    /// ~/.config/tmux-switcher/config.env
    public static var configURL: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".config/tmux-switcher/config.env")
    }

    /// ~/.config/tmux-switcher/notify.sock
    public static var socketPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/tmux-switcher")
        return configDir.appendingPathComponent("notify.sock").path
    }

    // MARK: - Private Helpers

    private static func parseBool(_ value: String) -> Bool {
        let lower = value.lowercased()
        switch lower {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return false
        }
    }
}

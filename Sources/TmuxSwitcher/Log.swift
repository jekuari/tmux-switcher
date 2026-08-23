import OSLog

enum Log {
    private static let subsystem = "com.rferegrino.tmux-switcher"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let ax = Logger(subsystem: subsystem, category: "accessibility")
    static let state = Logger(subsystem: subsystem, category: "state")
    static let ipc = Logger(subsystem: subsystem, category: "ipc")
    static let tmux = Logger(subsystem: subsystem, category: "tmux")
}

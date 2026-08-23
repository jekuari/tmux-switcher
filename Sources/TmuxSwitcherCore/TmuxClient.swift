import Foundation

public enum TmuxClient {
    /// Parse the output of `tmux list-sessions -F "#{session_name}"`.
    /// Split on newlines, trim each line, drop empty lines, preserve order.
    /// Pure function.
    public static func parseSessionList(_ output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var sessions: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                sessions.append(trimmed)
            }
        }

        return sessions
    }

    /// Run `tmux list-sessions -F "#{session_name}"` and return the parsed list.
    ///
    /// Returns [] on launch failure (tmux missing), non-zero exit (no server
    /// running), or timeout. Never throws.
    ///
    /// The read/wait ordering matters: we drain the pipe to EOF *before* waiting
    /// for exit. Waiting first would deadlock any child that filled the 64KB pipe
    /// buffer — it blocks on write while we block on its exit. A watchdog handles
    /// a genuinely hung tmux; terminating it closes the pipe, which is what
    /// unblocks the read.
    public static func listSessions(tmuxBin: String, timeout: TimeInterval) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBin)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // suppress "no server running" chatter

        do {
            try process.run()
        } catch {
            return []
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // A terminated (timed-out) process also lands here with non-zero status.
        guard process.terminationStatus == 0 else { return [] }

        return parseSessionList(String(data: data, encoding: .utf8) ?? "")
    }
}

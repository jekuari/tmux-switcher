import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One-shot client used to notify the running agent of a tmux event.
///
/// This is invoked from a tmux hook script on every session create/close/rename, so it
/// must be fast, silent, and utterly unable to disrupt tmux. Concretely:
///
/// - If the agent isn't running, the socket file won't exist and `connect()` fails
///   immediately; we return `false` with no output, so the calling hook can exit 0.
/// - We bound send/connect time with `SO_SNDTIMEO` (~250ms) so a wedged or
///   half-dead server can never make a tmux hook hang.
/// - We disable `SIGPIPE` delivery for writes on this socket (`SO_NOSIGPIPE`), because
///   writing to a socket whose peer has closed would otherwise raise SIGPIPE and kill
///   the whole process (tmux's hook-running process) rather than just failing the call.
enum NotifyClient {
    private static let timeoutMs: Int32 = 250

    @discardableResult
    static func send(_ command: String, socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        applyTimeout(fd)
        disableSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                buf[i] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return false }

        let payload = Array((command + "\n").utf8)
        let sent = payload.withUnsafeBytes { ptr -> Int in
            // MSG_NOSIGNAL belt-and-suspenders alongside SO_NOSIGPIPE: on Darwin
            // MSG_NOSIGNAL isn't defined for send(2), so SO_NOSIGPIPE (set above)
            // is what actually suppresses SIGPIPE here. Qualified as `Darwin.send`
            // to disambiguate from `NotifyClient.send(_:socketPath:)` in this scope.
            Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
        }

        return sent == payload.count
    }

    // MARK: - Socket options

    private static func applyTimeout(_ fd: Int32) {
        var tv = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(timeoutMs) * 1000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func disableSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

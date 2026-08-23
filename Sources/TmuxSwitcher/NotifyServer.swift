import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum NotifyServerError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case directoryCreationFailed(path: String, underlying: Error)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case pathTooLong(path: String)

    var description: String {
        switch self {
        case .socketCreationFailed(let e):
            return "NotifyServer: socket() failed (errno \(e): \(String(cString: strerror(e))))"
        case .directoryCreationFailed(let path, let underlying):
            return "NotifyServer: could not create directory for \(path): \(underlying)"
        case .bindFailed(let path, let e):
            return "NotifyServer: bind(\(path)) failed (errno \(e): \(String(cString: strerror(e))))"
        case .listenFailed(let e):
            return "NotifyServer: listen() failed (errno \(e): \(String(cString: strerror(e))))"
        case .pathTooLong(let path):
            return "NotifyServer: socket path too long for sockaddr_un: \(path)"
        }
    }
}

/// A Unix-domain socket server that receives newline-delimited text commands from
/// short-lived clients (in practice, `tmux` hook scripts invoking `NotifyClient`).
@MainActor
final class NotifyServer {
    var onCommand: ((String) -> Void)?

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.tmux-switcher.notify-server")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        guard listenFD < 0 else { return } // already started

        let directory = (socketPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw NotifyServerError.directoryCreationFailed(path: directory, underlying: error)
            }
        }

        // A stale socket file left behind by a previous crash still occupies the path,
        // which makes bind() fail with EADDRINUSE even though nothing is listening.
        // Unlinking first is safe: if another instance really is live on this path,
        // its listening fd is unaffected by removing the directory entry, and our own
        // bind() will simply create a fresh entry.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NotifyServerError.socketCreationFailed(errno: errno)
        }

        setCloseOnExec(fd)
        setReuseAddr(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NotifyServerError.pathTooLong(path: socketPath)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                buf[i] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw NotifyServerError.bindFailed(path: socketPath, errno: e)
        }

        // Only this user should be able to talk to the agent over this socket.
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw NotifyServerError.listenFailed(errno: e)
        }

        listenFD = fd

        // The event handler runs on `queue` (a background queue), not on the main
        // actor. It captures `fd` by value and calls into a free function (below)
        // that touches no actor-isolated state, so no isolation hop is needed for
        // the accept()/read() work itself. Only delivering a parsed line back to
        // `onCommand` needs to hop to the main actor, which it does via `Task`.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            acceptAndReadCommands(listenFD: fd) { line in
                Task { @MainActor in
                    self?.onCommand?(line)
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        guard listenFD >= 0 else { return } // already stopped: idempotent
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(socketPath)
    }
}

// MARK: - Free functions (no actor isolation; safe to call from the background queue)

/// Maximum bytes accepted for a single line before the connection is dropped as abusive.
private let maxNotifyLineBytes = 1024

/// Accepts one pending connection on `listenFD`, reads newline-delimited lines from it
/// to completion, invokes `onLine` for each complete, non-empty, trimmed line, and always
/// closes the accepted fd — leaking fds in a long-running background agent would
/// eventually exhaust the process's descriptor limit.
private func acceptAndReadCommands(listenFD: Int32, onLine: @escaping (String) -> Void) {
    let clientFD = accept(listenFD, nil, nil)
    guard clientFD >= 0 else { return }
    defer { close(clientFD) }
    setCloseOnExec(clientFD)

    var buffer = [UInt8]()
    buffer.reserveCapacity(256)
    var readBuf = [UInt8](repeating: 0, count: 512)
    var dropped = false

    while true {
        let n = readBuf.withUnsafeMutableBytes { ptr -> Int in
            read(clientFD, ptr.baseAddress, ptr.count)
        }
        if n <= 0 {
            break
        }
        for i in 0..<n {
            let byte = readBuf[i]
            if byte == UInt8(ascii: "\n") {
                if !dropped, let line = String(bytes: buffer, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onLine(trimmed)
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                dropped = false
            } else if buffer.count < maxNotifyLineBytes {
                buffer.append(byte)
            } else {
                // Line exceeded the cap: mark for drop, but keep draining the socket
                // so the client's write can complete instead of hanging on a full pipe.
                dropped = true
            }
        }
    }
}

private func setCloseOnExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD)
    guard flags >= 0 else { return }
    _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
}

private func setReuseAddr(_ fd: Int32) {
    var value: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))
}

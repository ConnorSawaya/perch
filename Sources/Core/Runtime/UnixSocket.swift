// UnixSocket.swift — the handful of POSIX socket calls the hook server needs, wrapped up so the
// rest of the runtime code reads like ordinary Swift.
//
// A Unix socket is a file on disk (PerchPaths.socketURL) that two programs on the same Mac use
// to talk to each other. Nothing here touches the network.

import Foundation

enum UnixSocket {
    /// Which file on disk a socket is: lets the server check that the file at its path is still
    /// the one it created, and not a replacement made by someone else.
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// The system keeps a socket's path in a fixed-size field: 104 bytes including the ending zero.
    static var maxPathBytes: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

    static func pathFits(_ path: String) -> Bool {
        let length = path.utf8.count
        return length > 0 && length <= maxPathBytes
    }

    /// The identity of the socket file at `path`. Nil when nothing is there or it is not a socket.
    static func identity(at path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// True when some program is listening on the socket file at `path` right now. A socket file
    /// left behind by a crash refuses the connection, which is how stale files are told apart.
    static func isAnswering(at path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return withAddress(for: path) { Darwin.connect(descriptor, $0, $1) } == 0
    }

    /// Creates the socket file at `path` (which must not exist), readable and writable by the
    /// current user only, and starts listening. Returns the listening descriptor.
    static func listen(at path: String, backlog: Int32) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HookServerError.system(step: "create the socket", code: errno) }
        /// Undoes everything on failure, keeping the error code of the step that failed.
        func fail(_ step: String, removeFile: Bool) -> HookServerError {
            let code = errno
            close(descriptor)
            if removeFile { unlink(path) }
            return .system(step: step, code: code)
        }
        guard withAddress(for: path, { Darwin.bind(descriptor, $0, $1) }) == 0 else {
            throw fail("bind the socket", removeFile: false)
        }
        guard chmod(path, 0o600) == 0 else { throw fail("protect the socket file", removeFile: true) }
        guard Darwin.listen(descriptor, backlog) == 0 else { throw fail("listen on the socket", removeFile: true) }
        makeNonBlocking(descriptor)
        closeOnExec(descriptor)
        return descriptor
    }

    /// Settings for a freshly accepted connection.
    static func prepareConnection(_ descriptor: Int32) {
        makeNonBlocking(descriptor)
        closeOnExec(descriptor)
        // Writing to a helper that has already quit must return an error, not send SIGPIPE to the app.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data` to a non-blocking socket, waiting whenever the other side is not ready
    /// for more. Returns false on an error or when `timeout` seconds pass.
    @discardableResult
    static func sendAll(_ data: Data, to descriptor: Int32, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        return data.withUnsafeBytes { bytes -> Bool in
            guard let start = bytes.baseAddress else { return true }   // nothing to send
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, start + sent, bytes.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0 && errno == EAGAIN {
                    let now = DispatchTime.now()
                    guard now < deadline else { return false }
                    let milliseconds = (deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000 + 1
                    var watch = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    if poll(&watch, 1, Int32(min(milliseconds, 1000))) < 0 && errno != EINTR { return false }
                } else if !(count < 0 && errno == EINTR) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Details

    private static func makeNonBlocking(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    /// Keeps the descriptor out of any program the app starts later (osascript, git...).
    private static func closeOnExec(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    /// Builds the address structure for `path` and hands it to `body` in the form the socket calls want.
    /// Returns -1 without calling `body` when the path does not fit.
    private static func withAddress(for path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        guard pathFits(path) else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

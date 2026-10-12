// HookServerError.swift — the reasons HookServer.start() can fail, in plain English.

import Foundation

enum HookServerError: Error, Equatable, LocalizedError {
    /// Another copy of Perch is already listening on the socket.
    case alreadyRunning(path: String)
    /// The socket's path is longer than the system allows (the limit is in bytes).
    case pathTooLong(path: String, limit: Int)
    /// A file or folder that is not a socket sits where the socket should go. It is left alone.
    case pathOccupied(path: String)
    /// A system call failed. `code` is the errno value.
    case system(step: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let path):
            return "Another copy of Perch is already listening at \(path)."
        case .pathTooLong(let path, let limit):
            return "The socket path is too long (\(path.utf8.count) bytes; the system allows \(limit)): \(path)"
        case .pathOccupied(let path):
            return "Something that is not a socket is in the way at \(path). Move or delete it and try again."
        case .system(let step, let code):
            return "Could not \(step): \(String(cString: strerror(code))) (error \(code))."
        }
    }
}

// HookReplyHandle.swift — what the app holds while a helper is waiting for an answer.
//
// The session engine keeps one of these for every request card. Calling `reply` sends the
// decision to the waiting `perch-hook` process (which prints it for the agent); `close` lets the
// helper go without an answer, so the agent falls back to its own prompt.
//
// Rules this class guarantees:
//   - the first `reply` or `close` wins; later calls do nothing;
//   - `onDisconnect` is called at most once, on the main thread, and only if the helper went
//     away before `reply` / `close` (it also fires if it is set after the helper already left);
//   - if the app drops the handle without answering, the helper is let go rather than left hanging.
//
// It may be used from any thread; the small lock below protects its three pieces of state.

import Foundation

final class HookReplyHandle: ReplyHandle {
    let id = UUID()

    private let connection: HookConnection
    /// The server's queue, where all work on the connection has to happen.
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// True once `reply` or `close` was called, or the disconnect was reported. Nothing happens after that.
    private var isFinished = false
    private var peerIsGone = false
    private var disconnectCallback: (() -> Void)?

    init(connection: HookConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    deinit {
        // Forgotten without an answer: hang up so the helper exits and the agent carries on.
        if !isFinished { hangUp() }
    }

    var onDisconnect: (() -> Void)? {
        get { lock.withLock { disconnectCallback } }
        set {
            let alreadyGone: Bool = lock.withLock {
                disconnectCallback = isFinished ? nil : newValue
                return peerIsGone && disconnectCallback != nil
            }
            // The helper left before anyone was listening for it: say so now.
            if alreadyGone { DispatchQueue.main.async { self.reportDisconnect() } }
        }
    }

    func reply(_ reply: HookReply) {
        guard finish() else { return }
        guard var line = try? JSONEncoder().encode(reply) else {
            hangUp()
            return
        }
        line.append(0x0A)
        queue.async { [connection] in connection.sendAndClose(line) }
    }

    func close() {
        guard finish() else { return }
        hangUp()
    }

    /// Called by the server (on its queue) when the helper disconnected, or the server stopped,
    /// before a reply was sent.
    func peerDisconnected() {
        lock.withLock { peerIsGone = true }
        DispatchQueue.main.async { self.reportDisconnect() }
    }

    // MARK: - Details

    /// Marks the handle as used. Returns false if it already was.
    private func finish() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            disconnectCallback = nil
            return true
        }
    }

    private func hangUp() {
        queue.async { [connection] in connection.close() }
    }

    /// Runs on the main thread. Calls `onDisconnect` unless it was already called, the app
    /// answered in the meantime, or nobody has asked to be told yet.
    private func reportDisconnect() {
        let callback: (() -> Void)? = lock.withLock {
            guard peerIsGone, !isFinished, let callback = disconnectCallback else { return nil }
            isFinished = true
            disconnectCallback = nil
            return callback
        }
        callback?()
    }
}

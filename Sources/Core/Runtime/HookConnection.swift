// HookConnection.swift — one `perch-hook` helper process connected to the server.
//
// Life of a connection:
//   1. readingLine      the helper is sending its one line of JSON; bytes are collected until the
//                       newline arrives, then `onLine` is called with the line.
//   2. waitingForReply  the line has arrived. The server either hangs up at once (nothing to
//                       answer) or keeps the helper waiting. Meanwhile the socket is still
//                       watched: if the helper goes away first (the user answered in the
//                       terminal, the agent quit), `onPeerClosed` is called.
//   3. closed           finished, one way or another.
//
// Everything in this class runs on the server's private queue, so it needs no locks. The app
// never sees this class; it talks to a HookReplyHandle, which forwards to the queue.

import Foundation

final class HookConnection {
    private enum Phase { case readingLine, waitingForReply, closed }

    /// The helper's line arrived (without its newline). Called at most once. The receiver must
    /// call `close()` straight away unless it wants to keep the helper waiting for a reply.
    var onLine: ((Data) -> Void)?
    /// The helper went away while it was waiting for a reply. Called at most once.
    var onPeerClosed: (() -> Void)?
    /// The connection is finished; the server uses this to forget it. Called exactly once.
    var onClosed: (() -> Void)?

    /// How long a reply may take to reach a helper that is slow to read it.
    private static let replyTimeout: TimeInterval = 5

    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let maxLineBytes: Int
    private var phase = Phase.readingLine
    private var buffer = Data()

    /// True from the moment the helper's line has arrived until the connection is closed.
    var isWaitingForReply: Bool { phase == .waitingForReply }

    /// Takes ownership of `descriptor` (an accepted, non-blocking socket). Must be called on
    /// `queue`; the callbacks above can be set right after, before the queue runs anything else.
    init(descriptor: Int32, queue: DispatchQueue, maxLineBytes: Int, firstLineTimeout: TimeInterval) {
        self.descriptor = descriptor
        self.maxLineBytes = maxLineBytes
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailableBytes() }
        // The descriptor is closed only here, once the source has let go of it for good.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        // A program that connects and then says nothing must not hold a descriptor forever.
        queue.asyncAfter(deadline: .now() + firstLineTimeout) { [weak self] in
            guard let self, self.phase == .readingLine else { return }
            Log.debug("dropped a connection that sent no complete message in \(firstLineTimeout) s", "runtime")
            self.close()
        }
    }

    deinit {
        // Normally closed long before this; cancelling is what releases the descriptor.
        source.cancel()
    }

    /// Hangs up quietly. Safe to call more than once.
    func close() {
        guard phase != .closed else { return }
        phase = .closed
        buffer = Data()
        source.cancel()
        let closed = onClosed
        onLine = nil
        onPeerClosed = nil
        onClosed = nil
        closed?()
    }

    /// Hangs up and, if the helper was waiting for a reply, reports that it is gone.
    /// Used when the helper disconnects and when the server shuts down.
    func closeReportingDisconnect() {
        let peerClosed = phase == .waitingForReply ? onPeerClosed : nil
        close()
        peerClosed?()
    }

    /// Sends the reply line to a waiting helper, then hangs up.
    func sendAndClose(_ data: Data) {
        guard phase == .waitingForReply else { return }
        // Writing can stall if the helper is slow to read, so it happens on a background thread
        // using its own duplicate of the descriptor. The connection itself is finished right now,
        // which keeps the server's queue free for other helpers.
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            // No descriptor to spare. Send from here after all: a brief stall beats a lost answer.
            UnixSocket.sendAll(data, to: descriptor, timeout: 1)
            close()
            return
        }
        close()
        DispatchQueue.global(qos: .userInitiated).async {
            UnixSocket.sendAll(data, to: duplicate, timeout: HookConnection.replyTimeout)
            Darwin.close(duplicate)
        }
    }

    // MARK: - Reading

    /// Called by the queue whenever the socket has bytes to read or the helper has hung up.
    private func readAvailableBytes() {
        guard phase != .closed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        if count > 0 {
            // Anything a helper sends after its one line is ignored.
            if phase == .readingLine { chunk.withUnsafeBufferPointer { collect($0.baseAddress, count: count) } }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // End of file, or the connection broke: the helper is gone.
            if phase == .readingLine, !buffer.isEmpty {
                Log.debug("a helper disconnected in the middle of a message (\(buffer.count) bytes received)", "runtime")
            }
            closeReportingDisconnect()
        }
    }

    /// Adds freshly read bytes to the line. (Plain C calls on purpose: they are just as fast in a
    /// debug build of the app, where a megabyte-sized payload would otherwise take a long time.)
    private func collect(_ bytes: UnsafePointer<UInt8>?, count: Int) {
        guard let bytes else { return }
        let newline = memchr(bytes, 0x0A, count)
        let lineBytes = newline.map { UnsafeRawPointer($0) - UnsafeRawPointer(bytes) } ?? count
        buffer.append(bytes, count: lineBytes)
        guard buffer.count <= maxLineBytes else {
            Log.debug("dropped a message longer than \(maxLineBytes) bytes", "runtime")
            close()
            return
        }
        guard newline != nil else { return }   // the rest of the line is still on its way
        phase = .waitingForReply
        let line = buffer
        buffer = Data()
        onLine?(line)
    }
}

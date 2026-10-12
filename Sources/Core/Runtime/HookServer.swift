// HookServer.swift — the app's end of the Unix socket that `perch-hook` talks to.
//
// How it works:
//   - `start()` creates the socket file (PerchPaths.socketURL) and listens on it.
//   - Each time a helper connects, a HookConnection collects its one line of JSON.
//   - The line is decoded into a HookEnvelope and handed to `onEnvelope` on the main thread.
//   - If the helper asked to wait (`wantsReply`), the connection stays open and the envelope
//     arrives together with a ReplyHandle. Whoever receives it answers later with `reply`, or
//     lets the helper go with `close`.
//
// All socket work happens on one private serial queue, so this class needs no locks. The only
// things that happen on the main thread are the `onEnvelope` and `onDisconnect` callbacks.
//
// If anything looks wrong with a connection it is simply dropped: the helper then exits quietly
// and the agent carries on as if Perch were not there.

import Foundation

final class HookServer: HookServing {
    /// Called on the main thread for every envelope. Set it (on the main thread) before `start()`.
    var onEnvelope: ((HookEnvelope, ReplyHandle?) -> Void)?

    /// Longest message accepted, in bytes. HookClient.maxLineBytes in the helper is the same number.
    static let maxLineBytes = 8 * 1024 * 1024
    /// Each connected helper uses one of the app's file descriptors (an app has about 256), so
    /// only this many are let in at a time. Others queue up in the system until there is room.
    static let maxConnections = 128
    /// How many helpers may sit waiting for an answer at once. Further ones are turned away (their
    /// agents ask in the terminal instead), which keeps room for ordinary events to flow.
    static let maxWaitingHelpers = 96
    /// How many helpers the system may queue while the server is busy or full.
    private static let listenBacklog: Int32 = 64
    /// The envelope format this build understands (HookEnvelope.v).
    private static let protocolVersion = HookEnvelope(agent: "").v

    private let socketURL: URL
    private let firstLineTimeout: TimeInterval
    private let queue = DispatchQueue(label: "local.perch.hook-server")
    /// Marks code that is already running on `queue` (see `onQueue`).
    private let queueMarker = DispatchSpecificKey<Bool>()
    private let decoder = JSONDecoder()

    // Everything below is touched only on `queue`.
    private var listener: DispatchSourceRead?
    /// True while no new helpers are being let in (see `pauseListener`).
    private var listenerIsPaused = false
    /// The socket file this server created, so it never deletes one that belongs to someone else.
    private var boundSocket: UnixSocket.FileIdentity?
    private var connections: [ObjectIdentifier: HookConnection] = [:]
    /// Keeps "the waiting room is full" out of the log after the first time it is said.
    private var waitingRoomIsFull = false

    /// `firstLineTimeout`: how long a helper may take to send its message before it is dropped.
    init(socketURL: URL = PerchPaths.socketURL, firstLineTimeout: TimeInterval = 10) {
        self.socketURL = socketURL
        self.firstLineTimeout = firstLineTimeout
        queue.setSpecific(key: queueMarker, value: true)
    }

    deinit { stop() }

    // MARK: - HookServing

    /// True while helpers can actually reach the server: it is listening, and the socket file on
    /// disk is still the one it created (not deleted or replaced behind its back).
    var isRunning: Bool {
        onQueue { listener != nil && socketFileIsOurs }
    }

    /// Starts listening. Does nothing if already running; if the socket file went missing while
    /// the server was running, starts afresh (helpers that were waiting are let go). Throws a
    /// HookServerError when it cannot listen, or a file error when the socket's folder cannot be made.
    func start() throws {
        try onQueue {
            if listener != nil {
                if socketFileIsOurs { return }
                shutDown()
            }
            let path = socketURL.path
            guard UnixSocket.pathFits(path) else {
                throw HookServerError.pathTooLong(path: path, limit: UnixSocket.maxPathBytes)
            }
            try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try removeStaleSocket(at: path)
            let descriptor = try UnixSocket.listen(at: path, backlog: Self.listenBacklog)
            boundSocket = UnixSocket.identity(at: path)

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptWaitingHelpers(on: descriptor) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            listener = source
            Log.info("listening for agents at \(path)", "runtime")
        }
    }

    /// Stops listening, hangs up on every helper (they exit quietly, so their agents fall back to
    /// their own prompts) and removes the socket file. Handles still waiting get `onDisconnect`.
    func stop() {
        onQueue { shutDown() }
    }

    /// How many helpers are connected right now (nearly always: waiting for an answer). For diagnostics.
    var connectionCount: Int {
        onQueue { connections.count }
    }

    // MARK: - Starting and stopping (on the queue)

    private var socketFileIsOurs: Bool {
        boundSocket != nil && UnixSocket.identity(at: socketURL.path) == boundSocket
    }

    /// Makes room for our socket file. A leftover from a crash is deleted; a socket that another
    /// running copy of Perch is listening on is an error, and so is anything that is not a socket.
    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }   // nothing in the way
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw HookServerError.pathOccupied(path: path) }
        if UnixSocket.isAnswering(at: path) { throw HookServerError.alreadyRunning(path: path) }
        unlink(path)
    }

    private func shutDown() {
        guard let source = listener else { return }
        resumeListener()   // a suspended source never finishes cancelling, so wake it first
        listener = nil
        source.cancel()
        for connection in Array(connections.values) { connection.closeReportingDisconnect() }
        connections.removeAll()
        if socketFileIsOurs { unlink(socketURL.path) }
        boundSocket = nil
        waitingRoomIsFull = false
        Log.info("stopped listening for agents", "runtime")
    }

    // MARK: - Accepting helpers (on the queue)

    private func acceptWaitingHelpers(on listeningDescriptor: Int32) {
        while listener != nil {
            // Full house: newcomers stay queued in the system until a connection ends (see `adopt`).
            guard connections.count < Self.maxConnections else {
                pauseListener()
                return
            }
            let descriptor = accept(listeningDescriptor, nil, nil)
            if descriptor < 0 {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code != EAGAIN { holdOff(afterError: code) }
                return   // EAGAIN: everyone who was queued has been let in
            }
            UnixSocket.prepareConnection(descriptor)
            adopt(descriptor)
        }
    }

    private func adopt(_ descriptor: Int32) {
        let connection = HookConnection(descriptor: descriptor, queue: queue, maxLineBytes: Self.maxLineBytes,
                                        firstLineTimeout: firstLineTimeout)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onLine = { [weak self, weak connection] line in
            guard let self, let connection else { return }
            self.receive(line, from: connection)
        }
        connection.onClosed = { [weak self] in
            self?.connections[key] = nil
            self?.resumeListener()   // there is room (and a spare file descriptor) again
        }
    }

    /// `accept` failed for a reason that will not go away in the next instant (usually the app has
    /// run out of file descriptors). macOS has already thrown away the helper that could not be let
    /// in; rather than lose every other queued helper the same way, hold off for a moment.
    private func holdOff(afterError code: Int32) {
        Log.error("could not let a helper in: \(String(cString: strerror(code))); trying again shortly", "runtime")
        pauseListener()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resumeListener() }
    }

    /// Stops letting helpers in. They are not refused: the system keeps them queued.
    private func pauseListener() {
        guard let listener, !listenerIsPaused else { return }
        listenerIsPaused = true
        listener.suspend()
    }

    private func resumeListener() {
        guard let listener, listenerIsPaused else { return }
        listenerIsPaused = false
        listener.resume()
    }

    // MARK: - Messages (on the queue)

    private func receive(_ line: Data, from connection: HookConnection) {
        guard let envelope = try? decoder.decode(HookEnvelope.self, from: line), envelope.v == Self.protocolVersion else {
            Log.debug("ignored a message that is not a version \(Self.protocolVersion) envelope (\(line.count) bytes)", "runtime")
            connection.close()
            return
        }
        guard envelope.wantsReply else {
            connection.close()
            deliver(envelope, handle: nil)
            return
        }
        // This connection already counts as waiting, hence "more than" rather than "as many as".
        guard connections.values.filter({ $0.isWaitingForReply }).count <= Self.maxWaitingHelpers else {
            if !waitingRoomIsFull {
                waitingRoomIsFull = true
                Log.error("\(Self.maxWaitingHelpers) helpers are already waiting for answers; turning further ones away", "runtime")
            }
            connection.close()
            return
        }
        waitingRoomIsFull = false
        let handle = HookReplyHandle(connection: connection, queue: queue)
        connection.onPeerClosed = { [weak handle] in handle?.peerDisconnected() }
        deliver(envelope, handle: handle)
    }

    private func deliver(_ envelope: HookEnvelope, handle: HookReplyHandle?) {
        DispatchQueue.main.async { [weak self] in
            // If nobody takes the handle it is released right here, and a released handle hangs
            // up, so a helper is never left waiting for an app that is not listening.
            self?.onEnvelope?(envelope, handle)
        }
    }

    // MARK: - Queue helper

    /// Runs `body` on the server's queue and waits for it. Safe to call from the queue itself.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueMarker) == true { return try body() }
        return try queue.sync(execute: body)
    }
}

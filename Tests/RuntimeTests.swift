// RuntimeTests.swift — checks the plumbing between agents and the app.
//
// Four parts, in this order:
//   1. HookServer + HookReplyHandle   (the app's socket server), driven by a bare POSIX client
//   2. HelperInstaller                (copies the helper to its fixed place)
//   3. HookClient                     (the helper's own functions, compiled into this test)
//   4. the real `perch-hook` program  (built with scripts/build-helper.sh and run as a child process)
//
// Nothing real is touched: PERCH_HOME points every PerchPaths location at a temporary folder,
// and every child process started here is gone again before the tests finish.
//
// Run with: scripts/test.sh Runtime Sources/Core/Runtime Sources/Helper/HookClient.swift

import Foundation

func runRuntimeTests(_ t: TestRunner) {
    let home = RuntimeTestHome()
    defer {
        settle(t, 0.2)             // let the last log lines be written before their folder goes
        home.remove()
    }
    signal(SIGPIPE, SIG_IGN)       // the test client writes to sockets the server has closed on purpose
    raiseDescriptorLimit()
    // The tests may themselves be started from a terminal or by a coding agent, which sets some of
    // the variables the helper forwards (TERM_PROGRAM, CLAUDE_PID...). Start from a clean slate.
    for name in HookEnvelope.forwardedEnvKeys { unsetenv(name) }
    Log.debugEnabled = true        // so the logging lines in the code under test are exercised too

    t.test("PERCH_HOME moves every Perch path into the temporary folder") {
        t.expectEqual(PerchPaths.supportDir.path, home.url.path)
        t.expect(PerchPaths.socketURL.path.hasPrefix(home.url.path))
        t.expect(PerchPaths.helperURL.path.hasPrefix(home.url.path))
        t.expect(UnixSocket.pathFits(PerchPaths.socketURL.path), "the test socket path must fit in a socket address")
    }

    runServerTests(t, home)
    runInstallerTests(t, home)
    runClientTests(t, home)
    runHelperProgramTests(t, home)
    ChildProcesses.killAll()
}

// MARK: - 1. HookServer

private func runServerTests(_ t: TestRunner, _ home: RuntimeTestHome) {
    // One full cycle first, so that anything the system opens once and keeps (dispatch's own
    // descriptors, for instance) is already open when the starting count is taken.
    try? withServer(t, home) { _, inbox, socketURL in
        let client = TestClient(socketURL)
        _ = client?.send(testEnvelope("warm-up", wantsReply: true))
        t.wait { inbox.count == 1 }
        (inbox.handles.first ?? nil)?.reply(.passthrough)
        _ = client?.readLine(timeout: 1)
    }
    settle(t, 0.2)
    let descriptorsAtStart = openDescriptorCount()

    t.test("start creates a private socket file; stop removes it") {
        let socketURL = home.url.appendingPathComponent("made-on-demand/a.sock")
        let server = HookServer(socketURL: socketURL)
        t.expect(!server.isRunning)
        try server.start()
        t.expect(server.isRunning)
        t.expectEqual(fileMode(socketURL.path), S_IFSOCK | 0o600, "socket file: owner read/write only")
        t.expectEqual(fileMode(socketURL.deletingLastPathComponent().path), S_IFDIR | 0o700, "new parent folder: owner only")
        try server.start()   // a second start is harmless
        t.expect(server.isRunning)
        server.stop()
        t.expect(!server.isRunning)
        t.expect(!FileManager.default.fileExists(atPath: socketURL.path), "stop removes the socket file")
        server.stop()        // and so is a second stop
        try server.start()   // and it can be started again
        t.expect(server.isRunning)
        server.stop()
    }

    t.test("fire-and-forget: the envelope arrives on the main thread with no handle") {
        try withServer(t, home) { server, inbox, socketURL in
            var sent = testEnvelope("PreToolUse", payload: "{\"text\":\"line1\\nline2\",\"emoji\":\"🐦\"}\n")
            sent.env = ["TERM_PROGRAM": "Apple_Terminal"]
            sent.args = ["one", "two words"]
            sent.tty = "/dev/ttys003"
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(sent))
            t.expect(t.wait { inbox.count == 1 }, "delivered")
            t.expectEqual(inbox.envelopes.first, sent)
            t.expect(inbox.handles.first.map { $0 == nil } ?? false, "no handle for fire-and-forget")
            t.expectEqual(inbox.deliveredOffMain, 0)
            t.expect(t.wait { client.serverHungUp }, "the server closes straight away")
            t.expect(t.wait { server.connectionCount == 0 })
        }
    }

    t.test("blocking round trip: the reply reaches the waiting client as one line") {
        try withServer(t, home) { server, inbox, socketURL in
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let handle = try t.unwrap(inbox.handles.first ?? nil, "a waiting envelope comes with a handle")
            t.expectEqual(inbox.envelopes.first?.wantsReply, true)
            t.expectEqual(server.connectionCount, 1, "the connection is held open")
            let reply = HookReply(stdout: "{\"decision\":\"allow\",\"note\":\"two\\nlines ✓\"}", exitCode: 3)
            handle.reply(reply)
            let line = try t.unwrap(client.readLine(timeout: 3), "reply line")
            t.expectEqual(try JSONDecoder().decode(HookReply.self, from: Data(line.utf8)), reply)
            t.expect(t.wait { client.serverHungUp }, "closed after the reply")
            t.expect(t.wait { server.connectionCount == 0 })
        }
    }

    t.test("a reply sent after a delay still arrives") {
        try withServer(t, home) { _, inbox, socketURL in
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("AskUserQuestion", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let handle = try t.unwrap(inbox.handles.first ?? nil)
            let started = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { handle.reply(HookReply(stdout: "late", exitCode: 0)) }
            settle(t, 0.2)
            t.expect(!client.serverHungUp, "still connected while the app is thinking")
            t.expect(t.wait(3) { client.hasBytes })
            t.expect(Date().timeIntervalSince(started) >= 0.35, "the reply was not sent early")
            let line = try t.unwrap(client.readLine(timeout: 1))
            t.expectEqual(try JSONDecoder().decode(HookReply.self, from: Data(line.utf8)).stdout, "late")
        }
    }

    t.test("client disconnects before the reply: onDisconnect fires once, on the main thread") {
        try withServer(t, home) { server, inbox, socketURL in
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let handle = try t.unwrap(inbox.handles.first ?? nil)
            var disconnects = 0
            var onMain = false
            handle.onDisconnect = { disconnects += 1; onMain = Thread.isMainThread }
            settle(t, 0.1)
            t.expectEqual(disconnects, 0, "nothing fires while the client is still there")
            client.close()
            t.expect(t.wait { disconnects == 1 }, "onDisconnect fired")
            t.expect(onMain, "on the main thread")
            handle.reply(.passthrough)   // too late: must be harmless
            handle.close()
            settle(t, 0.15)
            t.expectEqual(disconnects, 1, "exactly once")
            t.expectEqual(server.connectionCount, 0)
        }
    }

    t.test("onDisconnect set after the client already left still fires (once)") {
        try withServer(t, home) { server, inbox, socketURL in
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let handle = try t.unwrap(inbox.handles.first ?? nil)
            client.close()
            t.expect(t.wait { server.connectionCount == 0 }, "the server noticed")
            settle(t, 0.05)
            var disconnects = 0
            handle.onDisconnect = { disconnects += 1 }
            t.expect(t.wait { disconnects == 1 })
            handle.onDisconnect = { disconnects += 1 }
            settle(t, 0.1)
            t.expectEqual(disconnects, 1)
        }
    }

    t.test("reply and close are idempotent, and onDisconnect stays quiet after either") {
        try withServer(t, home) { _, inbox, socketURL in
            // reply, reply, close -> exactly one line
            let first = try t.unwrap(TestClient(socketURL))
            t.expect(first.send(testEnvelope("one", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let firstHandle = try t.unwrap(inbox.handles[0])
            var disconnects = 0
            firstHandle.onDisconnect = { disconnects += 1 }
            firstHandle.reply(HookReply(stdout: "first", exitCode: 0))
            firstHandle.reply(HookReply(stdout: "second", exitCode: 1))
            firstHandle.close()
            t.expectNil(firstHandle.onDisconnect.map { _ in "still set" }, "the callback is released once the handle is used")
            let line = try t.unwrap(first.readLine(timeout: 3))
            t.expectEqual(try JSONDecoder().decode(HookReply.self, from: Data(line.utf8)).stdout, "first")
            t.expect(t.wait { first.serverHungUp }, "nothing after the first reply")
            first.close()

            // close, close, reply -> nothing at all
            let second = try t.unwrap(TestClient(socketURL))
            t.expect(second.send(testEnvelope("two", wantsReply: true)))
            t.expect(t.wait { inbox.count == 2 })
            let secondHandle = try t.unwrap(inbox.handles[1])
            secondHandle.onDisconnect = { disconnects += 1 }
            secondHandle.close()
            secondHandle.close()
            secondHandle.reply(HookReply(stdout: "never", exitCode: 0))
            t.expect(t.wait { second.serverHungUp }, "closed with no reply bytes")
            second.close()
            settle(t, 0.2)
            t.expectEqual(disconnects, 0, "onDisconnect must not fire after reply or close")
            t.expect(firstHandle.id != secondHandle.id)
        }
    }

    t.test("a handle nobody keeps lets the helper go") {
        let socketURL = home.socketURL()
        let server = HookServer(socketURL: socketURL)
        var seen = 0
        server.onEnvelope = { _, _ in seen += 1 }   // takes the envelope, drops the handle
        try server.start()
        let client = try t.unwrap(TestClient(socketURL))
        t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
        t.expect(t.wait { client.serverHungUp }, "hung up when the handle was released")
        t.expectEqual(seen, 1)

        server.onEnvelope = nil                     // nobody listening at all
        let other = try t.unwrap(TestClient(socketURL))
        t.expect(other.send(testEnvelope("PermissionRequest", wantsReply: true)))
        t.expect(t.wait { other.serverHungUp }, "hung up when there is no onEnvelope")
        server.stop()
    }

    t.test("malformed input is dropped without disturbing the server") {
        try withServer(t, home) { server, inbox, socketURL in
            var future = testEnvelope("FromTheFuture")
            future.v = 99
            let futureLine = String(decoding: try JSONEncoder().encode(future), as: UTF8.self) + "\n"
            let badLines = ["this is not json\n", "\n", "{}\n", "{\"agent\":\"claude\"}\n", "[1,2,3]\n", "\u{0}\u{1}\u{2}\n", futureLine]
            for text in badLines {
                let client = try t.unwrap(TestClient(socketURL))
                t.expect(client.send(Data(text.utf8)))
                t.expect(t.wait { client.serverHungUp }, "dropped: \(text.debugDescription)")
            }
            // A message cut off in the middle (the helper was killed while writing).
            let partial = try t.unwrap(TestClient(socketURL))
            t.expect(partial.send(Data("{\"agent\":\"claude\",\"chan".utf8)))
            settle(t, 0.05)
            partial.close()
            // A client that connects and leaves without a word (this is what a liveness probe looks like).
            try t.unwrap(TestClient(socketURL)).close()
            settle(t, 0.15)   // long enough for the last two to be accepted and dropped
            t.expect(t.wait { server.connectionCount == 0 }, "no connection is left over")
            t.expectEqual(inbox.count, 0, "none of that reached the app")

            // Only the first line counts; anything after it is ignored.
            let chatty = try t.unwrap(TestClient(socketURL))
            let good = testEnvelope("Stop")
            var twoLines = try JSONEncoder().encode(good)
            twoLines.append(Data("\n{\"agent\":\"second line\"}\ntrailing".utf8))
            t.expect(chatty.send(twoLines))
            t.expect(t.wait { inbox.count == 1 })
            settle(t, 0.1)
            t.expectEqual(inbox.envelopes, [good])
        }
    }

    t.test("oversized input is dropped; a large but legal message arrives intact") {
        try withServer(t, home) { server, inbox, socketURL in
            let flood = try t.unwrap(TestClient(socketURL))
            let tooMuch = Data(repeating: UInt8(ascii: "x"), count: HookServer.maxLineBytes + 64 * 1024)
            _ = flood.send(tooMuch)   // fails part-way once the server hangs up; that is the point
            t.expect(t.wait(5) { flood.serverHungUp }, "the server hung up on the flood")
            flood.close()
            t.expect(t.wait { server.connectionCount == 0 })
            t.expectEqual(inbox.count, 0)

            let big = testEnvelope("Write", payload: String(repeating: "0123456789abcdef\n", count: 200_000))   // ~3.4 MB
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(big))
            t.expect(t.wait(5) { inbox.count == 1 }, "large message delivered")
            t.expect(inbox.envelopes.first == big, "payload intact")
        }
    }

    t.test("a client that never finishes its message is dropped; a waiting one is not") {
        try withServer(t, home, firstLineTimeout: 0.3) { _, inbox, socketURL in
            let silent = try t.unwrap(TestClient(socketURL))
            let mumbling = try t.unwrap(TestClient(socketURL))
            t.expect(mumbling.send(Data("{\"agent\":".utf8)))
            let waiting = try t.unwrap(TestClient(socketURL))
            t.expect(waiting.send(testEnvelope("PermissionRequest", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            t.expect(t.wait(3) { silent.serverHungUp && mumbling.serverHungUp }, "idle connections are dropped")
            settle(t, 0.4)
            t.expect(!waiting.serverHungUp, "a helper waiting for an answer is never timed out")
            try t.unwrap(inbox.handles.first ?? nil).reply(HookReply(stdout: "ok", exitCode: 0))
            t.expect(waiting.readLine(timeout: 3) != nil)
        }
    }

    t.test("two servers on one path: the second refuses to start") {
        try withServer(t, home) { first, inbox, socketURL in
            let second = HookServer(socketURL: socketURL)
            var thrown: Error?
            do { try second.start() } catch { thrown = error }
            t.expectEqual(thrown as? HookServerError, .alreadyRunning(path: socketURL.path))
            t.expect((thrown as? LocalizedError)?.errorDescription?.contains("already") ?? false)
            t.expect(!second.isRunning)
            second.stop()   // must not delete the first server's socket file
            t.expect(first.isRunning, "the first server is untouched")
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("Stop")))
            t.expect(t.wait { inbox.count == 1 })

            first.stop()
            try second.start()
            t.expect(second.isRunning, "once the first has stopped, the second can take over")
            second.stop()
        }
    }

    t.test("a stale socket file from a crash is replaced") {
        let socketURL = home.socketURL()
        t.expect(leaveStaleSocket(at: socketURL.path), "test setup: stale socket file")
        t.expect(UnixSocket.identity(at: socketURL.path) != nil)
        t.expect(!UnixSocket.isAnswering(at: socketURL.path))
        let server = HookServer(socketURL: socketURL)
        let inbox = Inbox(server)
        try server.start()
        t.expect(server.isRunning)
        let client = try t.unwrap(TestClient(socketURL))
        t.expect(client.send(testEnvelope("SessionStart")))
        t.expect(t.wait { inbox.count == 1 })
        server.stop()
    }

    t.test("something that is not a socket is never deleted; too-long paths are refused") {
        let occupied = home.socketURL()
        try Data("keep me".utf8).write(to: occupied)
        let blocked = HookServer(socketURL: occupied)
        var thrown: Error?
        do { try blocked.start() } catch { thrown = error }
        t.expectEqual(thrown as? HookServerError, .pathOccupied(path: occupied.path))
        t.expectEqual(try String(contentsOf: occupied, encoding: .utf8), "keep me")
        t.expect(!blocked.isRunning)

        let longURL = home.url.appendingPathComponent(String(repeating: "long-folder-name/", count: 8) + "perch.sock")
        let tooLong = HookServer(socketURL: longURL)
        thrown = nil
        do { try tooLong.start() } catch { thrown = error }
        t.expectEqual(thrown as? HookServerError, .pathTooLong(path: longURL.path, limit: UnixSocket.maxPathBytes))
        t.expect(!FileManager.default.fileExists(atPath: longURL.deletingLastPathComponent().path), "nothing was created")
        t.expectEqual(UnixSocket.maxPathBytes, 103)
    }

    t.test("isRunning notices a deleted socket file, and start() repairs it") {
        try withServer(t, home) { server, inbox, socketURL in
            unlink(socketURL.path)
            t.expect(!server.isRunning, "helpers cannot reach a server whose socket file is gone")
            t.expect(TestClient(socketURL) == nil)
            try server.start()
            t.expect(server.isRunning)
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("Stop")))
            t.expect(t.wait { inbox.count == 1 })
        }
    }

    t.test("stop leaves a socket file that belongs to another server alone") {
        let socketURL = home.socketURL()
        let old = HookServer(socketURL: socketURL)
        try old.start()
        unlink(socketURL.path)                      // e.g. the support folder was wiped
        let new = HookServer(socketURL: socketURL)
        let inbox = Inbox(new)
        try new.start()
        old.stop()
        t.expect(new.isRunning, "the newer server's socket file survived")
        let client = try t.unwrap(TestClient(socketURL))
        t.expect(client.send(testEnvelope("Stop")))
        t.expect(t.wait { inbox.count == 1 })
        new.stop()
    }

    t.test("stop hangs up on waiting clients and tells their handles") {
        try withServer(t, home) { server, inbox, socketURL in
            let client = try t.unwrap(TestClient(socketURL))
            t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
            t.expect(t.wait { inbox.count == 1 })
            let handle = try t.unwrap(inbox.handles.first ?? nil)
            var disconnects = 0
            handle.onDisconnect = { disconnects += 1 }
            server.stop()
            t.expect(t.wait { client.serverHungUp }, "the helper is let go (it exits quietly)")
            t.expect(t.wait { disconnects == 1 }, "the engine learns its request can no longer be answered")
            handle.reply(.passthrough)
            settle(t, 0.1)
            t.expectEqual(disconnects, 1)
        }
    }

    t.test("a server that is thrown away without stop() still cleans up") {
        let socketURL = home.socketURL()
        var server: HookServer? = HookServer(socketURL: socketURL)
        try server?.start()
        let client = try t.unwrap(TestClient(socketURL))
        t.expect(client.send(testEnvelope("PermissionRequest", wantsReply: true)))
        t.expect(t.wait { server?.connectionCount == 1 })
        server = nil
        t.expect(!FileManager.default.fileExists(atPath: socketURL.path))
        t.expect(t.wait { client.serverHungUp })
    }

    t.test("200 connections one after another: every message arrives, in order") {
        try withServer(t, home) { server, _, socketURL in
            var events: [String] = []
            server.onEnvelope = { envelope, handle in
                events.append(envelope.event ?? "?")
                handle?.reply(HookReply(stdout: envelope.event ?? "", exitCode: 0))
            }
            var replies = 0
            for index in 0..<200 {
                let client = try t.unwrap(TestClient(socketURL))
                if index % 2 == 0 {
                    // Like a real fire-and-forget helper: write and leave at once, before the server has read.
                    t.expect(client.send(testEnvelope("event-\(index)")))
                    client.close()
                } else {
                    t.expect(client.send(testEnvelope("event-\(index)", wantsReply: true)))
                    t.expect(t.wait { events.count == index + 1 })
                    if let line = client.readLine(timeout: 3),
                       (try? JSONDecoder().decode(HookReply.self, from: Data(line.utf8)))?.stdout == "event-\(index)" { replies += 1 }
                    client.close()
                }
            }
            t.expect(t.wait(5) { events.count == 200 }, "all 200 delivered (got \(events.count))")
            t.expectEqual(events, (0..<200).map { "event-\($0)" })
            t.expectEqual(replies, 100)
            t.expect(t.wait { server.connectionCount == 0 })
        }
    }

    t.test("50 connections at the same moment: each gets its own reply") {
        try withServer(t, home) { server, _, socketURL in
            var delivered = 0
            server.onEnvelope = { envelope, handle in
                delivered += 1
                handle?.reply(HookReply(stdout: "reply to \(envelope.event ?? "?")", exitCode: 0))
            }
            let correct = Shared(0)
            let finished = Shared(false)
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: 50) { index in
                    guard let client = TestClient(socketURL), client.send(testEnvelope("c\(index)", wantsReply: true)),
                          let line = client.readLine(timeout: 10),
                          let reply = try? JSONDecoder().decode(HookReply.self, from: Data(line.utf8)) else { return }
                    if reply.stdout == "reply to c\(index)" { correct.update { $0 += 1 } }
                }
                finished.value = true
            }
            t.expect(t.wait(15) { finished.value }, "all clients finished")
            t.expectEqual(correct.value, 50)
            t.expectEqual(delivered, 50)
            t.expect(t.wait { server.connectionCount == 0 })
        }
    }

    t.test("more helpers waiting than allowed: further ones are turned away, events keep flowing") {
        try withServer(t, home) { server, inbox, socketURL in
            let limit = HookServer.maxWaitingHelpers
            var clients: [TestClient] = []
            for index in 0..<limit {
                let client = try t.unwrap(TestClient(socketURL))
                t.expect(client.send(testEnvelope("waiting-\(index)", wantsReply: true)))
                clients.append(client)
                t.expect(t.wait { inbox.count == index + 1 }, "helper \(index) was let in")
            }
            t.expectEqual(server.connectionCount, limit)
            let extra = try t.unwrap(TestClient(socketURL))
            t.expect(extra.send(testEnvelope("one too many", wantsReply: true)))
            t.expect(t.wait { extra.serverHungUp }, "turned away at once (its agent asks in the terminal instead)")
            t.expectEqual(inbox.count, limit, "and the app never hears of it")

            let reporter = try t.unwrap(TestClient(socketURL))
            t.expect(reporter.send(testEnvelope("ordinary event")))
            t.expect(t.wait { inbox.count == limit + 1 }, "ordinary events still get through")
            t.expect(!clients[0].serverHungUp, "the waiting helpers are undisturbed")

            try t.unwrap(inbox.handles[0]).reply(HookReply(stdout: "answered", exitCode: 0))
            t.expect(clients[0].readLine(timeout: 3) != nil)
            t.expect(t.wait { server.connectionCount == limit - 1 })
            let next = try t.unwrap(TestClient(socketURL))
            t.expect(next.send(testEnvelope("room again", wantsReply: true)))
            t.expect(t.wait { inbox.count == limit + 2 }, "once one is answered, another may wait")
            t.expect(inbox.handles.last.map { $0 != nil } ?? false)
        }
    }

    t.test("a burst bigger than the connection limit is taken in at the server's pace, losing nothing") {
        try withServer(t, home) { server, _, socketURL in
            var delivered = 0
            server.onEnvelope = { _, _ in delivered += 1 }
            // One thread connects, writes and leaves as fast as it can: far faster than real helper
            // processes could. When the system's queue is full a connection is refused, which a real
            // helper treats like "Perch is not running"; everyone who did get through must be heard.
            var connected = 0
            for index in 0..<500 {
                guard let client = TestClient(socketURL) else { continue }
                if client.send(testEnvelope("burst-\(index)")) { connected += 1 }
                client.close()
            }
            t.expect(t.wait(10) { delivered == connected }, "heard \(delivered) of the \(connected) that connected")
            settle(t, 0.2)
            t.expectEqual(delivered, connected, "none lost, none heard twice")
            t.expect(connected >= 64, "at least a queue's worth got through (\(connected))")
            t.expect(t.wait { server.connectionCount == 0 })
            print("    burst of 500: \(connected) connected and were delivered, \(500 - connected) were refused by the full queue")
        }
    }

    t.test("out of file descriptors: the server holds off instead of losing every helper, then recovers") {
        try withServer(t, home) { _, inbox, socketURL in
            settle(t, 0.1)
            // Sockets are created first; connecting them later needs no new descriptor on this side.
            let clients = (0..<4).compactMap { _ in TestClient(unconnected: ()) }
            t.expectEqual(clients.count, 4)
            // Use up every free descriptor number below the highest one in use, then forbid higher ones.
            var fillers: [Int32] = []
            let highest = highestOpenDescriptor()
            while true {
                let filler = open("/dev/null", O_RDONLY)
                if filler < 0 || filler > highest {
                    if filler >= 0 { close(filler) }
                    break
                }
                fillers.append(filler)
            }
            defer { fillers.forEach { close($0) } }
            var original = rlimit()
            getrlimit(RLIMIT_NOFILE, &original)
            var tight = original
            tight.rlim_cur = rlim_t(highest + 1)
            guard setrlimit(RLIMIT_NOFILE, &tight) == 0 else {
                print("    (skipped: this system does not allow lowering the descriptor limit)")
                return
            }
            for client in clients where client.connect(to: socketURL) { _ = client.send(testEnvelope("squeezed")) }
            settle(t, 0.1)
            let deliveredWhileStarved = inbox.count
            if setrlimit(RLIMIT_NOFILE, &original) != 0 {
                original.rlim_cur = min(original.rlim_max, rlim_t(OPEN_MAX))
                setrlimit(RLIMIT_NOFILE, &original)
            }
            t.expectEqual(deliveredWhileStarved, 0, "nothing can be accepted without descriptors")
            // macOS throws away the one connection whose accept failed. The server then waits half a
            // second before trying again, so the others are still queued when descriptors are back.
            t.expect(t.wait(5) { inbox.count >= clients.count - 1 }, "the queued helpers were served afterwards (\(inbox.count) of 4)")
            let served = inbox.count
            let fresh = try t.unwrap(TestClient(socketURL))
            t.expect(fresh.send(testEnvelope("after the shortage")))
            t.expect(t.wait(5) { inbox.count == served + 1 }, "and new helpers are accepted again")
        }
    }

    t.test("no file descriptors leak") {
        t.expect(t.wait(5) { openDescriptorCount() <= descriptorsAtStart },
                 "open descriptors: \(openDescriptorCount()) now, \(descriptorsAtStart) before the server tests")
    }
}

// MARK: - 2. HelperInstaller

private func runInstallerTests(_ t: TestRunner, _ home: RuntimeTestHome) {
    t.test("HelperInstaller copies the helper, keeps it up to date and never rewrites an identical copy") {
        let bundled = home.url.appendingPathComponent("bundled-helper")
        try Data("#!/bin/sh\necho version one\n".utf8).write(to: bundled)
        let installed = PerchPaths.helperURL
        t.expect(!HelperInstaller.isInstalled)

        try HelperInstaller.install(from: bundled)
        t.expect(HelperInstaller.isInstalled)
        t.expectEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
        t.expectEqual(fileMode(installed.path), S_IFREG | 0o755)
        let firstInode = inode(installed.path)

        try HelperInstaller.install(from: bundled)
        t.expectEqual(inode(installed.path), firstInode, "identical copy: left alone")

        chmod(installed.path, 0o644)
        t.expect(!HelperInstaller.isInstalled, "not executable = not installed")
        try HelperInstaller.install(from: bundled)
        t.expectEqual(fileMode(installed.path), S_IFREG | 0o755, "permissions repaired")
        t.expectEqual(inode(installed.path), firstInode, "without rewriting the file")

        try Data("#!/bin/sh\necho version two\n".utf8).write(to: bundled)
        try HelperInstaller.install(from: bundled)
        t.expectEqual(try String(contentsOf: installed, encoding: .utf8), "#!/bin/sh\necho version two\n")
        t.expect(inode(installed.path) != firstInode, "replaced by a new file (rename), not overwritten in place")
        t.expectEqual(fileMode(installed.path), S_IFREG | 0o755)
        t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path),
                      [PerchPaths.helperName], "no temporary files left behind")
    }

    t.test("HelperInstaller reports a missing bundled helper and leaves the installed one alone") {
        let missing = home.url.appendingPathComponent("no-such-helper")
        var thrown: Error?
        do { try HelperInstaller.install(from: missing) } catch { thrown = error }
        t.expectEqual(thrown as? HelperInstallError, .bundledHelperMissing(path: missing.path))
        t.expect((thrown as? LocalizedError)?.errorDescription?.contains(missing.path) ?? false)
        t.expect(HelperInstaller.isInstalled, "the previous copy is still there")
        t.expect(HelperInstaller.bundledHelperURL.path.hasSuffix("Contents/Helpers/perch-hook"))
    }
}

// MARK: - 3. HookClient (the helper's functions, in-process)

private func runClientTests(_ t: TestRunner, _ home: RuntimeTestHome) {
    t.test("process lookups: parent, name, missing processes") {
        let me = try t.unwrap(HookClient.processFacts(getpid()))
        t.expectEqual(me.parent, getppid())
        t.expectEqual(me.name, String(ProcessInfo.processInfo.processName.prefix(16)))
        t.expectNil(HookClient.processFacts(0))
        t.expectNil(HookClient.processFacts(-5))
        t.expectNil(HookClient.processFacts(Int32.max - 7), "no such process")
        t.expectEqual(HookClient.terminalPath(of: getpid()), terminalAccordingToPS(getpid()), "same answer as `ps -o tty=`")
        t.expectNil(HookClient.terminalPath(of: Int32.max - 7))
    }

    t.test("the agent's process id: --pid, then CLAUDE_PID, then the first parent that is not a shell") {
        t.expectEqual(HookClient.agentProcessID(override: 4242, claudePID: "77"), 4242)
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: "77"), 77)
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: "not a number", parent: getpid()), getpid())
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: "0", parent: getpid()), getpid())
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: nil, parent: getpid()), getpid(), "this test program is not a shell")
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: nil, parent: 1), 0, "an orphan knows nothing")
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: nil, parent: Int32.max - 7), Int32.max - 7,
                      "a parent that cannot be inspected is still the best guess")

        // A shell wrapper between us and the "hook": sh waits in its `read` builtin until the pipe closes.
        var pipeEnds: [Int32] = [0, 0]
        t.expectEqual(pipe(&pipeEnds), 0)
        let shell = try t.unwrap(ChildProcesses.spawn("/bin/sh", ["-c", "read line"], input: pipeEnds[0]))
        close(pipeEnds[0])
        t.expect(t.wait { HookClient.processFacts(shell)?.name == "sh" })
        t.expectEqual(HookClient.agentProcessID(override: nil, claudePID: nil, parent: shell), getpid(), "skips the shell")
        close(pipeEnds[1])
        t.expect(ChildProcesses.waitForExit(shell, t) != nil)
    }

    t.test("a process's terminal is found without running ps") {
        guard let terminal = PseudoTerminal() else {
            print("    (skipped: no pseudo-terminal available here)")
            return
        }
        let sleeper = try t.unwrap(ChildProcesses.spawn("/bin/sleep", ["30"], controllingTerminal: terminal.devicePath))
        defer { ChildProcesses.kill(sleeper) }
        t.expect(t.wait { HookClient.processFacts(sleeper)?.name == "sleep" })
        let started = DispatchTime.now().uptimeNanoseconds
        let found = HookClient.terminalPath(of: sleeper)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        t.expectEqual(found, terminal.devicePath)
        t.expectEqual(found, terminalAccordingToPS(sleeper), "same answer as `ps -o tty=`")
        print(String(format: "    terminal lookup took %.3f ms", milliseconds))
        t.expect(milliseconds < 5, "terminal lookup must be quick")

        // Devices that are not numbered terminal tabs are found the slower, general way.
        var info = stat()
        t.expectEqual(stat("/dev/null", &info), 0)
        t.expectEqual(HookClient.devicePath(forTerminal: info.st_rdev), "/dev/null")
        t.expectEqual(stat(terminal.devicePath, &info), 0)
        t.expectEqual(HookClient.devicePath(forTerminal: info.st_rdev), terminal.devicePath)
        t.expectNil(HookClient.devicePath(forTerminal: 0x7F00_1234), "no such device")
    }

    t.test("only whitelisted, non-empty environment variables are forwarded") {
        setenv("TERM_PROGRAM", "iTerm.app", 1)
        setenv("ITERM_SESSION_ID", "w0t1p0:ABC", 1)
        setenv("TMUX", "", 1)
        setenv("PERCH_TEST_SECRET", "do not forward", 1)
        let names = ["TERM_PROGRAM", "ITERM_SESSION_ID", "TMUX", "PERCH_TEST_SECRET"]
        defer { for name in names { unsetenv(name) } }
        let forwarded = HookClient.forwardedEnvironment()
        t.expectEqual(forwarded["TERM_PROGRAM"], "iTerm.app")
        t.expectEqual(forwarded["ITERM_SESSION_ID"], "w0t1p0:ABC")
        t.expectNil(forwarded["TMUX"], "empty values say nothing")
        t.expectNil(forwarded["PERCH_TEST_SECRET"])
        t.expect(Set(forwarded.keys).isSubset(of: Set(HookEnvelope.forwardedEnvKeys)))
    }

    t.test("the envelope is filled in as ARCHITECTURE §5 describes and travels as one line") {
        var options = HookClient.Options(agent: "codex", channel: "notify", event: "agent-turn-complete", wait: true)
        options.pidOverride = getpid()
        options.extraArgs = ["{\"type\":\"agent-turn-complete\"}"]
        let before = Date().timeIntervalSince1970
        let payload = "{\"text\":\"a\\nb\"}\nsecond line \u{0} ünïcödé\n"
        let envelope = HookClient.makeEnvelope(options, payload: payload)
        t.expectEqual(envelope.v, 1)
        t.expectEqual(envelope.agent, "codex")
        t.expectEqual(envelope.channel, "notify")
        t.expectEqual(envelope.event, "agent-turn-complete")
        t.expectEqual(envelope.payload, payload)
        t.expectEqual(envelope.args, options.extraArgs)
        t.expectEqual(envelope.pid, getpid())
        t.expectEqual(envelope.tty, HookClient.terminalPath(of: getpid()))
        t.expectEqual(envelope.cwd, FileManager.default.currentDirectoryPath)
        t.expectEqual(envelope.wantsReply, true)
        t.expect(envelope.sentAt >= before && envelope.sentAt <= Date().timeIntervalSince1970)

        let line = try t.unwrap(HookClient.encodeLine(envelope))
        t.expectEqual(line.last, 0x0A)
        t.expectEqual(line.filter { $0 == 0x0A }.count, 1, "exactly one newline: the one at the end")
        t.expectEqual(try JSONDecoder().decode(HookEnvelope.self, from: line.dropLast()), envelope)

        options.channel = "statusline"
        t.expectEqual(HookClient.makeEnvelope(options, payload: "").wantsReply, false, "the status line never waits")
        options.fallback = "x"
        t.expectEqual(options.fallbackOutput, "", "and never prints")
    }

    t.test("reading stdin: to end-of-file, giving up on a writer that goes quiet, refusing too much") {
        var ends: [Int32] = [0, 0]
        t.expectEqual(pipe(&ends), 0)
        let text = Data(String(repeating: "payload ", count: 20_000).utf8)   // 160 KB: more than a pipe holds
        let writeEnd = ends[1]
        DispatchQueue.global().async {
            _ = HookClient.writeAll(text, to: writeEnd, timeout: 5)
            close(writeEnd)
        }
        t.expectEqual(HookClient.readAll(from: ends[0], idleTimeout: 2, limit: 1_000_000), text)
        close(ends[0])

        t.expectEqual(pipe(&ends), 0)
        _ = HookClient.writeAll(Data("never closed".utf8), to: ends[1], timeout: 1)
        let started = Date()
        t.expectEqual(HookClient.readAll(from: ends[0], idleTimeout: 0.25, limit: 1000), Data("never closed".utf8))
        let waited = Date().timeIntervalSince(started)
        t.expect(waited >= 0.2 && waited < 1.5, "gave up after the idle timeout (waited \(waited) s)")
        _ = HookClient.writeAll(Data("more than four bytes".utf8), to: ends[1], timeout: 1)
        t.expect(HookClient.readAll(from: ends[0], idleTimeout: 0.1, limit: 4) == nil, "over the limit")
        close(ends[0])
        t.expect(!HookClient.writeAll(Data("x".utf8), to: ends[1], timeout: 1), "writing to a closed pipe fails quietly")
        close(ends[1])
        t.expectEqual(HookClient.readAll(from: -1, idleTimeout: 0.1, limit: 10), Data(), "a bad descriptor reads as empty")
    }

    t.test("HookClient.run: nothing listening means exit 0, no output, and no waiting") {
        var options = HookClient.Options(agent: "claude", wait: true)
        let nowhere = home.socketURL().path
        var result = runClient(t, options, socketPath: nowhere, input: "{\"hook_event_name\":\"PreToolUse\"}")
        t.expectEqual(result?.status, 0)
        t.expectEqual(result?.output, "")
        t.expect((result?.seconds ?? 9) < 0.5, "returns at once")

        t.expect(leaveStaleSocket(at: nowhere))
        result = runClient(t, options, socketPath: nowhere, input: "{}")
        t.expectEqual(result?.status, 0, "a stale socket file is the same as no app")
        t.expectEqual(result?.output, "")

        result = runClient(t, options, socketPath: home.url.path + "/" + String(repeating: "x", count: 150), input: "{}")
        t.expectEqual(result?.status, 0, "a path too long for a socket")
        t.expectEqual(result?.output, "")

        options.fallback = "{\"decision\":\"ask\"}"
        result = runClient(t, options, socketPath: nowhere, input: "{}")
        t.expectEqual(result?.output, "{\"decision\":\"ask\"}", "--fallback is what gets printed when Perch has no answer")
        t.expectEqual(result?.status, 0)

        t.expectNil(HookClient.openConnection(to: ""))
        t.expectNil(HookClient.openConnection(to: nowhere))
    }

    t.test("HookClient.run: fire-and-forget and the blocking round trip against a real server") {
        try withServer(t, home) { server, inbox, socketURL in
            var options = HookClient.Options(agent: "claude", event: "Stop")
            options.extraArgs = ["extra"]
            var result = runClient(t, options, socketPath: socketURL.path, input: "{\"stop\":true}")
            t.expectEqual(result?.status, 0)
            t.expectEqual(result?.output, "")
            t.expect(t.wait { inbox.count == 1 })
            t.expectEqual(inbox.envelopes.first?.payload, "{\"stop\":true}")
            t.expectEqual(inbox.envelopes.first?.event, "Stop")
            t.expectEqual(inbox.envelopes.first?.args, ["extra"])
            t.expectEqual(inbox.envelopes.first?.wantsReply, false)
            t.expectEqual(inbox.envelopes.first?.pid, HookClient.agentProcessID(override: nil, claudePID: nil))

            options.wait = true
            server.onEnvelope = { envelope, handle in
                handle?.reply(HookReply(stdout: "decision for \(envelope.payload)", exitCode: 2))
            }
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.output, "decision for abc", "printed exactly, with nothing added")
            t.expectEqual(result?.status, 2)

            server.onEnvelope = { _, handle in handle?.reply(.passthrough) }
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.output, "", "passthrough prints nothing")
            t.expectEqual(result?.status, 0)

            options.fallback = "ASK"
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.output, "ASK", "no opinion + --fallback prints the fallback")

            server.onEnvelope = { _, handle in handle?.reply(HookReply(stdout: "real answer", exitCode: 0)) }
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.output, "real answer", "a real answer wins over the fallback")

            options.wait = false
            var seen = 0
            server.onEnvelope = { _, _ in seen += 1 }
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.output, "ASK", "reporting only: the fallback is printed and the event still arrives")
            t.expect(t.wait { seen == 1 })

            options = HookClient.Options(agent: "", wait: true)
            result = runClient(t, options, socketPath: socketURL.path, input: "abc")
            t.expectEqual(result?.status, 0, "no --agent: nothing is sent")
            settle(t, 0.1)
            t.expectEqual(seen, 1)
        }
    }

    t.test("HookClient.run: --timeout, an app that hangs up, and a reply that is not a reply") {
        try withServer(t, home) { server, _, socketURL in
            var kept: [ReplyHandle] = []
            var disconnects = 0
            server.onEnvelope = { _, handle in
                guard let handle else { return }
                handle.onDisconnect = { disconnects += 1 }
                kept.append(handle)
            }
            var options = HookClient.Options(agent: "claude", wait: true)
            options.timeout = 0.4
            var result = runClient(t, options, socketPath: socketURL.path, input: "{}")
            t.expectEqual(result?.status, 0)
            t.expectEqual(result?.output, "")
            t.expect((result?.seconds ?? 0) >= 0.35 && (result?.seconds ?? 9) < 2, "waited for the timeout (\(result?.seconds ?? -1) s)")
            t.expect(t.wait { disconnects == 1 }, "the app is told the helper gave up")

            options.timeout = nil
            server.onEnvelope = { _, handle in handle?.close() }
            result = runClient(t, options, socketPath: socketURL.path, input: "{}")
            t.expectEqual(result?.status, 0, "closed without a reply")
            t.expectEqual(result?.output, "")
            kept.removeAll()
        }

        // A "server" that answers with nonsense, and one that sends the reply in two pieces.
        var ends: [Int32] = [0, 0]
        t.expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0)
        let serverEnd = ends[1]
        _ = HookClient.writeAll(Data("certainly not json\n".utf8), to: serverEnd, timeout: 1)
        t.expectNil(HookClient.readReply(from: ends[0], timeout: 1))
        DispatchQueue.global().async {
            _ = HookClient.writeAll(Data("{\"stdout\":\"spl".utf8), to: serverEnd, timeout: 1)
            usleep(100_000)
            _ = HookClient.writeAll(Data("it\",\"exitCode\":5}\nignored".utf8), to: serverEnd, timeout: 1)
        }
        t.expectEqual(HookClient.readReply(from: ends[0], timeout: 3), HookReply(stdout: "split", exitCode: 5))
        close(ends[1])
        t.expectNil(HookClient.readReply(from: ends[0], timeout: 1), "end of file")
        close(ends[0])
    }
}

// MARK: - 4. The real perch-hook program

private func runHelperProgramTests(_ t: TestRunner, _ home: RuntimeTestHome) {
    let helper = TestRunner.root.appendingPathComponent(".build/bin/perch-hook")
    var built = false
    t.test("scripts/build-helper.sh builds perch-hook") {
        let build = try ChildRun(URL(fileURLWithPath: "/bin/bash"),
                                 [TestRunner.root.appendingPathComponent("scripts/build-helper.sh").path],
                                 environment: ProcessInfo.processInfo.environment)
        let result = try t.unwrap(build.finish(t, within: 300), "the build did not finish")
        t.expectEqual(result.status, 0, "build failed: \(result.errorText)")
        t.expectEqual(result.errorText, "", "the helper must compile without warnings")
        t.expect(FileManager.default.isExecutableFile(atPath: helper.path))
        built = result.status == 0
    }
    guard built else { return }
    let environment = ["PERCH_HOME": home.url.path, "PATH": "/usr/bin:/bin"]
    let server = HookServer()   // at PerchPaths.socketURL, which PERCH_HOME places in the test folder
    let inbox = Inbox(server)
    /// Runs the helper to completion with the given arguments and stdin.
    func run(_ arguments: [String], input: String? = nil, extraEnvironment: [String: String] = [:]) throws -> ChildRun.Result {
        let child = try ChildRun(helper, arguments, environment: environment.merging(extraEnvironment) { $1 },
                                 input: input.map { Data($0.utf8) })
        return try t.unwrap(child.finish(t), "perch-hook did not exit: \(arguments)")
    }

    t.test("perch-hook with no app running: exit 0, silent, fast") {
        t.expect(!server.isRunning)
        for arguments in [["--agent", "claude"], ["--agent", "claude", "--wait"], ["--agent", "codex", "--channel", "notify", "--", "{}"],
                          [], ["--agent"], ["--wait", "--timeout"], ["--bogus", "--pid", "x"]] {
            let result = try run(arguments, input: "{\"hook_event_name\":\"PreToolUse\"}")
            t.expectEqual(result.status, 0, "\(arguments)")
            t.expectEqual(result.output, "", "stdout \(arguments)")
            t.expectEqual(result.errorText, "", "stderr \(arguments)")
            t.expect(result.seconds < 1, "took \(result.seconds) s")
        }
        t.expect(leaveStaleSocket(at: PerchPaths.socketURL.path))
        let stale = try run(["--agent", "claude", "--wait"], input: "{}")
        t.expectEqual(stale.status, 0, "stale socket file")
        t.expectEqual(stale.output + stale.errorText, "")
        let fallback = try run(["--agent", "antigravity", "--wait", "--fallback", "{\"decision\":\"ask\"}"], input: "{}")
        t.expectEqual(fallback.output, "{\"decision\":\"ask\"}")
        t.expectEqual(fallback.status, 0)
    }

    t.test("HelperInstaller's copy of the real perch-hook runs") {
        try HelperInstaller.install(from: helper)
        t.expect(HelperInstaller.isInstalled)
        t.expectEqual(try Data(contentsOf: PerchPaths.helperURL), try Data(contentsOf: helper))
        let child = try ChildRun(PerchPaths.helperURL, ["--agent", "claude", "--wait", "--fallback", "copy works"], environment: environment)
        let result = try t.unwrap(child.finish(t))
        t.expectEqual(result.status, 0)
        t.expectEqual(result.output, "copy works")
        t.expectEqual(result.errorText, "")
    }

    t.test("perch-hook fire-and-forget: payload, arguments, environment, folder and process id arrive") {
        try server.start()   // also proves the stale socket file from the previous test is replaced
        let folder = home.url.appendingPathComponent("project folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = "{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"echo 'hi'\\n\"}}\n"
        let child = try ChildRun(helper, ["--agent", "claude", "--event", "PreToolUse", "--future-option", "--", "a b", "--wait", "c"],
                                 environment: environment.merging(["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%3", "CLAUDE_PROJECT_DIR": "/tmp/p",
                                                                   "AWS_SECRET_ACCESS_KEY": "nope", "KITTY_WINDOW_ID": ""]) { $1 },
                                 input: Data(payload.utf8), directory: folder)
        let result = try t.unwrap(child.finish(t))
        t.expectEqual(result.status, 0)
        t.expectEqual(result.output + result.errorText, "", "prints nothing")
        t.expect(t.wait { inbox.count == 1 }, "delivered")
        let envelope = try t.unwrap(inbox.envelopes.first)
        t.expectEqual(envelope.v, 1)
        t.expectEqual(envelope.agent, "claude")
        t.expectEqual(envelope.channel, "hook")
        t.expectEqual(envelope.event, "PreToolUse")
        t.expectEqual(envelope.payload, payload)
        t.expectEqual(envelope.args, ["a b", "--wait", "c"], "everything after -- is passed along untouched")
        t.expectEqual(envelope.env, ["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%3", "CLAUDE_PROJECT_DIR": "/tmp/p"])
        t.expectEqual(envelope.wantsReply, false)
        t.expectEqual(envelope.pid, getpid(), "started directly by this test, so this test is the 'agent'")
        t.expectEqual(envelope.tty, terminalAccordingToPS(getpid()))
        t.expectEqual(realPath(envelope.cwd), realPath(folder.path))
        t.expect(abs(envelope.sentAt - Date().timeIntervalSince1970) < 30)
        t.expect(inbox.handles.first.map { $0 == nil } ?? false)
    }

    t.test("perch-hook finds the agent through shell wrappers, CLAUDE_PID and --pid") {
        inbox.clear()
        // sh -c with two commands keeps the shell alive as the helper's parent; zsh wraps that again.
        let script = "\"$0\" --agent gemini --event via-shell; exit 0"
        _ = try t.unwrap(try ChildRun(URL(fileURLWithPath: "/bin/zsh"), ["-c", "/bin/sh -c '\(script)' \"$0\"; exit 0", helper.path],
                                      environment: environment).finish(t))
        t.expect(t.wait { inbox.count == 1 })
        t.expectEqual(inbox.envelopes.last?.pid, getpid(), "walked past sh and zsh to this test")
        t.expectEqual(inbox.envelopes.last?.agent, "gemini")

        _ = try run(["--agent", "claude"], extraEnvironment: ["CLAUDE_PID": "4321"])
        t.expect(t.wait { inbox.count == 2 })
        t.expectEqual(inbox.envelopes.last?.pid, 4321)
        t.expectEqual(inbox.envelopes.last?.env["CLAUDE_PID"], "4321")
        t.expectEqual(inbox.envelopes.last?.payload, "", "stdin was /dev/null")

        _ = try run(["--agent", "claude", "--pid", "\(getppid())"], extraEnvironment: ["CLAUDE_PID": "4321"])
        t.expect(t.wait { inbox.count == 3 })
        t.expectEqual(inbox.envelopes.last?.pid, getppid(), "--pid wins")
        t.expectEqual(inbox.envelopes.last?.tty, terminalAccordingToPS(getppid()))

        // Codex started from inside a Claude session inherits CLAUDE_PID; it must not be taken for Claude.
        _ = try run(["--agent", "codex"], extraEnvironment: ["CLAUDE_PID": "4321"])
        t.expect(t.wait { inbox.count == 4 })
        t.expectEqual(inbox.envelopes.last?.pid, getpid(), "CLAUDE_PID only counts for --agent claude")
    }

    t.test("perch-hook started from a terminal: reports that terminal and does not read the keyboard") {
        inbox.clear()
        guard let terminal = PseudoTerminal() else {
            print("    (skipped: no pseudo-terminal available here)")
            return
        }
        // /usr/bin/time plays the agent: a non-shell parent whose controlling terminal is our pseudo-terminal.
        let agent = try t.unwrap(ChildProcesses.spawn("/usr/bin/time", [helper.path, "--agent", "claude", "--event", "from-terminal"],
                                                      environment: environment, controllingTerminal: terminal.devicePath))
        t.expectEqual(ChildProcesses.waitForExit(agent, t), 0, "stdin is a terminal, so the helper must not wait for typing")
        t.expect(t.wait { inbox.count == 1 })
        t.expectEqual(inbox.envelopes.first?.pid, agent)
        t.expectEqual(inbox.envelopes.first?.tty, terminal.devicePath)
        t.expectEqual(inbox.envelopes.first?.payload, "")
    }

    t.test("perch-hook --wait prints the reply exactly and exits with its code") {
        inbox.clear()
        let exact = "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"allow\"}}}"
        let child = try ChildRun(helper, ["--agent", "claude", "--wait"], environment: environment, input: Data("{\"n\":1}".utf8))
        t.expect(t.wait(5) { inbox.count == 1 })
        t.expectEqual(inbox.envelopes.first?.wantsReply, true)
        t.expectEqual(inbox.envelopes.first?.payload, "{\"n\":1}")
        settle(t, 0.2)
        t.expect(child.isRunning, "the helper keeps waiting until the app answers")
        try t.unwrap(inbox.handles.first ?? nil).reply(HookReply(stdout: exact, exitCode: 7))
        var result = try t.unwrap(child.finish(t))
        t.expectEqual(result.output, exact, "no newline or anything else added")
        t.expectEqual(result.status, 7)
        t.expectEqual(result.errorText, "")

        server.onEnvelope = { _, handle in handle?.reply(HookReply(stdout: "line one\nline two ✓\n", exitCode: 0)) }
        result = try run(["--agent", "codex", "--wait", "--timeout", "30"], input: "{}")
        t.expectEqual(result.output, "line one\nline two ✓\n")
        t.expectEqual(result.status, 0)

        server.onEnvelope = { _, handle in handle?.reply(.passthrough) }
        result = try run(["--agent", "claude", "--wait"], input: "{}")
        t.expectEqual(result.output + result.errorText, "", "passthrough: silent")
        t.expectEqual(result.status, 0)
        result = try run(["--agent", "antigravity", "--wait", "--fallback", "ASK"], input: "{}")
        t.expectEqual(result.output, "ASK", "passthrough + --fallback")

        let large = String(repeating: "updated input ", count: 40_000)   // 560 KB: far more than the socket buffers
        server.onEnvelope = { _, handle in handle?.reply(HookReply(stdout: large, exitCode: 0)) }
        result = try run(["--agent", "claude", "--wait"], input: "{}")
        t.expect(result.output == large, "a large reply arrives whole (\(result.output.utf8.count) bytes)")
        inbox.attach(to: server)
    }

    t.test("perch-hook --timeout gives up quietly; a killed helper is noticed by the app") {
        inbox.clear()
        var disconnects = 0
        let started = Date()
        let child = try ChildRun(helper, ["--agent", "claude", "--wait", "--timeout", "0.5"], environment: environment, input: Data("{}".utf8))
        t.expect(t.wait(5) { inbox.count == 1 })
        try t.unwrap(inbox.handles.first ?? nil).onDisconnect = { disconnects += 1 }
        let result = try t.unwrap(child.finish(t))
        let waited = Date().timeIntervalSince(started)
        t.expectEqual(result.status, 0)
        t.expectEqual(result.output + result.errorText, "")
        t.expect(waited >= 0.45 && waited < 3, "gave up after about half a second (\(waited) s)")
        t.expect(t.wait { disconnects == 1 }, "onDisconnect after the timeout")

        // The user answers in the terminal and the agent kills the hook.
        let victim = try ChildRun(helper, ["--agent", "claude", "--wait"], environment: environment, input: Data("{}".utf8))
        t.expect(t.wait(5) { inbox.count == 2 })
        try t.unwrap(inbox.handles.last ?? nil).onDisconnect = { disconnects += 1 }
        victim.kill()
        _ = victim.finish(t)
        t.expect(t.wait { disconnects == 2 }, "onDisconnect after the helper was killed")
    }

    t.test("perch-hook whose agent has died stops waiting by itself") {
        inbox.clear()
        var disconnects = 0
        // The shell starts the helper in the background, prints its process id and exits a moment
        // later, as when an agent ends a hook by killing the shell it started: the helper is orphaned.
        let script = "\"$0\" --agent claude --wait </dev/null >/dev/null 2>&1 & echo $!; sleep 0.4"
        let result = try t.unwrap(try ChildRun(URL(fileURLWithPath: "/bin/sh"), ["-c", script, helper.path], environment: environment).finish(t))
        let orphan = try t.unwrap(Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)), "helper pid")
        ChildProcesses.track(orphan)
        t.expect(t.wait(5) { inbox.count == 1 })
        try t.unwrap(inbox.handles.first ?? nil).onDisconnect = { disconnects += 1 }
        t.expect(t.wait(5) { disconnects == 1 }, "the orphaned helper hung up")
        t.expect(t.wait(2) { Darwin.kill(orphan, 0) != 0 }, "and exited")
    }

    t.test("perch-hook with stdin, stdout and stderr closed still reports and still obeys the reply") {
        inbox.clear()
        // With no stdin the socket would be handed descriptor 0; the helper has to notice and step
        // aside, or it would read its own socket as the payload and print the reply into it.
        let pid = try t.unwrap(ChildProcesses.spawnWithoutStandardDescriptors(helper.path, ["--agent", "claude", "--event", "bare", "--wait"],
                                                                              environment: environment))
        t.expect(t.wait(5) { inbox.count == 1 }, "delivered")
        t.expectEqual(inbox.envelopes.first?.event, "bare")
        t.expectEqual(inbox.envelopes.first?.payload, "")
        try t.unwrap(inbox.handles.first ?? nil).reply(HookReply(stdout: "nowhere to print this", exitCode: 9))
        t.expectEqual(ChildProcesses.waitForExit(pid, t), 9, "exit code from the reply")
    }

    t.test("perch-hook status line channel: reports, never waits, never prints") {
        inbox.clear()
        let result = try run(["--agent", "claude", "--channel", "statusline", "--wait", "--fallback", "nope"], input: "{\"model\":{\"id\":\"x\"}}")
        t.expectEqual(result.output + result.errorText, "")
        t.expectEqual(result.status, 0)
        t.expect(result.seconds < 2, "did not wait")
        t.expect(t.wait { inbox.count == 1 })
        t.expectEqual(inbox.envelopes.first?.channel, "statusline")
        t.expectEqual(inbox.envelopes.first?.wantsReply, false)
        t.expectEqual(inbox.envelopes.first?.payload, "{\"model\":{\"id\":\"x\"}}")
    }

    t.test("perch-hook payload sizes: 1 MB arrives whole, more than 8 MB is skipped quietly") {
        inbox.clear()
        let megabyte = String(repeating: "0123456789abcde\n", count: 65_536)
        var result = try run(["--agent", "claude"], input: megabyte)
        t.expectEqual(result.status, 0)
        t.expect(t.wait(5) { inbox.count == 1 })
        t.expect(inbox.envelopes.first?.payload == megabyte, "1 MB payload intact")

        result = try run(["--agent", "claude", "--wait"], input: String(repeating: "x", count: HookClient.maxLineBytes + 1000))
        t.expectEqual(result.status, 0, "an oversized event is not worth blocking the agent for")
        t.expectEqual(result.output + result.errorText, "")
        settle(t, 0.2)
        t.expectEqual(inbox.count, 1, "nothing was delivered for it")
    }

    t.test("perch-hook: 12 helpers at once, 60 in a row") {
        inbox.clear()
        var events: [String] = []
        server.onEnvelope = { envelope, handle in
            events.append(envelope.event ?? "?")
            handle?.reply(HookReply(stdout: envelope.event ?? "", exitCode: 0))
        }
        let together = try (0..<12).map { index in
            try ChildRun(helper, ["--agent", "claude", "--event", "parallel-\(index)", "--wait"], environment: environment, input: Data("{}".utf8))
        }
        for (index, child) in together.enumerated() {
            let result = try t.unwrap(child.finish(t))
            t.expectEqual(result.output, "parallel-\(index)")
        }
        for index in 0..<60 {
            let pid = try t.unwrap(ChildProcesses.spawn(helper.path, ["--agent", "claude", "--event", "serial-\(index)"], environment: environment))
            t.expectEqual(ChildProcesses.waitForExit(pid, t), 0)
        }
        t.expect(t.wait(5) { events.count == 72 }, "every event arrived (\(events.count) of 72)")
        t.expectEqual(events.filter { $0.hasPrefix("serial-") }, (0..<60).map { "serial-\($0)" }, "in order")
    }

    t.test("perch-hook speed (goal: under 15 ms per event)") {
        let payload = Data(("{\"session_id\":\"abc\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\""
            + String(repeating: "x", count: 1500) + "\"}}").utf8)
        server.onEnvelope = { _, handle in handle?.reply(HookReply(stdout: "{\"decision\":\"allow\"}", exitCode: 0)) }
        let forget = measure(t, runs: 40) { timeOneRun(helper.path, ["--agent", "claude"], environment: environment, input: payload) }
        let roundTrip = measure(t, runs: 40) { timeOneRun(helper.path, ["--agent", "claude", "--wait"], environment: environment, input: payload) }
        server.stop()
        let noApp = measure(t, runs: 40) { timeOneRun(helper.path, ["--agent", "claude", "--wait"], environment: environment, input: payload) }
        print("    fire-and-forget: \(forget.summary)")
        print("    round trip:      \(roundTrip.summary)")
        print("    app not running: \(noApp.summary)")
        // The fastest run is what the helper costs; the median also includes whatever else this Mac is doing.
        t.expect(forget.fastest < 15, "fire-and-forget \(forget.summary)")
        t.expect(roundTrip.fastest < 15, "round trip \(roundTrip.summary)")
        t.expect(noApp.fastest < 15, "app not running \(noApp.summary)")
        t.expectEqual(forget.failures + roundTrip.failures + noApp.failures, 0, "every timed run exited 0")
    }

    server.stop()
    t.test("every child process started by these tests is gone") {
        t.expect(t.wait(5) { ChildProcesses.alive.isEmpty }, "still running: \(ChildProcesses.alive)")
    }
}

// MARK: - Test support: folders, servers, envelopes

/// A temporary PERCH_HOME. The path is kept short because a socket path may be at most 103 bytes.
private final class RuntimeTestHome {
    let url: URL
    private var socketCounter = 0

    init() {
        let name = "perch-rt-\(String(UUID().uuidString.prefix(6)).lowercased())"
        var base = FileManager.default.temporaryDirectory
        if base.path.utf8.count > 60 { base = URL(fileURLWithPath: "/tmp", isDirectory: true) }
        url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("PERCH_HOME", url.path, 1)
    }

    /// A fresh socket path, so tests never interfere with each other.
    func socketURL() -> URL {
        socketCounter += 1
        return url.appendingPathComponent("s\(socketCounter).sock")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Collects what a server hands to the app.
private final class Inbox {
    private(set) var envelopes: [HookEnvelope] = []
    private(set) var handles: [ReplyHandle?] = []
    private(set) var deliveredOffMain = 0
    var count: Int { envelopes.count }

    init(_ server: HookServer) { attach(to: server) }

    func attach(to server: HookServer) {
        server.onEnvelope = { [unowned self] envelope, handle in
            if !Thread.isMainThread { self.deliveredOffMain += 1 }
            self.envelopes.append(envelope)
            self.handles.append(handle)
        }
    }

    func clear() {
        envelopes.removeAll()
        handles.removeAll()
    }
}

/// Starts a server on a fresh socket, runs `body`, and stops the server whatever happens.
private func withServer(_ t: TestRunner, _ home: RuntimeTestHome, firstLineTimeout: TimeInterval = 10,
                        _ body: (HookServer, Inbox, URL) throws -> Void) throws {
    let socketURL = home.socketURL()
    let server = HookServer(socketURL: socketURL, firstLineTimeout: firstLineTimeout)
    let inbox = Inbox(server)
    try server.start()
    defer { server.stop() }
    try body(server, inbox, socketURL)
}

private func testEnvelope(_ event: String, wantsReply: Bool = false, payload: String = "{}") -> HookEnvelope {
    var envelope = HookEnvelope(agent: "claude")
    envelope.event = event
    envelope.payload = payload
    envelope.pid = getpid()
    envelope.cwd = "/tmp/project"
    envelope.wantsReply = wantsReply
    envelope.sentAt = 1_800_000_000.5
    return envelope
}

/// Lets the main thread's queue run for a while (the server delivers its callbacks there).
private func settle(_ t: TestRunner, _ seconds: TimeInterval) {
    t.wait(seconds) { false }
}

/// A value shared between threads.
private final class Shared<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

// MARK: - Test support: a bare POSIX client

/// Stands in for the helper when testing the server, using plain socket calls so the server is
/// not merely tested against HookClient's idea of the protocol.
private final class TestClient {
    private var descriptor: Int32
    private var received = Data()

    /// Connects to a server. Nil when nothing is listening.
    convenience init?(_ socketURL: URL) {
        self.init(unconnected: ())
        guard descriptor >= 0, connect(to: socketURL) else { return nil }
    }

    /// Creates the socket without connecting it yet.
    init?(unconnected: Void) {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func connect(to socketURL: URL) -> Bool {
        var address = sockaddr_un()
        let path = Array(socketURL.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    func send(_ envelope: HookEnvelope) -> Bool {
        guard var line = try? JSONEncoder().encode(envelope) else { return false }
        line.append(0x0A)
        return send(line)
    }

    /// Writes everything (blocking). False if the server hung up part-way.
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard let start = bytes.baseAddress else { return true }
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, start + sent, bytes.count - sent)
                if count > 0 { sent += count } else if !(count < 0 && errno == EINTR) { return false }
            }
            return true
        }
    }

    /// True when at least one byte from the server is waiting to be read.
    var hasBytes: Bool { peek() > 0 }

    /// True once the server has closed the connection and there is nothing left to read.
    var serverHungUp: Bool {
        guard descriptor >= 0 else { return true }
        var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&watch, 1, 0) > 0 else { return false }
        let count = peek()
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
    }

    /// Waits for one line from the server. Nil if it hangs up or the time runs out first.
    func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = received.firstIndex(of: 0x0A) {
                let line = String(decoding: received[received.startIndex..<newline], as: UTF8.self)
                received.removeSubrange(received.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&watch, 1, Int32(remaining * 1000) + 1) > 0 else { continue }
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 { received.append(chunk, count: count) } else if count == 0 || errno != EINTR { return nil }
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }

    private func peek() -> Int {
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    }
}

/// Creates a socket file with nobody listening on it, which is what a crashed app leaves behind.
private func leaveStaleSocket(at path: String) -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    unlink(path)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix(100)) }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
}

// MARK: - Test support: files and descriptors

private func fileMode(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode : nil
}

private func inode(_ path: String) -> ino_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_ino : nil
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func openDescriptorCount() -> Int {
    (0..<Int32(4096)).filter { fcntl($0, F_GETFD) != -1 }.count
}

private func highestOpenDescriptor() -> Int32 {
    (0..<Int32(4096)).last { fcntl($0, F_GETFD) != -1 } ?? 2
}

/// Shells often allow only 256 open files; the connection-limit test needs a few more than that.
private func raiseDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 1024 else { return }
    limit.rlim_cur = min(1024, limit.rlim_max)
    setrlimit(RLIMIT_NOFILE, &limit)
}

// MARK: - Test support: child processes

/// What `ps -o tty=` says about a process, in the form the envelope uses ("/dev/ttys003"; nil for "??").
/// This is the reference the helper's sysctl lookup is checked against.
private func terminalAccordingToPS(_ pid: Int32) -> String? {
    let ps = Process()
    let pipe = Pipe()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "tty=", "-p", "\(pid)"]
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    ps.waitUntilExit()
    return text.isEmpty || text.hasPrefix("?") ? nil : "/dev/" + text
}

/// A pseudo-terminal: gives a child process a controlling terminal without a real Terminal window.
private final class PseudoTerminal {
    let devicePath: String
    private let primary: Int32

    init?() {
        primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else {
            if primary >= 0 { close(primary) }
            return nil
        }
        devicePath = String(cString: name)
    }

    deinit { close(primary) }
}

/// Children started with posix_spawn (Foundation's Process cannot give a child its own terminal,
/// and its overhead would blur the speed measurements). Keeps track of them so none is left behind.
private enum ChildProcesses {
    private static let pids = Shared(Set<Int32>())

    /// The tracked processes that still exist.
    static var alive: [Int32] { pids.value.filter { Darwin.kill($0, 0) == 0 }.sorted() }

    static func track(_ pid: Int32) { pids.update { $0.insert(pid) } }

    /// Starts a program. stdin is `input` (or /dev/null); stdout and stderr go to /dev/null. With
    /// `controllingTerminal`, the program runs in a new session whose terminal is that device, with
    /// the terminal on stdin, the way a program started in a terminal tab does.
    static func spawn(_ path: String, _ arguments: [String], environment: [String: String] = [:],
                      input: Int32? = nil, controllingTerminal: String? = nil) -> Int32? {
        if let controllingTerminal {
            // A session leader gets its terminal by opening it, so a shell leads the new session,
            // opens the device and then turns into the program (same process id).
            return spawn("/bin/sh", ["-c", "exec \"$@\" <\"$0\"", controllingTerminal, path] + arguments,
                         environment: environment, newSession: true)
        }
        return spawn(path, arguments, environment: environment, input: input, newSession: false)
    }

    /// Starts a program with stdin, stdout and stderr all closed, as a careless launcher might.
    static func spawnWithoutStandardDescriptors(_ path: String, _ arguments: [String], environment: [String: String]) -> Int32? {
        spawn(path, arguments, environment: environment, newSession: false, standardDescriptors: false)
    }

    private static func spawn(_ path: String, _ arguments: [String], environment: [String: String],
                              input: Int32? = nil, newSession: Bool, standardDescriptors: Bool = true) -> Int32? {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // Only the three standard descriptors set up below are passed on to the child.
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT
        if newSession { flags |= POSIX_SPAWN_SETSID }
        if standardDescriptors {
            if let input {
                posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
            } else {
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            }
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: Int32 = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { return nil }
        track(pid)
        return pid
    }

    /// Waits (keeping the main thread's queue running) for a child to exit. Returns its exit
    /// status, or nil if it had to be killed after `seconds`.
    @discardableResult
    static func waitForExit(_ pid: Int32, _ t: TestRunner, within seconds: TimeInterval = 10) -> Int32? {
        var status: Int32 = 0
        var reaped = false
        t.wait(seconds) {
            // (The harness asks once more after the answer turns true; a child can only be collected once.)
            if !reaped { reaped = waitpid(pid, &status, WNOHANG) == pid }
            return reaped
        }
        guard reaped else {
            kill(pid)
            return nil
        }
        return exitCode(status)
    }

    /// Blocks until the child exits (for use off the main thread).
    static func waitForExit(_ pid: Int32) -> Int32? {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { return nil } }
        return exitCode(status)
    }

    static func kill(_ pid: Int32) {
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    static func killAll() {
        for pid in alive { kill(pid) }
    }

    /// The exit code, or nil when the process was ended by a signal.
    private static func exitCode(_ status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}

/// One run of a program through Foundation's Process, with its output collected.
private final class ChildRun {
    struct Result {
        var status: Int32
        var outputData: Data
        var errorData: Data
        var seconds: TimeInterval
        var output: String { String(decoding: outputData, as: UTF8.self) }
        var errorText: String { String(decoding: errorData, as: UTF8.self) }
    }

    private let process = Process()
    private let started = Date()
    private let collectedOutput = Shared(Data())
    private let collectedErrors = Shared(Data())
    private let readers = DispatchGroup()

    var isRunning: Bool { process.isRunning }

    /// Starts the program. `input` is written to its stdin, which is then closed; nil means /dev/null.
    init(_ executable: URL, _ arguments: [String], environment: [String: String], input: Data? = nil, directory: URL? = nil) throws {
        let outPipe = Pipe(), errPipe = Pipe()
        let inPipe = input == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        ChildProcesses.track(process.processIdentifier)
        collect(outPipe, into: collectedOutput)
        collect(errPipe, into: collectedErrors)
        if let inPipe, let input {
            DispatchQueue.global().async {
                // Fails harmlessly when the program exits without reading everything.
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }

    /// Waits for the program to exit, keeping the main thread's queue running meanwhile (the
    /// server needs it). Nil if it had to be killed after `seconds`.
    func finish(_ t: TestRunner, within seconds: TimeInterval = 15) -> Result? {
        let exited = t.wait(seconds) { !self.process.isRunning }
        if !exited { kill() }
        process.waitUntilExit()
        readers.wait()
        guard exited else { return nil }
        return Result(status: process.terminationStatus, outputData: collectedOutput.value, errorData: collectedErrors.value,
                      seconds: Date().timeIntervalSince(started))
    }

    func kill() {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func collect(_ pipe: Pipe, into box: Shared<Data>) {
        readers.enter()
        DispatchQueue.global().async { [readers] in
            box.value = pipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
    }
}

// MARK: - Test support: running HookClient.run in-process, and timing the real helper

private struct ClientResult {
    var status: Int32
    var output: String
    var seconds: TimeInterval
}

/// Runs HookClient.run on a background thread with pipes standing in for stdin and stdout, while
/// the main thread keeps serving the HookServer under test. Nil if it did not return in time.
private func runClient(_ t: TestRunner, _ options: HookClient.Options, socketPath: String, input: String) -> ClientResult? {
    var inputEnds: [Int32] = [0, 0], outputEnds: [Int32] = [0, 0]
    guard pipe(&inputEnds) == 0, pipe(&outputEnds) == 0 else { return nil }
    _ = HookClient.writeAll(Data(input.utf8), to: inputEnds[1], timeout: 1)
    close(inputEnds[1])
    let status = Shared<Int32?>(nil)
    let started = Date()
    let (stdinEnd, stdoutEnd) = (inputEnds[0], outputEnds[1])
    DispatchQueue.global().async {
        status.value = HookClient.run(options, socketPath: socketPath, input: stdinEnd, output: stdoutEnd)
        close(stdoutEnd)
    }
    let returned = t.wait(10) { status.value != nil }
    let seconds = Date().timeIntervalSince(started)
    defer {
        close(inputEnds[0])
        close(outputEnds[0])
    }
    guard returned, let code = status.value else { return nil }
    let output = HookClient.readAll(from: outputEnds[0], idleTimeout: 1, limit: 1_000_000) ?? Data()
    return ClientResult(status: code, output: String(decoding: output, as: UTF8.self), seconds: seconds)
}

private struct Timing {
    var milliseconds: [Double]
    var failures: Int
    var fastest: Double { milliseconds.min() ?? .infinity }
    var median: Double { milliseconds.isEmpty ? .infinity : milliseconds.sorted()[milliseconds.count / 2] }
    var slowest: Double { milliseconds.max() ?? .infinity }
    var summary: String {
        String(format: "median %.2f ms, fastest %.2f ms, slowest %.2f ms over %d runs", median, fastest, slowest, milliseconds.count)
    }
}

/// Starts the helper with `input` on stdin, waits for it, and returns the wall-clock time in
/// milliseconds from just before the spawn to just after the exit (nil if it did not exit 0).
private func timeOneRun(_ path: String, _ arguments: [String], environment: [String: String], input: Data) -> Double? {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { return nil }
    _ = HookClient.writeAll(input, to: ends[1], timeout: 1)
    close(ends[1])
    defer { close(ends[0]) }
    let started = DispatchTime.now().uptimeNanoseconds
    guard let pid = ChildProcesses.spawn(path, arguments, environment: environment, input: ends[0]),
          ChildProcesses.waitForExit(pid) == 0 else { return nil }
    return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
}

/// Runs `one` a few times to warm up, then `runs` times for the record, on a background thread
/// (the main thread has to stay free to answer the helper, exactly as in the app).
private func measure(_ t: TestRunner, runs: Int, _ one: @escaping () -> Double?) -> Timing {
    let timing = Shared(Timing(milliseconds: [], failures: 0))
    let finished = Shared(false)
    DispatchQueue.global(qos: .userInitiated).async {
        for _ in 0..<5 { _ = one() }
        for _ in 0..<runs {
            let result = one()
            timing.update { if let result { $0.milliseconds.append(result) } else { $0.failures += 1 } }
        }
        finished.value = true
    }
    t.wait(60) { finished.value }
    return timing.value
}

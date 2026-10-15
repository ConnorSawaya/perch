// ClaudeLiveLimits.swift — asks Anthropic for your current Claude limits, so they stay up to date
// even when you only use the Claude app (which, unlike a terminal session, sends no status line).
//
// Off unless "Live Claude limits" is switched on in Settings. When on, every few minutes it:
//   1. reads the login Claude Code saved in your keychain ("Claude Code-credentials") through
//      macOS's own `security` tool, which that keychain item already trusts, so there is no password
//      prompt; the login is then kept in memory until it expires or Anthropic turns it down,
//   2. sends one request to Anthropic's usage endpoint with that login,
//   3. hands back the 5-hour and weekly percentages and their reset times.
// It never refreshes, changes or stores the login, and sends it nowhere but Anthropic. If the saved
// login has expired it simply waits until Claude Code renews it. When Anthropic says "too many
// requests" it backs off for a while. The endpoint is not a documented
// public API, so any failure is logged once and the other limit sources carry on as before.

import Foundation

enum ClaudeLiveLimits {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    enum Failure: Error, Equatable {
        case noSavedLogin
        case loginExpired
        case http(Int)
        case unreadableReply
        /// Anthropic asked us to slow down; no request was sent this time.
        case backingOff
    }

    /// The login in memory, so the keychain is read only when it changes. Guarded by `lock`.
    private static var cachedLogin: Login?
    /// No request before this time (set after a "too many requests" reply). Guarded by `lock`.
    private static var quietUntil = Date.distantPast
    private static let lock = NSLock()

    /// Reads the saved login and asks Anthropic. Runs on a background queue; calls back on main.
    static func fetch(completion: @escaping (Result<LimitReport, Failure>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let finish = { (result: Result<LimitReport, Failure>) in DispatchQueue.main.async { completion(result) } }
            if (lock.withLock { quietUntil }) > Date() { return finish(.failure(.backingOff)) }
            guard let login = currentLogin() else { return finish(.failure(.noSavedLogin)) }
            if let expires = login.expiresAt, expires < Date() { return finish(.failure(.loginExpired)) }
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 401 || status == 403 {
                    // Turned down: Claude Code has probably renewed its login. Read it again next time.
                    lock.withLock { cachedLogin = nil }
                }
                if status == 429 {
                    let wait = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 900
                    lock.withLock { quietUntil = Date().addingTimeInterval(min(max(wait, 300), 3600)) }
                }
                guard status == 200, let data else { return finish(.failure(.http(status))) }
                guard let report = parse(data, plan: login.plan, at: Date()) else { return finish(.failure(.unreadableReply)) }
                finish(.success(report))
            }.resume()
        }
    }

    /// The 5-hour and weekly windows from Anthropic's reply. Nil when neither is present.
    static func parse(_ data: Data, plan: String?, at now: Date) -> LimitReport? {
        guard let reply = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        let windows: [RateWindow] = [("five_hour", "5h", "5-hour limit"), ("seven_day", "7d", "Weekly limit")].compactMap { key, id, label in
            let entry = reply[key]
            guard let used = entry["utilization"].doubleValue, used.isFinite else { return nil }
            return RateWindow(id: id, label: label, usedPercent: min(max(used, 0), 100), resetsAt: date(entry["resets_at"].stringValue))
        }
        guard !windows.isEmpty else { return nil }
        return LimitReport(agent: .claude, windows: windows, planName: plan, capturedAt: now)
    }

    // MARK: The saved login

    struct Login {
        var accessToken: String
        var expiresAt: Date?
        var plan: String?
    }

    /// The login in memory if it is still good, otherwise a fresh read of the keychain.
    static func currentLogin(now: Date = Date()) -> Login? {
        if let cached = (lock.withLock { cachedLogin }), (cached.expiresAt ?? .distantFuture) > now.addingTimeInterval(60) {
            return cached
        }
        let fresh = savedLogin()
        lock.withLock { cachedLogin = fresh }
        return fresh
    }

    /// Claude Code's saved login, read with `/usr/bin/security`. Claude Code writes the item with that
    /// same tool, so the keychain lets it read it back without asking for your password (reading it
    /// directly from Perch would make macOS ask every time Claude Code renews the login).
    static func savedLogin() -> Login? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice
        do { try tool.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        return login(from: data)
    }

    static func login(from data: Data) -> Login? {
        let oauth = JSONValue.parse(String(decoding: data, as: UTF8.self))?["claudeAiOauth"] ?? .null
        guard let token = oauth["accessToken"].stringValue, !token.isEmpty else { return nil }
        let expires = oauth["expiresAt"].doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        let plan = oauth["subscriptionType"].stringValue.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return Login(accessToken: token, expiresAt: expires, plan: plan)
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        // Anthropic sends microseconds ("…:00.354604+00:00"); the parser only takes whole seconds.
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

// ContractTests.swift — checks the shared building blocks (JSON, wire format, settings).

import Foundation

func runContractTests(_ t: TestRunner) {
    t.test("JSONValue parses and reads nested values") {
        let json = try t.unwrap(JSONValue.parse(#"{"a":{"b":[1,"two",true,null]},"n":42,"f":1.5}"#))
        t.expectEqual(json["a"]["b"][0].intValue, 1)
        t.expectEqual(json["a"]["b"][1].stringValue, "two")
        t.expectEqual(json["a"]["b"][2].boolValue, true)
        t.expect(json["a"]["b"][3].isNull)
        t.expect(json["missing"]["deeper"].isNull, "missing keys chain to null")
        t.expectEqual(json["n"].intValue, 42)
        t.expectEqual(json["f"].doubleValue, 1.5)
        t.expectNil(JSONValue.parse("not json"))
    }

    t.test("JSONValue keeps integers as integers when printed") {
        let json: JSONValue = ["count": 3, "ok": true, "name": "x"]
        t.expectEqual(json.serialized(), #"{"count":3,"name":"x","ok":true}"#)
    }

    t.test("HookEnvelope survives a round trip as one line") {
        var env = HookEnvelope(agent: "claude")
        env.payload = "{\"hook_event_name\":\"Stop\",\n \"text\":\"line1\\nline2\"}"
        env.env = ["TERM_PROGRAM": "Apple_Terminal"]
        env.wantsReply = true
        let data = try JSONEncoder().encode(env)
        let line = try t.unwrap(String(data: data, encoding: .utf8))
        t.expect(!line.contains("\n"), "an encoded envelope must not contain a raw newline")
        t.expectEqual(try JSONDecoder().decode(HookEnvelope.self, from: data), env)
    }

    t.test("AppSettings saves and reloads") {
        let suite = "local.perch.tests.\(UUID().uuidString)"
        let defaults = try t.unwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = AppSettings(defaults: defaults)
        t.expectEqual(a.theme, .midnight)
        a.theme = .ember
        a.panelWidth = 640
        a.soundsEnabled = false
        let b = AppSettings(defaults: defaults)
        t.expectEqual(b.theme, .ember)
        t.expectEqual(b.panelWidth, 640)
        t.expectEqual(b.soundsEnabled, false)
        b.resetToDefaults()
        t.expectEqual(b.theme, .midnight)
        t.expectEqual(AppSettings(defaults: defaults).soundsEnabled, true)
    }

    t.test("quiet hours wrap past midnight") {
        let suite = "local.perch.tests.\(UUID().uuidString)"
        let defaults = try t.unwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.quietHoursEnabled = true
        s.quietStartHour = 22
        s.quietEndHour = 8
        var parts = DateComponents(year: 2026, month: 10, day: 12, hour: 23)
        t.expect(s.inQuietHours(at: try t.unwrap(Calendar.current.date(from: parts))))
        parts.hour = 12
        t.expect(!s.inQuietHours(at: try t.unwrap(Calendar.current.date(from: parts))))
    }

    t.test("SessionStore headline prefers sessions that need the user") {
        let store = SessionStore()
        let now = Date()
        func make(_ id: String, _ state: SessionState, _ at: Date) -> Session {
            Session(id: Session.makeID(.claude, id), agent: .claude, sessionID: id, cwd: "/tmp/\(id)", title: id,
                    state: state, stateSince: at, startedAt: at, lastEventAt: at)
        }
        store.sessions = [make("a", .working, now), make("b", .needsApproval, now.addingTimeInterval(-60)), make("c", .done, now)]
        t.expectEqual(store.headline?.sessionID, "b")
        t.expectEqual(store.attentionCount, 1)
        t.expectEqual(store.busyCount, 1)
    }
}

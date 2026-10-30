import Foundation

// `brim selftest`: the logic that needs no screen and no network.

enum Selftest {
    static var failures = 0
    static var checks = 0

    static func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok { failures += 1; print("  FAIL \(what) (line \(line))") }
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)    // so a crash can't swallow the FAIL lines before it
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Claude: the newer `limits` list.
        let claude: [String: Any] = [
            "five_hour": ["utilization": 99.0, "resets_at": "2026-10-17T00:40:00.163298+00:00"],
            "limits": [
                ["kind": "session", "percent": 17, "resets_at": "2026-10-17T00:40:00.163298+00:00"],
                ["kind": "weekly_all", "percent": 21, "resets_at": "2026-10-18T19:00:00.163320+00:00"],
                ["kind": "weekly_scoped", "percent": 2, "resets_at": "2026-10-18T19:00:00+00:00",
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ]
        let cw = Claude.parse(claude)
        expect(cw.count == 3, "claude limits → 3 windows")
        expect(cw.first?.kind == .session && cw.first?.percent == 17, "claude session prefers limits list")
        expect(cw.first?.resetsAt != nil, "microsecond dates parse")
        expect(cw.last?.label == "Fable" && cw.last?.kind == .model, "scoped model window")

        // Claude: legacy shape only.
        let legacy = Claude.parse(["five_hour": ["utilization": 40.0, "resets_at": "2026-10-17T00:40:00Z"],
                                   "seven_day": ["utilization": 10.0, "resets_at": NSNull()], "seven_day_opus": NSNull()])
        expect(legacy.count == 2 && legacy[1].resetsAt == nil, "legacy five_hour/seven_day")

        // Codex.
        let codex: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": ["primary_window": ["used_percent": 7, "limit_window_seconds": 18000, "reset_after_seconds": 476, "reset_at": 1_800_000_476],
                           "secondary_window": ["used_percent": 34, "limit_window_seconds": 604800, "reset_after_seconds": 9, "reset_at": NSNull()]],
            "rate_limit_reset_credits": ["available_count": 2],
        ]
        let cx = Codex.parse(codex, now: now)
        expect(cx.windows.count == 2 && cx.windows[0].kind == .session && cx.windows[1].kind == .weekly, "codex windows")
        expect(cx.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_476), "codex reset_at")
        expect(cx.windows[1].resetsAt == now.addingTimeInterval(9), "codex reset_after fallback")
        expect(cx.plan == "plus" && cx.credits == 2, "codex plan + credits")

        // Pace.
        let half = UsageWindow(kind: .session, label: "Session", percent: 80, resetsAt: now.addingTimeInterval(2.5 * 3600), length: 5 * 3600)
        expect(abs((half.elapsed(at: now) ?? 0) - 0.5) < 0.001, "elapsed half")
        expect(abs((half.projected(at: now) ?? 0) - 160) < 0.5, "projected 160%")
        let out = half.runsOut(at: now)
        expect(out != nil && abs(out!.timeIntervalSince(now) - 0.625 * 3600) < 2, "runs out in 37.5m")
        let slow = UsageWindow(kind: .session, label: "Session", percent: 20, resetsAt: now.addingTimeInterval(2.5 * 3600), length: 5 * 3600)
        expect(slow.runsOut(at: now) == nil, "slow pace never runs out")

        // Formatting.
        expect(Fmt.duration(59) == "now" && Fmt.duration(7 * 60) == "7m", "duration minutes")
        expect(Fmt.duration(2 * 3600 + 14 * 60) == "2h14" && Fmt.duration(3600) == "1h", "duration hours")
        expect(Fmt.duration(3 * 86400 + 4 * 3600) == "3d 4h", "duration days")
        expect(Fmt.plan("default_claude_max_20x") == "Max 20×" && Fmt.plan("plus") == "Plus", "plan names")
        expect(SignIn.defaultLabel("adam@auernet.com") == "Auernet" && SignIn.defaultLabel("bob@gmail.com") == "Bob", "default labels")

        // Alerts.
        let a = Account(id: "a", provider: .claude, source: .signIn, label: "Personal")
        var s = Settings(); s.thresholds = [80, 95]
        let reset = now.addingTimeInterval(3600)
        func u(_ sp: Double, _ wp: Double, wr: Date = now.addingTimeInterval(5 * 86400), sr: Date? = nil) -> Usage {
            Usage(accountId: "a", fetchedAt: now, windows: [
                UsageWindow(kind: .session, label: "Session", percent: sp, resetsAt: sr ?? reset, length: 5 * 3600),
                UsageWindow(kind: .weekly, label: "Week", percent: wp, resetsAt: wr, length: 7 * 86400)])
        }
        var fired = Set<String>()
        let first = Alerts.evaluate(account: a, old: u(50, 10), new: u(82, 10), settings: s, fired: fired, now: now)
        expect(first.count == 1 && first[0].kind == .threshold && first[0].title.contains("82%"), "threshold 80 fires")
        first.forEach { fired.insert($0.key) }
        let again = Alerts.evaluate(account: a, old: u(82, 10), new: u(84, 10), settings: s, fired: fired, now: now)
        expect(again.isEmpty, "same threshold, same cycle: quiet")
        let higher = Alerts.evaluate(account: a, old: u(84, 10), new: u(96, 10), settings: s, fired: fired, now: now)
        expect(higher.count == 1 && higher[0].key.contains(":95:"), "95 fires once")
        let lo = Alerts.evaluate(account: a, old: nil, new: u(0, 40, wr: now.addingTimeInterval(5 * 3600)), settings: s, fired: [], now: now)
        expect(lo.contains { $0.kind == .leftover }, "leftover: 60% left, resets in 5h")
        let past = now.addingTimeInterval(-30)
        let rs = Alerts.evaluate(account: a, old: u(70, 10, sr: past), new: u(0, 10, sr: now.addingTimeInterval(5 * 3600)), settings: s, fired: [], now: now)
        expect(rs.contains { $0.kind == .reset }, "reset detected")
        var c1 = u(0, 0); c1.resetCredits = 1
        var c2 = u(0, 0); c2.resetCredits = 2
        expect(Alerts.evaluate(account: a, old: c1, new: c2, settings: s, fired: [], now: now).contains { $0.kind == .credits }, "new reset credit")
        var na = u(0, 0); na.needsAuth = true
        expect(Alerts.evaluate(account: a, old: u(0, 0), new: na, settings: s, fired: [], now: now).contains { $0.kind == .auth }, "auth alert")

        // Settings decode tolerates junk and old files.
        let st = try? JSON.decoder.decode(Settings.self, from: Data(#"{"refreshSeconds": 5, "thresholds": [120, 90, "x"]}"#.utf8))
        expect(st?.refreshSeconds == 60, "refresh clamped to 60s")
        expect(st?.thresholds == Settings().thresholds, "bad thresholds fall back")
        let st2 = try? JSON.decoder.decode(Settings.self, from: Data(#"{"thresholds": [95, 50]}"#.utf8))
        expect(st2?.thresholds == [50, 95] && st2?.pager == true, "thresholds sorted, defaults kept")

        // JWT claims.
        let payload = Data(#"{"exp": 1800000000, "https://api.openai.com/auth": {"chatgpt_account_id": "acc"}}"#.utf8).base64url
        expect(Codex.auth("x.\(payload).y")["chatgpt_account_id"] as? String == "acc", "jwt claims")

        // PKCE.
        let p = PKCE()
        expect(p.verifier.count >= 43 && !p.challenge.contains("=") && p.state.count > 10, "pkce shape")

        // OpenRouter.
        let ob = OpenRouter.parse(key: ["usage_daily": 3.2, "usage_weekly": 10, "limit": NSNull(), "limit_remaining": NSNull()],
                                  credits: ["total_credits": 100, "total_usage": 57.5])
        expect(ob.remaining == 42.5 && ob.total == 100 && abs((ob.usedPercent ?? 0) - 57.5) < 0.001 && ob.today == 3.2, "openrouter credits")
        let capped = OpenRouter.parse(key: ["limit": 20, "limit_remaining": 4], credits: ["total_credits": 100, "total_usage": 10])
        expect(capped.remaining == 4 && capped.total == 20, "key limit wins when tighter")
        let nocred = OpenRouter.parse(key: ["usage_daily": 1], credits: nil)
        expect(nocred.remaining == nil && nocred.today == 1, "no credits access")
        var bs = Settings(); bs.lowBalance = 5
        let ora = Account(id: "o", provider: .openrouter, source: .apiKey, label: "OpenRouter")
        let low = Alerts.evaluate(account: ora, old: nil, new: Usage(accountId: "o", fetchedAt: now, balance: Balance(remaining: 3.4, total: 50)),
                                  settings: bs, fired: [], now: now)
        expect(low.count == 1 && low[0].kind == .balance && low[0].title.contains("$3.40"), "low balance alert")
        expect(Fmt.money(42.1) == "$42.10" && Fmt.money(1234) == "$1.2k", "money")

        // Notch geometry: the wings always leave the camera housing's width free.
        MainActor.assumeIsolated {
            let m = NotchModel()
            for w in [150.0, 160, 185, 200] {
                m.notchWidth = w
                let c = m.collapsedSize
                let wing = (c.width - 2 * NotchModel.topRadius - w) / 2
                expect(wing >= 54, "collapsed wing \(wing) fits the reset label for notch \(w)")
                m.open = true
                let o = m.openSize(rows: 3)
                expect((o.width - 2 * NotchModel.topRadius - w) / 2 >= 100, "open wing fits the buttons for notch \(w)")
                m.open = false
            }
        }

        migration()
        switching()

        print(failures == 0 ? "selftest ok (\(checks) checks)" : "selftest: \(failures) of \(checks) checks failed")
        return failures == 0
    }
}

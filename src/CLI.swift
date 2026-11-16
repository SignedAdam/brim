import Foundation

enum CLI {
    static func help() {
        print("""
        brim \(VERSION) — AI subscription usage, around the notch

          brim                      run (the notch); one per user
          brim status [<account>…] [--json] [--fresh]
                                    usage per account, or just the ones named. --fresh fetches
                                    now instead of reading what the running app saw last
          brim list [--json]        accounts, the tools holding each, and the logins parked
          brim where [--json]       what each tool (Claude Code, Codex, Hermes, OMP) is
                                    signed in as, and the logins Brim has parked
          brim switch <account> <tool>…|all [--no-open] [--json]
                                    sign tools (claude-code, codex, hermes, omp) in as <account>;
                                    all = every tool here that takes it. The previous login is
                                    parked, so switching back needs no new sign-in; --no-open
                                    prints the sign-in link if one is needed
          brim reset <account> [--yes] [--json]
                                    use one of an account's banked limit resets (Claude or
                                    ChatGPT); asks first unless --yes. Can't be undone
          brim log [-n N] [--kind K,…] [--account A] [--since 2h] [--json] [-f]
                                    switches, sign-ins, account changes, token refreshes, fetch
                                    errors, resets and alerts; -f keeps printing new events.
                                    K: \(Event.Kind.allCases.map(\.rawValue).joined(separator: " ")),
                                    or error for failures only
          brim add claude|codex [--label NAME] [--no-open]
                                    sign in to another account in the browser; --no-open
                                    prints the sign-in link instead of opening it
          brim add openrouter [--env VAR] [--label NAME]
                                    an OpenRouter key: from stdin, or tracked by env var name
          brim rename <account> <label>
          brim hide <account>       leave it out of the notch and status; brim show brings it back
          brim remove <account>     <account> = label, email or id prefix
          brim alerts [-n N]        recent alerts, JSON lines
          brim install              run at login (LaunchAgent); brim uninstall
          brim quit                 stop the running app
          brim snapshot <png> [--open] [--flash] [--live]
                                    render the notch offscreen

        Files live in ~/.brim (BRIM_HOME moves them). Alert hooks: settings.json "hooks",
        each a shell command that gets the alert as JSON on stdin and in $BRIM_ALERT.
        JSON is the default output when stdout isn't a terminal.
        """)
    }

    static func await_<T>(_ f: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await f()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try result!.get()
    }

    static func accounts() -> [Account] { Accounts.load() }

    static func scanned() -> Store {
        let st = MainActor.assumeIsolated { Store(load: true) }
        try? await_ { await st.scan() }
        MainActor.assumeIsolated { st.discover() }
        return st
    }

    static func matches(_ q: String, in list: [Account]) -> [Account] {
        let l = q.lowercased()
        let exact = list.filter { $0.label.lowercased() == l || $0.email?.lowercased() == l }
        return exact.isEmpty ? list.filter { $0.id.lowercased().hasPrefix(l) } : exact
    }

    static func account(_ q: String, in list: [Account]) -> Account {
        let m = matches(q, in: list)
        guard let a = m.first else { fail("no account \(q)") }
        if m.count > 1 { ambiguous(q, m) }
        return a
    }

    static func ambiguous(_ q: String, _ m: [Account]) -> Never {
        fail("\(q) could be " + m.map { "\($0.id.prefix(8)) (\($0.provider.name))" }.joined(separator: " or ") + "; name it by id prefix")
    }

    static func fail(_ s: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("brim: \(s)\n".utf8))
        exit(code)
    }

    static var json = false

    static func say(_ s: String) {
        let out = json ? stderr : stdout
        fputs(s + "\n", out)
        fflush(out)
    }

    static func wantsJSON(_ args: [String]) -> Bool { args.contains("--json") || isatty(1) == 0 }

    static func value(_ flag: String, _ args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    static func printJSON(_ o: Any) {
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    static func loadUsage() -> [String: Usage] {
        Dictionary((JSON.load([Usage].self, Paths.usage) ?? []).map { ($0.accountId, $0) }, uniquingKeysWith: { $1 })
    }

    static func notify() { if let pid = Lock.running() { kill(pid, SIGHUP) } }

    static func signal(_ s: Int32, _ what: String) {
        if let pid = Lock.running() { kill(pid, s); print("\(what): sent to \(pid)") } else { print("brim is not running") }
    }

    static func status(_ args: [String]) {
        let st = scanned()
        let all = MainActor.assumeIsolated { st.accounts }
        let named = args.filter { !$0.hasPrefix("-") }
        let list = named.isEmpty ? all.filter { !$0.isHidden } : named.flatMap { q -> [Account] in
            let m = matches(q, in: all)
            guard !m.isEmpty else { fail("no account \(q)") }
            return m
        }
        var usage = loadUsage()
        if args.contains("--fresh") || usage.isEmpty {
            if let pid = Lock.running() {
                let before = (try? Paths.usage.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                kill(pid, SIGUSR1)
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    usleep(200_000)
                    let m = (try? Paths.usage.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if m != before { break }
                }
                usage = loadUsage()
            } else {
            let todo = MainActor.assumeIsolated { list.map { ($0, st.borrowed($0, now: Date())) } }
            let results: [(Usage, Account)] = (try? await_ { () async -> [(Usage, Account)] in
                await withTaskGroup(of: (Usage, Account).self) { g in
                    for (a, b) in todo { g.addTask { await Fetcher.fetch(a, borrowed: b) } }
                    var out: [(Usage, Account)] = []
                    for await r in g { out.append(r) }
                    return out
                }
            }) ?? []
            for (u, a) in results {
                usage[u.accountId] = u
                adopt(a)
            }
            JSON.save(Array(usage.values), Paths.usage)
            }
        }
        let now = Date()
        if wantsJSON(args) {
            printJSON(list.map { describe($0, usage[$0.id], now: now) })
            return
        }
        if list.isEmpty { print("no accounts. brim add claude|codex"); return }
        let w = list.map(\.label.count).max() ?? 8
        for a in list { print(line(a, usage[a.id], width: w, now: now)) }
    }

    static func adopt(_ a: Account) {
        var all = accounts()
        guard let i = all.firstIndex(where: { $0.id == a.id }),
              (all[i].accessToken, all[i].refreshToken, all[i].expiresAt) != (a.accessToken, a.refreshToken, a.expiresAt) else { return }
        (all[i].accessToken, all[i].refreshToken, all[i].expiresAt) = (a.accessToken, a.refreshToken, a.expiresAt)
        JSON.save(all, Paths.accounts)
    }

    static func describe(_ a: Account, _ u: Usage?, now: Date) -> [String: Any] {
        var o: [String: Any] = ["id": a.id, "label": a.label, "provider": a.provider.rawValue, "source": a.source.rawValue]
        if let e = a.email { o["email"] = e }
        if let p = Fmt.plan(a.plan ?? u?.plan, a.provider) { o["plan"] = p }
        if a.isHidden { o["hidden"] = true }
        guard let u else { return o }
        o["fetched_at"] = ISO8601DateFormatter().string(from: u.fetchedAt)
        if let e = u.error { o["error"] = e }
        if u.needsAuth == true { o["needs_auth"] = true }
        if let c = u.resetCredits { o["reset_credits"] = c }
        if let g = u.resetNext { o["next_reset"] = ["label": g.label, "clears": u.resetClears] }
        if let b = u.balance {
            var d: [String: Any] = ["currency": "USD"]
            if let v = b.remaining { d["remaining"] = v }
            if let v = b.total { d["total"] = v }
            if let v = b.today { d["spent_today"] = v }
            if let v = b.week { d["spent_week"] = v }
            o["balance"] = d
        }
        o["windows"] = u.windows.map { w -> [String: Any] in
            var d: [String: Any] = ["kind": w.kind.rawValue, "label": w.label, "percent": w.percent,
                                    "left_percent": max(0, 100 - w.percent)]
            if let r = w.resetsAt {
                d["resets_at"] = ISO8601DateFormatter().string(from: r)
                d["resets_in_seconds"] = Int(r.timeIntervalSince(now))
            }
            if let p = w.projected(at: now) { d["projected_percent"] = (p * 10).rounded() / 10 }
            if let r = w.runsOut(at: now) { d["runs_out_at"] = ISO8601DateFormatter().string(from: r) }
            return d
        }
        return o
    }

    static func line(_ a: Account, _ u: Usage?, width w: Int, now: Date) -> String {
        var line = a.label.padding(toLength: w + 2, withPad: " ", startingAt: 0)
        if let u, u.needsAuth == true { line += "sign in again (\(u.error ?? ""))" }
        else if let u, !u.hasData, let e = u.error { line += "error: \(e)" }
        else if let u, let b = u.balance {
            line += "balance \(b.usedPercent.map { bar($0) } ?? "")  \(b.remaining.map(Fmt.money) ?? "?") left"
            if let t = b.today { line += "   today \(Fmt.money(t))" }
        }
        else if let u {
            line += u.windows.filter { $0.kind != .model || $0.percent >= 1 }.map { win in
                let bar = bar(win.percent)
                let r = Fmt.reset(win.resetsAt, now: now)
                return "\(win.label.lowercased()) \(bar) \(String(format: "%3d", Int(win.percent.rounded())))%\(r.isEmpty ? "" : "  ↻ \(r)")"
            }.joined(separator: "   ")
            if let c = u.resetCredits, c > 0 { line += "   \(c) reset\(c == 1 ? "" : "s") banked" }
        } else { line += "no data yet" }
        return line
    }

    static func bar(_ pct: Double) -> String {
        let n = Int((min(pct, 100) / 100 * 10).rounded())
        return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n)
    }

    static func list(_ args: [String]) {
        let st = scanned()
        let (all, holdings, parked) = MainActor.assumeIsolated { (st.accounts, st.holdings, st.parked) }
        func holding(_ a: Account) -> [Tool] {
            Tool.allCases.filter { t in holdings.contains { $0.tool == t && $0.account != nil && $0.account == a.key && $0.dead == nil } }
        }
        func parkedFor(_ a: Account) -> [Tool] {
            Tool.allCases.filter { t in parked.contains { $0.tool == t && $0.account == a.key && Switcher.usable($0, Date()) } }
        }
        if wantsJSON(args) {
            printJSON(all.map { a -> [String: Any] in
                var o: [String: Any] = ["id": a.id, "label": a.label, "provider": a.provider.rawValue, "source": a.source.rawValue,
                                        "hidden": a.isHidden, "tools": holding(a).map(\.rawValue), "parked": parkedFor(a).map(\.rawValue)]
                if let e = a.email { o["email"] = e }
                if let p = Fmt.plan(a.plan, a.provider) { o["plan"] = p }
                if let k = a.keyVar { o["key_var"] = k }
                return o
            })
            return
        }
        for a in all {
            let tools = holding(a).map(\.name)
            var src = a.source == .signIn ? ["signed in to brim"] : []
            if a.source == .apiKey { src = [a.keyVar.map { "key from $\($0)" } ?? "stored key"] }
            else { src.append(tools.isEmpty ? "no tool holds it" : "in " + tools.joined(separator: ", ")) }
            let p = parkedFor(a).map(\.name)
            if !p.isEmpty { src.append("parked for " + p.joined(separator: ", ")) }
            print("\(a.id.prefix(8))  \(a.label)\(a.isHidden ? " (hidden)" : "")  \(a.provider.name) · \(a.email ?? "-") · \(src.joined(separator: ", "))")
        }
    }

    static func whereNow(_ args: [String]) {
        let st = scanned()
        let w = MainActor.assumeIsolated { Where.now(accounts: st.accounts, holdings: st.holdings, vault: Vault.load()) }
        if args.contains("--json") || isatty(1) == 0 {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            e.dateEncodingStrategy = .iso8601
            print(String(decoding: try! e.encode(w), as: UTF8.self))
            return
        }
        let now = Date()
        func exp(_ d: Date?) -> String {
            guard let d else { return "" }
            return d > now ? "  expires in \(Fmt.duration(d.timeIntervalSince(now)))" : "  expired"
        }
        for t in w.tools {
            let place = t.location.map { " [\($0)]" } ?? ""
            let who = t.label ?? t.email ?? "-"
            print("\(t.tool.name)\(place)  \(t.provider.name)  \(who)  \(t.state.prefix(120))\(exp(t.expiresAt))")
        }
        if w.tools.isEmpty { print("no tool on this Mac holds a Claude or Codex login") }
        for s in w.vault {
            print("vault  \(s.label ?? s.account) for \(s.tool.name)  \(s.state)\(exp(s.expiresAt))")
        }
    }

    static func switchTool(_ args: [String]) {
        let open = !args.contains("--no-open")
        json = args.contains("--json")
        let args = args.filter { !$0.hasPrefix("--") }
        let usage = "usage: brim switch <account> <tool>…|all [--no-open] [--json]   tool: \(Tool.allCases.map(\.rawValue).joined(separator: ", "))"
        guard args.count >= 2 else { fail(usage, code: 2) }
        let st = scanned()
        let found = matches(args[0], in: MainActor.assumeIsolated { st.accounts })
        guard !found.isEmpty else { fail("no account \(args[0])") }
        var plan: [(tool: Tool, account: String)] = []
        for name in args.dropFirst() {
            let all = name == "all"
            guard let tools = all ? Tool.allCases.filter(\.installed) : Tool(rawValue: name).map({ [$0] }) else { fail(usage, code: 2) }
            for t in tools {
                let fits = found.filter { t.providers.contains($0.provider) }
                if fits.isEmpty, !all { fail("\(t.name) doesn't take \(Set(found.map(\.provider.name)).sorted().joined(separator: " or ")) accounts") }
                if Set(fits.map(\.provider)).count < fits.count { ambiguous(args[0], fits) }
                for a in fits where !plan.contains(where: { $0.tool == t && $0.account == a.id }) { plan.append((t, a.id)) }
            }
        }
        guard !plan.isEmpty else { fail("no tool on this Mac takes \(args[0])") }
        var results: [[String: Any]] = []
        for (tool, id) in plan {
            guard let a = accounts().first(where: { $0.id == id }) ?? found.first(where: { $0.id == id }) else { continue }
            if Switcher.needsSignIn(tool, a) {
                say(open ? "Opening your browser to sign \(tool.name) in as \(a.label)…" : "Open this to sign \(tool.name) in as \(a.label):")
            }
            var r: [String: Any] = ["tool": tool.rawValue, "account": a.id, "label": a.label, "provider": a.provider.rawValue]
            do {
                let line = try await_ {
                    try await Switcher.run(tool, to: a, open: open) {
                        var all = accounts()
                        guard let j = all.firstIndex(where: { $0.id == a.id }) else { return }
                        all[j].source = .tool
                        (all[j].accessToken, all[j].refreshToken, all[j].expiresAt) = (nil, nil, nil)
                        JSON.save(all, Paths.accounts)
                    }
                }
                say(line)
                if let p = tool.pickup { say(p) }
                r["ok"] = true
            } catch {
                FileHandle.standardError.write(Data("brim: switching \(tool.name) to \(a.label) failed: \(error)\n".utf8))
                r["ok"] = false
                r["error"] = "\(error)"
            }
            results.append(r)
        }
        if results.contains(where: { $0["ok"] as? Bool == true }) { notify() }
        if json { printJSON(results) }
        if results.contains(where: { $0["ok"] as? Bool == false }) { exit(1) }
    }

    static func add(_ args: [String]) {
        guard let p = args.first.flatMap(Provider.init(rawValue:)) else { print("usage: brim add claude|codex|openrouter [--label NAME] [--no-open]"); exit(2) }
        let label = value("--label", args)
        if p == .openrouter {
            let envVar = value("--env", args)
            let key: String?
            if let envVar { key = OpenRouter.env(envVar) }
            else if isatty(0) != 0 { key = String(cString: getpass("OpenRouter key: ")) }
            else { key = readLine() }
            guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                print(envVar.map { "\($0) is not set" } ?? "no key"); exit(1)
            }
            do {
                let a = try await_ { try await SignIn.openRouter(key: key, keyVar: envVar, label: label) }
                save(a)
            } catch {
                Events.record(.signIn, "OpenRouter key", failure: error)
                print("key rejected: \(error)"); exit(1)
            }
            return
        }
        let open = !args.contains("--no-open")
        print(open ? "Opening your browser to sign in to \(p.name)…" : "Open this to sign in to \(p.name):")
        fflush(stdout)
        do {
            let a = try await_ { try await SignIn.run(p, label: label, open: open) }
            save(a)
        } catch {
            Events.record(.signIn, "\(p.name) sign-in", failure: error)
            print("sign-in failed: \(error)"); exit(1)
        }
    }

    static func save(_ a: Account) {
        do {
            let list = try Accounts.adding(a, to: accounts())
            JSON.save(list, Paths.accounts)
        } catch {
            Events.record(.signIn, "add \(a.label)", failure: error)
            print(error); exit(1)
        }
        Events.record(.signIn, "added\(a.email.map { " \($0)" } ?? "")", account: a)
        notify()
        print("added \(a.label)\(a.email.map { " (\($0))" } ?? "")")
    }

    static func rename(_ args: [String]) {
        guard args.count >= 2 else { print("usage: brim rename <account> <label>"); exit(2) }
        let st = MainActor.assumeIsolated { Store(load: true) }
        let a = account(args[0], in: MainActor.assumeIsolated { st.accounts })
        let label = args.dropFirst().joined(separator: " ")
        MainActor.assumeIsolated { st.rename(a.id, to: label) }
        notify()
        print("renamed to \(label)")
    }

    static func remove(_ args: [String]) {
        guard let q = args.first else { print("usage: brim remove <account>"); exit(2) }
        let st = scanned()
        let a = account(q, in: MainActor.assumeIsolated { st.accounts })
        MainActor.assumeIsolated { st.remove(a.id) }
        notify()
        print("removed \(a.label)")
    }

    static func setHidden(_ args: [String], _ hidden: Bool) {
        guard let q = args.first else { print("usage: brim \(hidden ? "hide" : "show") <account>"); exit(2) }
        let st = MainActor.assumeIsolated { Store(load: true) }
        let a = account(q, in: MainActor.assumeIsolated { st.accounts })
        if a.isHidden != hidden { MainActor.assumeIsolated { hidden ? st.hide(a.id) : st.restore(a.id) } }
        notify()
        print(hidden ? "\(a.label) is hidden" : "\(a.label) is shown")
    }

    static func reset(_ args: [String]) {
        json = args.contains("--json")
        guard let q = args.first(where: { !$0.hasPrefix("-") }) else { fail("usage: brim reset <account> [--yes] [--json]", code: 2) }
        let st = scanned()
        let found = matches(q, in: MainActor.assumeIsolated { st.accounts })
        guard !found.isEmpty else { fail("no account \(q)") }
        let banking = found.filter { $0.provider != .openrouter }
        guard let a = banking.first else { fail("OpenRouter keys don't bank limit resets") }
        if banking.count > 1 { ambiguous(q, banking) }
        var usage = loadUsage()
        let before = usage[a.id]?.resetCredits
        if before == 0 { fail("\(a.label) has no banked resets") }
        if !args.contains("--yes") {
            guard isatty(0) != 0 else { fail("pass --yes to use a reset without being asked", code: 2) }
            let n = before.map { "one of \(a.label)'s \($0) banked resets" } ?? "a banked reset on \(a.label)"
            let what = usage[a.id].map { u in (u.resetNext.map { "\($0.label). It" } ?? "It") + " clears \(u.resetClears)" } ?? "It clears the account's limits"
            fputs("Use \(n)? \(what) and can't be undone. [y/N] ", stderr)
            guard readLine()?.lowercased().hasPrefix("y") == true else { fail("nothing used") }
        }
        let borrowed = MainActor.assumeIsolated { st.borrowed(a, now: Date()) }
        var acct: Account
        do {
            acct = try await_ { try await Fetcher.useReset(a, borrowed: borrowed) }
        } catch {
            Events.record(.reset, "use a banked reset", failure: error, account: a)
            fail("using a reset on \(a.label) failed: \(error)")
        }
        Events.record(.reset, "used a banked reset", account: a)
        adopt(acct)
        say("used a reset on \(a.label)")
        var fresh: Usage?
        for wait in [1.0, 3, 8] {
            usleep(useconds_t(wait * 1_000_000))
            let current = acct
            let b = MainActor.assumeIsolated { st.borrowed(current, now: Date()) }
            guard let r = try? await_({ await Fetcher.fetch(current, borrowed: b) }) else { continue }
            let (u, next) = r
            acct = next
            adopt(acct)
            if u.hasData, before.map({ (u.resetCredits ?? 0) < $0 }) ?? true { fresh = u; break }
        }
        if let fresh {
            usage[a.id] = fresh
            JSON.save(Array(usage.values), Paths.usage)
        }
        notify()
        if json { printJSON(describe(a, fresh, now: Date())); return }
        if let fresh { print(line(a, fresh, width: a.label.count, now: Date())) }
        else { print("\(a.provider.company) hasn't updated \(a.label)'s usage yet; brim status shows it once it does") }
    }

    static func events(_ args: [String]) {
        let kinds = value("--kind", args).map { $0.lowercased().split(separator: ",").map(String.init) } ?? []
        let valid = Event.Kind.allCases.map(\.rawValue) + ["error"]
        if let bad = kinds.first(where: { !valid.contains($0) }) { fail("unknown kind \(bad); one of \(valid.joined(separator: ", "))", code: 2) }
        let who = value("--account", args).map { q in (ids: Set(matches(q, in: accounts()).map(\.id)), name: q.lowercased()) }
        var since: Date?
        if let s = value("--since", args) {
            guard let d = parseSince(s) else { fail("can't read --since \(s); try 30m, 2h, 7d or 2026-11-13", code: 2) }
            since = d
        }
        var n = 50
        if let s = value("-n", args) {
            guard let v = Int(s) else { fail("-n wants a number", code: 2) }
            n = v
        }
        let asJSON = wantsJSON(args)
        func keep(_ e: Event) -> Bool {
            if let since, e.at < since { return false }
            if !kinds.isEmpty, !kinds.contains(e.kind.rawValue), !(kinds.contains("error") && e.error != nil) { return false }
            if let who, !(e.account.map(who.ids.contains) ?? false), e.label?.lowercased() != who.name { return false }
            return true
        }
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func show(_ e: Event) {
            if asJSON { print(String(decoding: try! JSONEncoder.compact.encode(e), as: UTF8.self)); return }
            var s = "\(time.string(from: e.at))  \(e.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
            s += e.error == nil ? "  " : "✗ "
            if let l = e.label, e.kind != .switched, e.kind != .alert { s += "\(l): " }
            s += e.text
            if let f = e.from { s += " (was \(f))" }
            if let err = e.error { s += ": \(err)" }
            if e.via == "cli" { s += "  · cli" }
            print(s)
        }
        let data = (try? Data(contentsOf: Paths.events)) ?? Data()
        Events.parse(data).filter(keep).suffix(n).forEach(show)
        guard args.contains("-f") || args.contains("--follow") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        var offset = UInt64(data.count)
        var partial = Data()
        while true {
            usleep(500_000)
            guard let h = try? FileHandle(forReadingFrom: Paths.events) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            if size < offset { offset = 0; partial = Data() }
            try? h.seek(toOffset: offset)
            guard let more = try? h.readToEnd(), !more.isEmpty else { try? h.close(); continue }
            try? h.close()
            offset += UInt64(more.count)
            partial += more
            guard let last = partial.lastIndex(of: 0x0a) else { continue }
            Events.parse(partial[...last]).filter(keep).forEach(show)
            partial = Data(partial[(last + 1)...])
        }
    }

    static func parseSince(_ s: String) -> Date? {
        if let unit = s.last, let k = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit)], let v = Double(s.dropLast()) {
            return Date().addingTimeInterval(-v * k)
        }
        if let d = JSON.parseDate(s) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func alerts(_ args: [String]) {
        let n = value("-n", args).flatMap(Int.init) ?? 20
        let lines = ((try? String(contentsOf: Paths.alerts, encoding: .utf8)) ?? "").split(separator: "\n")
        lines.suffix(n).forEach { print($0) }
    }
}

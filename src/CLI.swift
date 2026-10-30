import Foundation

// Command-line side: what agents and scripts use.

enum CLI {
    static func help() {
        print("""
        brim \(VERSION) — AI subscription usage, around the notch

          brim                      run (the notch); one per user
          brim status [--json] [--fresh]
                                    usage per account. --fresh fetches now instead of
                                    reading what the running app saw last
          brim list                 accounts and which tools hold them
          brim where [--json]       what each tool (Claude Code, Codex, Hermes, OMP) is
                                    signed in as, and the logins Brim has parked
          brim switch <account> claude-code|codex|hermes|omp
                                    sign that tool in as <account>; the previous login is
                                    parked, so switching back needs no new sign-in
          brim add claude|codex [--label NAME]
                                    sign in to another account in the browser
          brim add openrouter [--env VAR] [--label NAME]
                                    an OpenRouter key: from stdin, or tracked by env var name
          brim rename <account> <label>
          brim remove <account>     <account> = label, email or id prefix
          brim alerts [-n N]        recent alerts, JSON lines
          brim install              run at login (LaunchAgent); brim uninstall
          brim quit                 stop the running app
          brim snapshot <png> [--open] [--flash] [--live]
                                    render the notch offscreen
          brim selftest

        Files live in ~/.brim (BRIM_HOME moves them). Alert hooks: settings.json "hooks",
        each a shell command that gets the alert as JSON on stdin and in $BRIM_ALERT.
        """)
    }

    static func await_<T>(_ f: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await f()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try result!.get()
    }

    static func accounts() -> [Account] { Accounts.load() }

    /// A store that has looked at what the tools hold and added rows for their accounts.
    static func scanned() -> Store {
        let st = MainActor.assumeIsolated { Store(load: true) }
        try? await_ { await st.scan() }
        MainActor.assumeIsolated { st.discover() }
        return st
    }

    static func find(_ q: String, in list: [Account]) -> Int? {
        let l = q.lowercased()
        return list.firstIndex { $0.label.lowercased() == l || $0.email?.lowercased() == l }
            ?? list.firstIndex { $0.id.lowercased().hasPrefix(l) }
    }

    static func notify() { if let pid = Lock.running() { kill(pid, SIGHUP) } }

    static func signal(_ s: Int32, _ what: String) {
        if let pid = Lock.running() { kill(pid, s); print("\(what): sent to \(pid)") } else { print("brim is not running") }
    }

    static func status(_ args: [String]) {
        let st = scanned()
        var list = MainActor.assumeIsolated { st.accounts }
        list = list.filter { !$0.isHidden }
        var usage: [String: Usage] = Dictionary((JSON.load([Usage].self, Paths.usage) ?? []).map { ($0.accountId, $0) }, uniquingKeysWith: { $1 })
        if args.contains("--fresh") || usage.isEmpty {
            if let pid = Lock.running() {
                // The app owns token refreshes; ask it to fetch and wait for the file to change.
                let before = (try? Paths.usage.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                kill(pid, SIGUSR1)
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    usleep(200_000)
                    let m = (try? Paths.usage.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if m != before { break }
                }
                usage = Dictionary((JSON.load([Usage].self, Paths.usage) ?? []).map { ($0.accountId, $0) }, uniquingKeysWith: { $1 })
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
            // Keep any rotated tokens.
            var all = accounts()
            for (u, a) in results {
                usage[u.accountId] = u
                if let i = all.firstIndex(where: { $0.id == a.id }) {
                    all[i].accessToken = a.accessToken; all[i].refreshToken = a.refreshToken; all[i].expiresAt = a.expiresAt
                }
            }
            if !all.isEmpty { JSON.save(all, Paths.accounts) }
            JSON.save(Array(usage.values), Paths.usage)
            }
        }
        let now = Date()
        if args.contains("--json") || isatty(1) == 0 {
            let out: [[String: Any]] = list.map { a in
                let u = usage[a.id]
                var o: [String: Any] = ["id": a.id, "label": a.label, "provider": a.provider.rawValue, "source": a.source.rawValue]
                if let e = a.email { o["email"] = e }
                if let p = Fmt.plan(a.plan ?? u?.plan) { o["plan"] = p }
                if let u {
                    o["fetched_at"] = ISO8601DateFormatter().string(from: u.fetchedAt)
                    if let e = u.error { o["error"] = e }
                    if u.needsAuth == true { o["needs_auth"] = true }
                    if let c = u.resetCredits { o["reset_credits"] = c }
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
                }
                return o
            }
            let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }
        if list.isEmpty { print("no accounts. brim add claude|codex"); return }
        let w = list.map(\.label.count).max() ?? 8
        for a in list {
            let u = usage[a.id]
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
            print(line)
        }
    }

    static func bar(_ pct: Double) -> String {
        let n = Int((min(pct, 100) / 100 * 10).rounded())
        return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n)
    }

    static func list() {
        let st = scanned()
        let (all, holdings) = MainActor.assumeIsolated { (st.accounts, st.holdings) }
        for a in all {
            let tools = holdings.filter { $0.account != nil && $0.account == a.key && $0.dead == nil }.map(\.tool.name)
            var src = a.source == .signIn ? ["signed in to brim"] : []
            if a.source == .apiKey { src = [a.keyVar.map { "key from $\($0)" } ?? "stored key"] }
            else { src.append(tools.isEmpty ? "no tool holds it" : "in " + Array(Set(tools)).sorted().joined(separator: ", ")) }
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
            print("vault  \(s.label ?? s.account) for \(s.tool.name)\(s.home.map { " [\($0)]" } ?? "")  \(s.state)\(exp(s.expiresAt))")
        }
    }

    static func switchTool(_ args: [String]) {
        guard args.count == 2, let tool = Tool(rawValue: args[1]) else {
            print("usage: brim switch <account> claude-code|codex|hermes|omp"); exit(2)
        }
        let st = scanned()
        let list = MainActor.assumeIsolated { st.accounts }
        guard let i = find(args[0], in: list) else { print("no account \(args[0])"); exit(1) }
        let a = list[i]
        if Switcher.needsSignIn(tool, a) {
            print("Opening your browser to sign \(tool.name) in as \(a.label)…")
        }
        do {
            let line = try await_ { try await Switcher.run(tool, to: a) }
            print(line)
            if let p = tool.pickup { print(p) }
            notify()
        } catch {
            FileHandle.standardError.write(Data("brim: switching \(tool.name) to \(a.label) failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func add(_ args: [String]) {
        guard let p = args.first.flatMap(Provider.init(rawValue:)) else { print("usage: brim add claude|codex|openrouter [--label NAME]"); exit(2) }
        let label = args.firstIndex(of: "--label").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        if p == .openrouter {
            let envVar = args.firstIndex(of: "--env").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
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
            } catch { print("key rejected: \(error)"); exit(1) }
            return
        }
        print("Opening your browser to sign in to \(p.name)…")
        do {
            let a = try await_ { try await SignIn.run(p, label: label) }
            save(a)
        } catch {
            print("sign-in failed: \(error)"); exit(1)
        }
    }

    static func save(_ a: Account) {
        do {
            let list = try Accounts.adding(a, to: accounts())
            JSON.save(list, Paths.accounts)
        } catch { print(error); exit(1) }
        notify()
        print("added \(a.label)\(a.email.map { " (\($0))" } ?? "")")
    }

    static func rename(_ args: [String]) {
        guard args.count >= 2 else { print("usage: brim rename <account> <label>"); exit(2) }
        var list = accounts()
        guard let i = find(args[0], in: list) else { print("no account \(args[0])"); exit(1) }
        list[i].label = args.dropFirst().joined(separator: " ")
        JSON.save(list, Paths.accounts); notify()
        print("renamed to \(list[i].label)")
    }

    static func remove(_ args: [String]) {
        guard let q = args.first else { print("usage: brim remove <account>"); exit(2) }
        let st = scanned()
        let list = MainActor.assumeIsolated { st.accounts }
        guard let i = find(q, in: list) else { print("no account \(q)"); exit(1) }
        MainActor.assumeIsolated { st.remove(list[i].id) }
        notify()
        print("removed \(list[i].label)")
    }

    static func alerts(_ args: [String]) {
        let n = args.firstIndex(of: "-n").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 20
        let lines = ((try? String(contentsOf: Paths.alerts, encoding: .utf8)) ?? "").split(separator: "\n")
        lines.suffix(n).forEach { print($0) }
    }
}

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
          brim list                 accounts and where their login comes from
          brim add claude|codex [--label NAME]
                                    sign in to another account in the browser
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

    static func accounts() -> [Account] { JSON.load([Account].self, Paths.accounts) ?? [] }

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
        var list = accounts()
        if list.isEmpty {
            // First run without the app: pick up local logins so `status --fresh` works straight away.
            let s = MainActor.assumeIsolated { () -> [Account] in let st = Store(load: true); st.discover(); return st.accounts }
            list = s
        }
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
            let todo = list
            let results: [(Usage, Account)] = (try? await_ { () async -> [(Usage, Account)] in
                await withTaskGroup(of: (Usage, Account).self) { g in
                    for a in todo { g.addTask { await Fetcher.fetch(a) } }
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
            else if let u, u.windows.isEmpty, let e = u.error { line += "error: \(e)" }
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
        for a in accounts() {
            let src = a.source == .claudeCode ? "Claude Code login" : a.source == .codexCLI ? "Codex CLI login" : "signed in to brim"
            print("\(a.id.prefix(8))  \(a.label)\(a.isHidden ? " (hidden)" : "")  \(a.provider.name) · \(a.email ?? "-") · \(src)")
        }
    }

    static func add(_ args: [String]) {
        guard let p = args.first.flatMap(Provider.init(rawValue:)) else { print("usage: brim add claude|codex [--label NAME]"); exit(2) }
        let label = args.firstIndex(of: "--label").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        print("Opening your browser to sign in to \(p.name)…")
        do {
            let a = try await_ { try await SignIn.run(p, label: label) }
            var list = accounts()
            if let r = a.remoteId, let d = list.first(where: { $0.provider == p && $0.remoteId == r && !$0.isHidden }) {
                print("already tracked as \(d.label)"); exit(1)
            }
            list.append(a)
            JSON.save(list, Paths.accounts)
            notify()
            print("added \(a.label)\(a.email.map { " (\($0))" } ?? "")")
        } catch {
            print("sign-in failed: \(error)"); exit(1)
        }
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
        var list = accounts()
        guard let i = find(q, in: list) else { print("no account \(q)"); exit(1) }
        let name = list[i].label
        if list[i].source == .signIn { list.remove(at: i) } else { list[i].hidden = true }
        JSON.save(list, Paths.accounts); notify()
        print("removed \(name)")
    }

    static func alerts(_ args: [String]) {
        let n = args.firstIndex(of: "-n").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 20
        let lines = ((try? String(contentsOf: Paths.alerts, encoding: .utf8)) ?? "").split(separator: "\n")
        lines.suffix(n).forEach { print($0) }
    }
}

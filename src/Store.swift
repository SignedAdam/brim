import Foundation
import Combine

/// The live state: accounts, their latest usage, polling and alerts.
@MainActor
final class Store: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var usage: [String: Usage] = [:]
    @Published var settings = Settings()
    @Published var refreshing = false
    /// A line shown under the notch for a few seconds (alerts, sign-in results).
    @Published var flash: Flash?
    @Published var now = Date()
    /// Latest publicly announced reset, if recent.
    @Published var announcement: Announcement?

    private var fired: Set<String> = []
    private var timer: Timer?
    private var clock: Timer?
    private var lastFetch = Date.distantPast
    private var backoff: [String: Date] = [:]

    var visible: [Account] { accounts.filter { !$0.isHidden } }

    init(load: Bool = true) {
        guard load else { return }
        accounts = JSON.load([Account].self, Paths.accounts) ?? []
        settings = JSON.load(Settings.self, Paths.settings) ?? Settings()
        let saved = JSON.load([Usage].self, Paths.usage) ?? []
        usage = Dictionary(saved.map { ($0.accountId, $0) }, uniquingKeysWith: { $1 })
        fired = Set(JSON.load([String].self, Paths.fired) ?? [])
        if !FileManager.default.fileExists(atPath: Paths.settings.path) { JSON.save(settings, Paths.settings) }
    }

    // MARK: lifecycle

    func start() {
        discover()
        Task { await refresh() }
        schedule()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Picks up Claude Code and Codex CLI logins on this Mac, once each.
    func discover() {
        var changed = false
        if !accounts.contains(where: { $0.source == .claudeCode }), Claude.claudeCodeCreds() != nil {
            accounts.append(Account(id: UUID().uuidString, provider: .claude, source: .claudeCode, label: "Claude"))
            changed = true
        }
        if !accounts.contains(where: { $0.source == .codexCLI }), Codex.cliCreds(nil) != nil {
            accounts.append(Account(id: UUID().uuidString, provider: .codex, source: .codexCLI, label: "ChatGPT"))
            changed = true
        }
        if changed { save(); Task { await identify() } }
    }

    /// Fills in email / remote id for CLI accounts (for labels and duplicate checks).
    func identify() async {
        for i in accounts.indices where accounts[i].remoteId == nil {
            switch accounts[i].source {
            case .claudeCode:
                if let c = Claude.claudeCodeCreds(), let p = try? await Claude.profile(c.access) {
                    accounts[i].remoteId = p.id; accounts[i].email = p.email; accounts[i].plan = p.plan
                }
            case .codexCLI:
                if let c = Codex.cliCreds(accounts[i].path) {
                    accounts[i].remoteId = c.accountId
                    accounts[i].email = jwtClaims(c.idToken)["email"] as? String
                }
            case .signIn: break
            }
        }
        save()
    }

    // MARK: refresh

    /// Refreshes every visible account in parallel. `force` skips the freshness check.
    func refresh(force: Bool = true) async {
        if !force, Date().timeIntervalSince(lastFetch) < 45 { return }
        guard !refreshing else { return }
        refreshing = true
        lastFetch = Date()
        let now = Date()
        let todo = visible.filter { (backoff[$0.id] ?? .distantPast) <= now }
        let results = await withTaskGroup(of: (Usage, Account).self) { g in
            for a in todo { g.addTask { await Fetcher.fetch(a, now: now) } }
            var out: [(Usage, Account)] = []
            for await r in g { out.append(r) }
            return out
        }
        var newAlerts: [Alert] = []
        for (u, a) in results {
            var u = u
            let old = usage[a.id]
            if u.error != nil, u.needsAuth != true, let old, !old.windows.isEmpty {
                // Keep showing the last good numbers through a transient failure.
                let err = u.error
                u = old; u.error = err
                if err?.contains("429") == true { backoff[a.id] = now.addingTimeInterval(600) }
            }
            if let i = accounts.firstIndex(where: { $0.id == a.id }), accounts[i] != a {
                // Only take token/plan updates; the user may have renamed it meanwhile.
                accounts[i].accessToken = a.accessToken; accounts[i].refreshToken = a.refreshToken
                accounts[i].expiresAt = a.expiresAt; accounts[i].plan = a.plan
            }
            newAlerts += Alerts.evaluate(account: a, old: old, new: u, settings: settings, fired: fired, now: now)
            usage[a.id] = u
        }
        self.now = now
        save()
        JSON.save(Array(usage.values), Paths.usage)
        refreshing = false
        for a in newAlerts { fire(a) }
        if settings.announcements { await checkAnnouncements(now: now) }
    }

    /// Picks up resets OpenAI / Anthropic announce in public, via resets.albastov.com.
    func checkAnnouncements(now: Date) async {
        guard let o = try? await HTTP.json(URLRequest(url: URL(string: "https://resets.albastov.com/api/resets?limit=5")!)) else { return }
        let list = Announcement.parse(o).sorted { $0.at > $1.at }
        announcement = list.first.flatMap { now.timeIntervalSince($0.at) < 48 * 3600 ? $0 : nil }
        let firstRun = !fired.contains { $0.hasPrefix("ann:") }
        for a in list where !fired.contains("ann:\(a.id)") {
            // On the very first run just remember what's there; only new ones are news.
            if firstRun || now.timeIntervalSince(a.at) > 6 * 3600 { fired.insert("ann:\(a.id)"); continue }
            fire(Alert(kind: .announced, accountId: "", account: a.provider == .claude ? "Anthropic" : "OpenAI",
                       provider: a.provider, window: nil, percent: nil, resetsAt: nil,
                       title: a.summary, key: "ann:\(a.id)", at: now))
        }
        JSON.save(Array(fired), Paths.fired)
    }

    // MARK: alerts

    func fire(_ a: Alert) {
        fired.insert(a.key)
        if fired.count > 500 { fired = Set(fired.suffix(300)) }
        JSON.save(Array(fired), Paths.fired)
        log("alert \(a.kind.rawValue): \(a.title)")
        if let line = try? JSONEncoder.compact.encode(a), let h = try? FileHandle(forWritingTo: Paths.alerts) {
            h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close()
        } else if let line = try? JSONEncoder.compact.encode(a) {
            FileManager.default.createFile(atPath: Paths.alerts.path, contents: line + Data("\n".utf8))
        }
        show(Flash(alert: a))
        let json = (try? JSONEncoder.compact.encode(a)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pager = settings.pager ? Self.pagerPath : nil
        let hooks = settings.hooks
        DispatchQueue.global().async {
            if let pager {
                let sev = a.kind == .threshold && (a.percent ?? 0) >= 95 ? "warn" : "info"
                _ = Shell.run(pager, ["event", "--text", a.title, "--source", "Brim", "--subject", a.account,
                                      "--type", "usage.\(a.kind.rawValue)", "--severity", sev])
            }
            for h in hooks {
                _ = Shell.run("/bin/zsh", ["-lc", h], stdin: json, env: ["BRIM_ALERT": json])
            }
        }
    }

    static let pagerPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/pager", "/opt/homebrew/bin/pager", "/usr/local/bin/pager"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func show(_ f: Flash, seconds: Double = 6) {
        flash = f
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.flash?.id == f.id { self?.flash = nil }
        }
    }

    // MARK: accounts

    func add(_ a: Account) throws {
        if let r = a.remoteId, let dup = accounts.first(where: { $0.provider == a.provider && $0.remoteId == r && !$0.isHidden }) {
            throw ProviderError.other("already tracked as \(dup.label)")
        }
        accounts.append(a)
        save()
        Task { await refresh() }
    }

    func update(_ id: String, _ f: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        f(&accounts[i])
        save()
    }

    /// Signed-in accounts are deleted; CLI ones are hidden so discovery doesn't bring them back.
    func remove(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        if accounts[i].source == .signIn { accounts.remove(at: i) } else { accounts[i].hidden = true }
        usage[id] = nil
        save()
        JSON.save(Array(usage.values), Paths.usage)
    }

    func move(from: IndexSet, to: Int) {
        var v = visible
        v.move(fromOffsets: from, toOffset: to)
        accounts = v + accounts.filter(\.isHidden)
        save()
    }

    func save() { JSON.save(accounts, Paths.accounts) }

    func saveSettings() { JSON.save(settings, Paths.settings); schedule() }
}

extension JSONEncoder {
    static let compact: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

struct Flash: Equatable {
    enum Tone { case accent, warn, bad, plain }
    var id = UUID()
    var text: String
    var provider: Provider?
    var tone: Tone

    init(text: String, provider: Provider? = nil, tone: Tone = .plain) {
        self.text = text; self.provider = provider; self.tone = tone
    }

    init(alert a: Alert) {
        text = a.title
        provider = a.provider
        switch a.kind {
        case .reset, .credits, .leftover, .announced: tone = .accent
        case .threshold: tone = (a.percent ?? 0) >= 100 ? .bad : (a.percent ?? 0) >= 85 ? .warn : .accent
        case .auth: tone = .warn
        }
    }
}

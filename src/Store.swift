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
    /// What each tool on this Mac holds, and what Brim has parked.
    @Published var holdings: [Holding] = []
    @Published var parked: [Slot] = []
    /// Tools set up on this Mac.
    @Published var installed: [Tool] = []
    /// "<account id>:<tool>" of switches under way.
    @Published var switching: Set<String> = []

    private var fired: Set<String> = []
    private var timer: Timer?
    private var clock: Timer?
    private var lastFetch = Date.distantPast
    private var backoff: [String: Date] = [:]

    var visible: [Account] { accounts.filter { !$0.isHidden } }

    init(load: Bool = true) {
        guard load else { return }
        accounts = Accounts.load()
        settings = JSON.load(Settings.self, Paths.settings) ?? Settings()
        let saved = JSON.load([Usage].self, Paths.usage) ?? []
        usage = Dictionary(saved.map { ($0.accountId, $0) }, uniquingKeysWith: { $1 })
        fired = Set(JSON.load([String].self, Paths.fired) ?? [])
        if !FileManager.default.fileExists(atPath: Paths.settings.path) { JSON.save(settings, Paths.settings) }
    }

    // MARK: lifecycle

    func start() {
        Task {
            await scan()
            discover()
            await refresh()
        }
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

    /// Reads what every tool holds (Keychain, files, OMP's database) off the main thread.
    func scan() async {
        let (h, v, t) = await Task.detached { () -> ([Holding], Vault, [Tool]) in
            let v = Vault.load()
            return (Tools.scan(minted: v.minted), v, Tool.allCases.filter(\.installed))
        }.value
        holdings = h
        parked = v.slots
        installed = t
    }

    /// The tool icons on an account's row.
    func chips(_ a: Account) -> [Chip] {
        guard let k = a.key else { return [] }
        return installed.filter { $0.providers.contains(a.provider) }.map { t in
            let here = holdings.filter { $0.tool == t && $0.provider == a.provider }
            let mine = here.filter { $0.account == k }
            let active = mine.contains { $0.dead == nil }
            let dead = mine.first { $0.dead != nil }?.dead
            let other = here.contains { $0.account == nil } ? "holds a login Brim can't place" : nil
            var help = t.name
            if active { help += " · \(a.label)" } else { help += " · switch to \(a.label)" }
            if let d = dead { help += "\nThis login is dead: \(d.prefix(90))" }
            if !active, let o = other { help += "\nIt \(o.prefix(90))" }
            if !active, let p = t.pickup { help += "\n\(p.prefix(1).uppercased() + p.dropFirst())" }
            return Chip(tool: t, active: active, busy: switching.contains("\(a.id):\(t.rawValue)"),
                        mine: active ? nil : dead, other: other, help: help)
        }
    }

    /// Adds a row for every account a tool on this Mac is signed in to, once each, and an
    /// OpenRouter key found in the environment.
    func discover() {
        var changed = false
        for h in holdings {
            guard let k = h.account, !accounts.contains(where: { $0.key == k }) else { continue }
            let f = h.family
            accounts.append(Account(id: UUID().uuidString, provider: h.provider, source: .tool,
                                    label: f.email.map(SignIn.defaultLabel) ?? h.provider.name, email: f.email,
                                    plan: f.rateLimitTier ?? f.subscriptionType, remoteId: f.accountId))
            changed = true
        }
        // An OpenRouter key in the environment or global.env: track it by name, never copy it.
        if !accounts.contains(where: { $0.keyVar == "OPENROUTER_API_KEY" }), OpenRouter.env("OPENROUTER_API_KEY") != nil {
            accounts.append(Account(id: UUID().uuidString, provider: .openrouter, source: .apiKey, label: "OpenRouter",
                                    keyVar: "OPENROUTER_API_KEY"))
            changed = true
        }
        if changed { save() }
    }

    /// A fresh token for a `.tool` account, from whoever holds it now. Read, never refreshed.
    /// Hermes's Claude tokens can't read usage (inference only), so they don't count.
    func borrowed(_ a: Account, now: Date) -> Family? {
        guard a.source == .tool, let k = a.key else { return nil }
        let live = holdings.filter { $0.account == k && $0.dead == nil && !($0.tool == .hermes && $0.provider == .claude) }.map(\.family)
            + parked.filter { $0.account == k && $0.error == nil && $0.tool != .hermes }.map(\.family)
        return live.filter { !$0.expired(now) }.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    // MARK: refresh

    /// Refreshes every visible account in parallel. `force` skips the freshness check.
    func refresh(force: Bool = true) async {
        if !force, Date().timeIntervalSince(lastFetch) < 45 { return }
        guard !refreshing else { return }
        refreshing = true
        lastFetch = Date()
        await Task.detached { await Switcher.keepFresh() }.value
        await scan()
        discover()
        let now = Date()
        let todo = visible.filter { (backoff[$0.id] ?? .distantPast) <= now }.map { ($0, borrowed($0, now: now)) }
        let results = await withTaskGroup(of: (Usage, Account).self) { g in
            for (a, b) in todo { g.addTask { await Fetcher.fetch(a, borrowed: b, now: now) } }
            var out: [(Usage, Account)] = []
            for await r in g { out.append(r) }
            return out
        }
        var olds: [String: Usage] = [:]
        for (u, a) in results {
            var u = u
            let old = usage[a.id]
            olds[a.id] = old
            if u.error != nil, u.needsAuth != true, let old, old.hasData {
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
            usage[a.id] = u
        }
        var newAlerts: [Alert] = []
        for (u, a) in results {
            newAlerts += Alerts.evaluate(account: a, old: olds[a.id], new: usage[a.id] ?? u, settings: settings, fired: fired,
                                         now: now, alternative: alternative(to: a))
        }
        self.now = now
        save()
        JSON.save(Array(usage.values), Paths.usage)
        refreshing = false
        for a in newAlerts { fire(a) }
        if settings.announcements { await checkAnnouncements(now: now) }
    }

    /// The other account of the same provider with the most room left, for "almost full" alerts.
    func alternative(to a: Account) -> (label: String, left: Double)? {
        visible.filter { $0.provider == a.provider && $0.id != a.id }
            .compactMap { o in usage[o.id].flatMap { $0.hasData && $0.needsAuth != true ? (o.label, 100 - $0.peak) : nil } }
            .max { $0.1 < $1.1 }
    }

    // MARK: switching

    /// Points `tool` at `account`: the click on a tool icon, and `brim switch`.
    func switchTool(_ tool: Tool, to a: Account) {
        let k = "\(a.id):\(tool.rawValue)"
        guard !switching.contains(k) else { return }
        switching.insert(k)
        if Switcher.needsSignIn(tool, a) {
            show(Flash(text: "Sign \(tool.name) in as \(a.label) in your browser", provider: a.provider), seconds: 30)
        }
        Task {
            do {
                let line = try await Switcher.run(tool, to: a)
                show(Flash(text: line + (tool.pickup.map { " · \($0)" } ?? ""), provider: a.provider, tone: .accent))
            } catch {
                show(Flash(text: "\(tool.name): \(error)", provider: a.provider, tone: .warn), seconds: 10)
            }
            switching.remove(k)
            await scan()
        }
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
                       title: a.short, key: "ann:\(a.id)", at: now))
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

    /// Adds a Brim sign-in; one for an account a tool already holds upgrades that row.
    func add(_ a: Account) throws {
        accounts = try Accounts.adding(a, to: accounts)
        save()
        Task { await refresh() }
    }

    func update(_ id: String, _ f: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        f(&accounts[i])
        save()
    }

    /// Signed-in accounts are deleted; discovered ones are hidden so discovery doesn't bring them back.
    /// A signed-in account a tool still holds keeps its row, hidden and without Brim's tokens.
    func remove(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let k = accounts[i].key
        if Self.discovered(accounts[i]) {
            accounts[i].hidden = true
        } else if k != nil, holdings.contains(where: { $0.account == k }) || parked.contains(where: { $0.account == k }) {
            accounts[i].source = .tool
            accounts[i].hidden = true
            (accounts[i].accessToken, accounts[i].refreshToken, accounts[i].expiresAt) = (nil, nil, nil)
        } else {
            accounts.remove(at: i)
        }
        usage[id] = nil
        save()
        JSON.save(Array(usage.values), Paths.usage)
    }

    static func discovered(_ a: Account) -> Bool {
        a.source == .tool || (a.source == .apiKey && a.keyVar != nil)
    }

    func restore(_ id: String) {
        update(id) { $0.hidden = false }
        Task { await refresh() }
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
        case .balance: tone = .warn
        case .threshold: tone = (a.percent ?? 0) >= 100 ? .bad : (a.percent ?? 0) >= 85 ? .warn : .accent
        case .auth: tone = .warn
        }
    }
}

/// One tool icon on an account row.
struct Chip: Identifiable, Equatable {
    var tool: Tool
    /// The tool is signed in as this account.
    var active: Bool
    var busy: Bool
    /// This account's login in the tool is dead (why).
    var mine: String?
    /// The tool holds a login that's dead or Brim can't place (what).
    var other: String?
    var help: String
    var id: String { tool.rawValue }
}

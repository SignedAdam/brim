import Foundation

// Account switching, part 3: moving a login between the vault and a tool.
//
// Switch tool T to account B: take B's family for T out of the vault (or sign in for a new one),
// install it, and park the family T held until then. On disk a family is never in two places:
// the vault drops B before T gets it, and gets T's old family only once T has let go of it.

/// The network a switch uses; the selftest swaps it for a fake.
struct Net {
    /// Refreshes a family Brim owns. Throws `ProviderError.auth` when the login is gone for good.
    var refresh: (Family) async throws -> Family
    /// Claude's /api/oauth/profile for a token, as JSON.
    var profile: (String) async throws -> [String: Any]
    /// A new family from the browser.
    var signIn: (Provider, _ longLived: Bool) async throws -> Family

    static let live = Net(
        refresh: { f in
            guard let rt = f.refresh else { throw ProviderError.auth("nothing to refresh with") }
            var n = f
            do {
                switch f.provider {
                case .claude:
                    let r = try await Claude.refresh(rt)
                    (n.access, n.refresh, n.expiresAt) = (r.access, r.refresh, r.expiresAt)
                case .codex:
                    let r = try await Codex.refresh(rt)
                    n = Family.codex(access: r.access, refresh: r.refresh, idToken: r.idToken ?? f.idToken, accountId: f.accountId)
                case .openrouter: break
                }
            } catch ProviderError.http(let code, let body) where code == 400 || code == 401 {
                throw ProviderError.auth("refresh rejected (\(code)\(body.contains("invalid_grant") ? ", invalid_grant" : ""))")
            }
            return n
        },
        profile: { try await HTTP.json(Claude.request("profile", $0)) },
        signIn: { try await SignIn.family($0, longLived: $1) })
}

enum Switcher {
    /// Refresh a family before installing it when it expires within this.
    static let installMargin: TimeInterval = 15 * 60

    /// Points `tool` at account `a`. Returns the line to show ("Claude Code → Work").
    static func run(_ tool: Tool, to a: Account, net: Net = .live, now: @escaping () -> Date = Date.init) async throws -> String {
        let p = a.provider
        guard let key = a.key else { throw ProviderError.other("\(a.label) has no account id yet") }
        guard tool.providers.contains(p) else { throw ProviderError.other("\(tool.name) doesn't take \(p.name) accounts") }
        guard tool.installed else { throw ProviderError.other("\(tool.name) isn't set up on this Mac") }
        let longLived = tool == .hermes && p == .claude
        var places = Tools.places(tool, p)
        if places.isEmpty { places = ["default"] }

        for home in places {
            let v = try Vault.read()
            let current = held(tool, p, home, minted: v.minted)
            if !current.isEmpty, current.allSatisfy({ $0.account == key && $0.dead == nil }) { continue }

            // No usable parked login: sign in first, outside the lock (it waits on the browser).
            var fresh: Family?
            if !usable(v.slot(key, tool, home), now()) {
                let f = try await net.signIn(p, longLived)
                guard f.key == key else {
                    throw ProviderError.other("the browser signed in as \(f.email ?? "another account"), not \(a.label)")
                }
                fresh = f
            }

            try await Vault.locked { v in
                // 1. Out of the vault, on disk too, before the tool gets it.
                let before = v
                let slot = v.take(key, tool, home)
                guard var f = fresh ?? slot?.family else { throw ProviderError.other("\(a.label)'s login for \(tool.name) went missing, try again") }
                try v.save()
                func putBack(_ fam: Family) {
                    var s = slot ?? Slot(account: key, tool: tool, home: home, family: fam, parkedAt: now())
                    s.family = fam
                    s.error = nil
                    v = before
                    v.put(s)
                    try? v.save()
                }

                // 2. Fresh, and (Claude Code) who it is, while Brim still owns it.
                var profile: [String: Any]?
                do {
                    if f.refresh != nil, f.expired(now().addingTimeInterval(installMargin)) { f = try await net.refresh(f) }
                    if tool == .claudeCode { profile = try await net.profile(f.access) }
                } catch {
                    putBack(f)
                    throw error
                }

                // 3. Into the tool. It hands back what it held.
                let out: [Holding]
                do {
                    out = try Tools.install(tool, home: home, f, profile: profile, minted: v.minted)
                } catch {
                    putBack(f)
                    throw error
                }

                // 4. Park what it let go of. Dead and unplaceable logins stay in the backup only.
                var seen = Set<String>()
                for h in out where h.dead == nil && !h.family.gone(now()) && h.family.access != f.access {
                    guard let k = h.account, seen.insert(h.family.fingerprint).inserted else { continue }
                    v.put(Slot(account: k, tool: tool, home: home, family: h.family, parkedAt: now()))
                }
                if longLived { v.minted[Secret.fingerprint(f.access)] = Minted(account: key, expiresAt: f.expiresAt) }
                do { try v.save() } catch {
                    log("switch: \(tool.name) now holds \(a.label), but the vault couldn't keep the previous login: \(error)")
                    throw ProviderError.other("\(tool.name) switched, but its previous login couldn't be parked (\(error))")
                }
                log("switch: \(tool.name)\(home.map { " [\($0)]" } ?? "") -> \(a.label)")
            }
        }
        return "\(tool.name) → \(a.label)"
    }

    static func usable(_ s: Slot?, _ now: Date) -> Bool {
        guard let s else { return false }
        return s.error == nil && !s.family.gone(now)
    }

    /// Whether switching `tool` to `a` would open the browser.
    static func needsSignIn(_ tool: Tool, _ a: Account, now: Date = Date()) -> Bool {
        guard let key = a.key, tool.providers.contains(a.provider) else { return false }
        let v = Vault.load()
        let places = Tools.places(tool, a.provider)
        return (places.isEmpty ? ["default"] : places).contains { home in
            let current = held(tool, a.provider, home, minted: v.minted)
            let there = !current.isEmpty && current.allSatisfy { $0.account == key && $0.dead == nil }
            return !there && !usable(v.slot(key, tool, home), now)
        }
    }

    /// What `tool` holds for `p` in one place (a Hermes home for Codex; everywhere otherwise).
    static func held(_ tool: Tool, _ p: Provider, _ home: String?, minted: [String: Minted]) -> [Holding] {
        Tools.read(tool, p, minted: minted).filter { home == nil || $0.home == home }
    }

    /// Refreshes parked families before they go stale, so a parked login always works later.
    /// Claude access tokens last hours, so refresh within the hour; ChatGPT ones last days, and
    /// Codex itself refreshes every 8 days, so do it at least every 5.
    static func keepFresh(net: Net = .live, now: Date = Date()) async {
        do {
            try await Vault.locked { v in
                for i in v.slots.indices {
                    let s = v.slots[i]
                    guard s.error == nil, s.family.refresh != nil, !s.family.gone(now) else { continue }
                    let last = s.refreshedAt ?? s.parkedAt
                    guard s.family.expired(now.addingTimeInterval(3600)) || now.timeIntervalSince(last) > 5 * 86400 else { continue }
                    do {
                        v.slots[i].family = try await net.refresh(s.family)
                        v.slots[i].refreshedAt = now
                    } catch ProviderError.auth(let why) {
                        v.slots[i].error = why
                        log("vault: \(s.account) for \(s.tool.name) can't be refreshed: \(why)")
                    } catch {
                        continue    // offline or a hiccup: try next round
                    }
                    // Save each one at once: the old refresh token is already dead.
                    try v.save()
                }
            }
        } catch {
            log("vault: keep-fresh skipped: \(error)")
        }
    }
}

// MARK: - Who holds what

/// `brim where`: every tool's login and every parked one. No tokens.
struct Where: Encodable {
    struct Held: Encodable {
        var tool: Tool
        var provider: Provider
        var location: String?
        var account: String?
        var label: String?
        var email: String?
        var state: String
        var expiresAt: Date?
        var fingerprint: String
    }
    struct Parked: Encodable {
        var account: String
        var label: String?
        var tool: Tool
        var home: String?
        var state: String
        var expiresAt: Date?
        var parkedAt: Date
        var fingerprint: String
    }
    var tools: [Held]
    var vault: [Parked]

    static func now(accounts: [Account], holdings: [Holding], vault: Vault, at now: Date = Date()) -> Where {
        let labels = Dictionary(accounts.compactMap { a in a.key.map { ($0, a.label) } }, uniquingKeysWith: { a, _ in a })
        let tools = holdings.map { h in
            Held(tool: h.tool, provider: h.provider, location: h.location, account: h.account,
                 label: h.account.flatMap { labels[$0] }, email: h.family.email, state: state(h, now: now),
                 expiresAt: h.family.expiresAt, fingerprint: h.family.fingerprint)
        }
        let parked = vault.slots.map { s in
            Parked(account: s.account, label: labels[s.account], tool: s.tool, home: s.home,
                   state: s.error.map { "parked, dead: \($0)" } ?? (s.family.gone(now) ? "parked, expired" : "parked"),
                   expiresAt: s.family.expiresAt, parkedAt: s.parkedAt, fingerprint: s.family.fingerprint)
        }
        return Where(tools: tools, vault: parked)
    }

    static func state(_ h: Holding, now: Date) -> String {
        if let d = h.dead { return "dead: \(d)" }
        if h.account == nil { return "unknown account" }
        if h.family.gone(now) { return "expired" }
        return "installed"
    }
}

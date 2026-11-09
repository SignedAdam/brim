import Foundation

enum Switcher {
    static let installMargin: TimeInterval = 15 * 60

    static func run(_ tool: Tool, to a: Account) async throws -> String {
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

            var fresh: Family?
            if !usable(v.slot(key, tool, home), Date()) {
                let f = try await SignIn.family(p, longLived: longLived)
                guard f.key == key else {
                    throw ProviderError.other("the browser signed in as \(f.email ?? "another account"), not \(a.label)")
                }
                fresh = f
            }

            try await Vault.locked { v in
                let before = v
                let slot = v.take(key, tool, home)
                guard var f = fresh ?? slot?.family else { throw ProviderError.other("\(a.label)'s login for \(tool.name) went missing, try again") }
                try v.save()
                func putBack(_ fam: Family) {
                    var s = slot ?? Slot(account: key, tool: tool, home: home, family: fam, parkedAt: Date())
                    s.family = fam
                    s.error = nil
                    v = before
                    v.put(s)
                    try? v.save()
                }

                var profile: [String: Any]?
                do {
                    if f.refresh != nil, f.expired(Date().addingTimeInterval(installMargin)) { f = try await refresh(f) }
                    if tool == .claudeCode { profile = try await HTTP.json(Claude.request("profile", f.access)) }
                } catch {
                    putBack(f)
                    throw error
                }

                let out: [Holding]
                do {
                    out = try Tools.install(tool, home: home, f, profile: profile, minted: v.minted)
                } catch {
                    putBack(f)
                    throw error
                }

                var seen = Set<String>()
                for h in out where h.dead == nil && !h.family.gone(Date()) && h.family.access != f.access {
                    guard let k = h.account, seen.insert(h.family.fingerprint).inserted else { continue }
                    v.put(Slot(account: k, tool: tool, home: home, family: h.family, parkedAt: Date()))
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

    static func refresh(_ f: Family) async throws -> Family {
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
    }

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

    static func held(_ tool: Tool, _ p: Provider, _ home: String?, minted: [String: Minted]) -> [Holding] {
        Tools.read(tool, p, minted: minted).filter { home == nil || $0.home == home }
    }

    static func keepFresh() async {
        let now = Date()
        do {
            try await Vault.locked { v in
                for i in v.slots.indices {
                    let s = v.slots[i]
                    guard s.error == nil, s.family.refresh != nil, !s.family.gone(now) else { continue }
                    let last = s.refreshedAt ?? s.parkedAt
                    guard s.family.expired(now.addingTimeInterval(3600)) || now.timeIntervalSince(last) > 5 * 86400 else { continue }
                    do {
                        v.slots[i].family = try await refresh(s.family)
                        v.slots[i].refreshedAt = now
                    } catch ProviderError.auth(let why) {
                        v.slots[i].error = why
                        log("vault: \(s.account) for \(s.tool.name) can't be refreshed: \(why)")
                    } catch {
                        continue
                    }
                    try v.save()
                }
            }
        } catch {
            log("vault: keep-fresh skipped: \(error)")
        }
    }
}

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

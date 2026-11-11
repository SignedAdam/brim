import Foundation

enum Switcher {
    static let installMargin: TimeInterval = 15 * 60

    static func run(_ tool: Tool, to a: Account, open: Bool = true, onHandOver: () async -> Void = {}) async throws -> String {
        let p = a.provider
        guard let key = a.key else { throw ProviderError.other("\(a.label) has no account id yet") }
        guard tool.providers.contains(p) else { throw ProviderError.other("\(tool.name) doesn't take \(p.name) accounts") }
        guard tool.installed else { throw ProviderError.other("\(tool.name) isn't set up on this Mac") }
        let longLived = tool == .hermes
        let v = try Vault.read()
        let current = Tools.read(tool, p, minted: v.minted)
        if !current.isEmpty, current.allSatisfy({ $0.account == key && $0.dead == nil }) { return "\(tool.name) → \(a.label)" }

        var fresh: Family?
        if !usable(v.slot(key, tool), Date()) {
            if !longLived, let o = ownFamily(a) {
                fresh = try await refresh(o)
                await onHandOver()
            } else if p == .codex {
                let logins = try await SignIn.codex(open: open) { f in f.key == key ? wanted(key, except: tool) : 0 }
                guard logins[0].key == key else {
                    throw ProviderError.other("the browser signed in as \(logins[0].email ?? "another account"), not \(a.label)")
                }
                fresh = logins[0]
                if logins.count > 1 {
                    try await Vault.locked { v in
                        park(Array(logins.dropFirst()), key, in: &v, except: tool)
                        try v.save()
                    }
                }
            } else {
                let f = try await SignIn.family(p, longLived: longLived, open: open)
                guard f.key == key else {
                    throw ProviderError.other("the browser signed in as \(f.email ?? "another account"), not \(a.label)")
                }
                fresh = f
            }
        }

        try await Vault.locked { v in
            let before = v
            let slot = v.take(key, tool)
            guard var f = fresh ?? slot?.family else { throw ProviderError.other("\(a.label)'s login for \(tool.name) went missing, try again") }
            try v.save()
            func putBack(_ fam: Family) {
                var s = slot ?? Slot(account: key, tool: tool, family: fam, parkedAt: Date())
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
                out = try Tools.install(tool, f, profile: profile, minted: v.minted)
            } catch {
                putBack(f)
                throw error
            }

            var seen = Set<String>()
            for h in out where h.dead == nil && !h.family.gone(Date()) && h.family.access != f.access {
                guard let k = h.account, seen.insert(h.family.fingerprint).inserted else { continue }
                v.put(Slot(account: k, tool: tool, family: h.family, parkedAt: Date()))
            }
            if longLived { v.minted[Secret.fingerprint(f.access)] = Minted(account: key, expiresAt: f.expiresAt) }
            do { try v.save() } catch {
                log("switch: \(tool.name) now holds \(a.label), but the vault couldn't keep the previous login: \(error)")
                throw ProviderError.other("\(tool.name) switched, but its previous login couldn't be parked (\(error))")
            }
            log("switch: \(tool.name) -> \(a.label)")
        }
        return "\(tool.name) → \(a.label)"
    }

    static func missing(_ key: String, _ v: Vault, except: Tool?) -> [Tool] {
        Tool.allCases.filter { t in
            t != except && t.installed && t.providers.contains(.codex)
                && !Tools.read(t, .codex, minted: v.minted).contains { $0.account == key && $0.dead == nil }
                && !usable(v.slot(key, t), Date())
        }
    }

    static func wanted(_ key: String, except: Tool?, own: Int = 0) -> Int {
        max(0, missing(key, Vault.load(), except: except).count - own)
    }

    static func park(_ logins: [Family], _ key: String, in v: inout Vault, except: Tool?) {
        for (t, f) in zip(missing(key, v, except: except), logins) {
            v.put(Slot(account: key, tool: t, family: f, parkedAt: Date()))
        }
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

    static func ownFamily(_ a: Account) -> Family? {
        guard a.source == .signIn, let access = a.accessToken, let refresh = a.refreshToken else { return nil }
        switch a.provider {
        case .codex: return Family.codex(access: access, refresh: refresh, idToken: nil, accountId: a.remoteId)
        case .claude: return Family(provider: .claude, access: access, refresh: refresh, expiresAt: a.expiresAt, accountId: a.remoteId, email: a.email)
        case .openrouter: return nil
        }
    }

    static func needsSignIn(_ tool: Tool, _ a: Account, now: Date = Date()) -> Bool {
        guard let key = a.key, tool.providers.contains(a.provider) else { return false }
        let v = Vault.load()
        let current = Tools.read(tool, a.provider, minted: v.minted)
        if !current.isEmpty, current.allSatisfy({ $0.account == key && $0.dead == nil }) { return false }
        if usable(v.slot(key, tool), now) { return false }
        return tool == .hermes || ownFamily(a) == nil
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
            Parked(account: s.account, label: labels[s.account], tool: s.tool,
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

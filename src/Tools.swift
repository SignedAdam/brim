import Foundation

// Account switching, part 2: reading and writing each tool's own credential store. Every write
// is preceded by a backup and done in one step, so a failure leaves the tool as it was.

/// A login one tool holds right now.
struct Holding: Equatable {
    var tool: Tool
    var provider: Provider
    /// Where inside the tool, for display: a Hermes home ("default", "orion"), an OMP row ("row 7").
    var location: String?
    /// The vault slot's home when this family moves out (Hermes Codex: one family per home).
    var home: String?
    var family: Family
    /// Why it no longer works, if it doesn't.
    var dead: String?
    /// Whose it is ("claude:<uuid>"); nil = a login Brim can't place.
    var account: String?
}

// MARK: - Claude Code

/// Keychain item "Claude Code-credentials" (account $USER) plus `oauthAccount` in ~/.claude.json.
/// Claude Code re-reads the item before each refresh check (cached 30 s) and refreshes with what
/// it finds there, so a running session moves to the new login on its next request.
enum ClaudeCode {
    static var user: String { ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName() }

    /// The whole item: `{"claudeAiOauth": {...}, ...}`, read through `security` (on the item's ACL).
    static func payload() -> [String: Any]? {
        guard let raw = Shell.run("/usr/bin/security", ["find-generic-password", "-a", user, "-s", Paths.keychainService, "-w"]) else { return nil }
        return Files.object(Data(raw.utf8))
    }

    static func oauthAccount() -> [String: Any]? {
        Files.object(try? Data(contentsOf: Paths.claudeJSON))?["oauthAccount"] as? [String: Any]
    }

    static func read() -> Holding? {
        guard let c = payload()?["claudeAiOauth"] as? [String: Any] else { return nil }
        let ms = { (k: String) in (c[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let rt = c["refreshToken"] as? String
        let who = oauthAccount()
        let f = Family(provider: .claude, access: c["accessToken"] as? String ?? "", refresh: rt.flatMap { $0.isEmpty ? nil : $0 },
                       expiresAt: ms("expiresAt"), refreshExpiresAt: ms("refreshTokenExpiresAt"),
                       accountId: who?["accountUuid"] as? String, email: who?["emailAddress"] as? String,
                       orgId: who?["organizationUuid"] as? String, orgName: who?["organizationName"] as? String,
                       scopes: c["scopes"] as? [String], subscriptionType: c["subscriptionType"] as? String,
                       rateLimitTier: c["rateLimitTier"] as? String)
        let dead = f.access.isEmpty || rt == "" ? "signed out" : nil
        return Holding(tool: .claudeCode, provider: .claude, family: f, dead: dead, account: f.key)
    }

    /// Installs `f`, and `oauthAccount` built from `profile` (/api/oauth/profile with f's token).
    static func install(_ f: Family, profile: [String: Any]) throws -> [Holding] {
        let lock = try RefreshLock()
        defer { lock.release() }
        let old = read()
        let before = payload()
        let json = try? Data(contentsOf: Paths.claudeJSON)
        if let before { try Backup.save("claude-code-keychain", try Files.json(before)) }
        if let json { try Backup.save("claude-code-claude.json", json) }

        var p = before ?? [:]
        p["claudeAiOauth"] = record(f, profile: profile)
        try write(p, expecting: f.access)
        do {
            if let json { try Files.write(try JSONText.replacing("oauthAccount", in: json, with: account(profile)), to: Paths.claudeJSON) }
        } catch {
            // Put the item back as it was, so Claude Code never sees half a switch.
            if let before { try? write(before, expecting: nil) } else { _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-a", user, "-s", Paths.keychainService]) }
            throw error
        }
        return old.map { [$0] } ?? []
    }

    static func record(_ f: Family, profile: [String: Any]) -> [String: Any] {
        let org = profile["organization"] as? [String: Any] ?? [:]
        let plans = ["claude_max": "max", "claude_pro": "pro", "claude_enterprise": "enterprise", "claude_team": "team"]
        var r: [String: Any] = ["accessToken": f.access, "refreshToken": f.refresh ?? "", "expiresAt": Stamp.ms(f.expiresAt),
                                "scopes": f.scopes ?? Claude.scopes]
        if let d = f.refreshExpiresAt { r["refreshTokenExpiresAt"] = Stamp.ms(d) }
        r["subscriptionType"] = f.subscriptionType ?? (org["organization_type"] as? String).flatMap { plans[$0] } ?? NSNull()
        r["rateLimitTier"] = f.rateLimitTier ?? org["rate_limit_tier"] as? String ?? NSNull()
        return r
    }

    /// `oauthAccount` the way Claude Code writes it after a profile fetch.
    static func account(_ profile: [String: Any]) -> [String: Any] {
        let a = profile["account"] as? [String: Any] ?? [:]
        let o = profile["organization"] as? [String: Any] ?? [:]
        var r: [String: Any] = [:]
        r["accountUuid"] = a["uuid"]
        r["emailAddress"] = a["email"] ?? a["email_address"]
        r["organizationUuid"] = o["uuid"]
        r["displayName"] = a["display_name"]
        r["fullName"] = a["full_name"]
        r["accountCreatedAt"] = a["created_at"]
        r["organizationName"] = o["name"]
        r["organizationType"] = o["organization_type"]
        r["organizationRateLimitTier"] = o["rate_limit_tier"]
        r["hasExtraUsageEnabled"] = o["has_extra_usage_enabled"] ?? false
        r["billingType"] = o["billing_type"]
        r["subscriptionCreatedAt"] = o["subscription_created_at"]
        r["ccOnboardingFlags"] = o["cc_onboarding_flags"] ?? [String: Any]()
        r["claudeCodeTrialEndsAt"] = o["claude_code_trial_ends_at"] ?? NSNull()
        r["claudeCodeTrialDurationDays"] = o["claude_code_trial_duration_days"] ?? NSNull()
        r["seatTier"] = o["seat_tier"] ?? NSNull()
        r["profileFetchedAt"] = Stamp.ms(Date())
        return r
    }

    /// Writes the item the way Claude Code does: `security -i` with the JSON as hex on stdin
    /// (argv only when too long for it), then reads it back.
    static func write(_ p: [String: Any], expecting access: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: p, options: [.withoutEscapingSlashes])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(user)\" -s \"\(Paths.keychainService)\" -X \"\(hex)\"\n"
        let r = line.utf8.count <= 4032
            ? Shell.exec("/usr/bin/security", ["-i"], stdin: line)
            : Shell.exec("/usr/bin/security", ["add-generic-password", "-U", "-a", user, "-s", Paths.keychainService, "-X", hex])
        guard r.status == 0 else { throw ProviderError.other("Keychain write failed: \(r.err)") }
        if let access, (payload()?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String != access {
            throw ProviderError.other("Keychain write didn't stick")
        }
    }

    /// Claude Code's refresh lock (a proper-lockfile directory, stale after 60 s). Holding it keeps
    /// a running Claude Code from refreshing while the login changes under it.
    struct RefreshLock {
        let url = Paths.claudeDir.appendingPathComponent(".oauth_refresh.lock")
        private(set) var mine = false

        init() throws {
            let deadline = Date().addingTimeInterval(15)
            while true {
                if mkdir(url.path, 0o755) == 0 { mine = true; return }
                if errno == ENOENT { return }       // no ~/.claude: nothing running to lock out
                let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if m.map({ Date().timeIntervalSince($0) > 60 }) ?? true { return }   // stale
                guard Date() < deadline else { throw ProviderError.other("Claude Code is refreshing its login, try again") }
                usleep(250_000)
            }
        }

        func release() { if mine { rmdir(url.path) } }
    }
}

// MARK: - Codex CLI

/// `$CODEX_HOME/auth.json`. Codex reads it at start; a running session never adopts another
/// account (its guarded reload refuses an account change), so new sessions get the new login.
enum CodexCLI {
    static var file: URL { Paths.codexHome.appendingPathComponent("auth.json") }

    static func read() -> Holding? {
        guard let t = Files.object(try? Data(contentsOf: file))?["tokens"] as? [String: Any],
              let at = t["access_token"] as? String else { return nil }
        let f = Family.codex(access: at, refresh: t["refresh_token"] as? String, idToken: t["id_token"] as? String,
                             accountId: t["account_id"] as? String)
        return Holding(tool: .codex, provider: .codex, family: f, account: f.key)
    }

    static func install(_ f: Family) throws -> [Holding] {
        let old = read()
        let data = try? Data(contentsOf: file)
        if let data { try Backup.save("codex-auth.json", data) }
        var o = Files.object(data) ?? [:]
        o["auth_mode"] = "chatgpt"
        if o["OPENAI_API_KEY"] == nil { o["OPENAI_API_KEY"] = NSNull() }
        o["tokens"] = tokens(f)
        o["last_refresh"] = Stamp.iso(Date())
        try Files.write(try Files.json(o), to: file)
        return old.map { [$0] } ?? []
    }

    static func tokens(_ f: Family) -> [String: Any] {
        var t: [String: Any] = ["access_token": f.access, "refresh_token": f.refresh ?? ""]
        if let v = f.idToken { t["id_token"] = v }
        if let v = f.accountId { t["account_id"] = v }
        return t
    }
}

// MARK: - Hermes

/// Every Hermes home: `~/.hermes` ("default") and each `~/.hermes/profiles/*`.
/// Claude: a long-lived token in each `.env`'s ANTHROPIC_TOKEN, re-read every gateway turn.
/// Codex: `auth.json` `providers.openai-codex` per home, which Hermes syncs its pool from
/// (under `auth.lock`) before using or refreshing a login.
enum Hermes {
    static func homes() -> [(name: String, url: URL)] {
        let root = Paths.hermesRoot
        var out = [(name: "default", url: root)]
        let profiles = root.appendingPathComponent("profiles")
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted() where !n.hasPrefix(".") {
            var dir: ObjCBool = false
            let u = profiles.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { out.append((n, u)) }
        }
        return out
    }

    static func url(_ home: String) -> URL {
        home == "default" ? Paths.hermesRoot : Paths.hermesRoot.appendingPathComponent("profiles/\(home)")
    }

    static func read(minted: [String: Minted]) -> [Holding] {
        var out: [Holding] = []
        for h in homes() {
            if let text = try? String(contentsOf: h.url.appendingPathComponent(".env"), encoding: .utf8), let tok = envToken(text) {
                let m = minted[Secret.fingerprint(tok)]
                out.append(Holding(tool: .hermes, provider: .claude, location: h.name,
                                   family: Family(provider: .claude, access: tok, expiresAt: m?.expiresAt), account: m?.account))
            }
            if let o = Files.object(try? Data(contentsOf: h.url.appendingPathComponent("auth.json"))), let c = codex(o, home: h.name) {
                out.append(c)
            }
        }
        return out
    }

    // .env: only the ANTHROPIC_TOKEN line is ever touched.

    static func envLine(_ line: String) -> (prefix: String, quote: String, value: String)? {
        var s = Substring(line)
        var prefix = String(s.prefix { $0 == " " || $0 == "\t" })
        s = s.dropFirst(prefix.count)
        if s.hasPrefix("export ") { prefix += "export "; s = s.dropFirst(7) }
        guard s.hasPrefix("ANTHROPIC_TOKEN=") else { return nil }
        var v = String(s.dropFirst("ANTHROPIC_TOKEN=".count)).trimmingCharacters(in: .whitespaces)
        var quote = ""
        if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { quote = String(q); v = String(v.dropFirst().dropLast()) }
        return (prefix, quote, v)
    }

    static func envToken(_ text: String) -> String? {
        text.components(separatedBy: "\n").lazy.compactMap { envLine($0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))) }
            .first { !$0.value.isEmpty }?.value
    }

    /// The same text with every set ANTHROPIC_TOKEN line holding `token`; nil if there's none.
    static func rewrite(_ text: String, token: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        var hit = false
        for i in lines.indices {
            let cr = lines[i].hasSuffix("\r")
            guard let l = envLine(cr ? String(lines[i].dropLast()) : lines[i]), !l.value.isEmpty else { continue }
            lines[i] = "\(l.prefix)ANTHROPIC_TOKEN=\(l.quote)\(token)\(l.quote)\(cr ? "\r" : "")"
            hit = true
        }
        return hit ? lines.joined(separator: "\n") : nil
    }

    /// Sets ANTHROPIC_TOKEN in every home that sets it. All files or none.
    static func installToken(_ f: Family, minted: [String: Minted]) throws -> [Holding] {
        let old = read(minted: minted).filter { $0.provider == .claude }
        let targets = homes().compactMap { h -> (name: String, url: URL, data: Data, new: Data)? in
            let u = h.url.appendingPathComponent(".env")
            guard let data = try? Data(contentsOf: u), let text = String(data: data, encoding: .utf8),
                  let new = rewrite(text, token: f.access) else { return nil }
            return (h.name, u, data, Data(new.utf8))
        }
        guard !targets.isEmpty else { throw ProviderError.other("no Hermes home sets ANTHROPIC_TOKEN") }
        for t in targets { try Backup.save("hermes-\(t.name)-env", t.data) }
        var done: [(URL, Data)] = []
        do {
            for t in targets { try Files.write(t.new, to: t.url); done.append((t.url, t.data)) }
        } catch {
            for (u, d) in done.reversed() { try? Files.write(d, to: u) }
            throw error
        }
        return old
    }

    // auth.json: providers.openai-codex, and the pool entry that mirrors it.

    static func codex(_ o: [String: Any], home: String) -> Holding? {
        guard let st = (o["providers"] as? [String: Any])?["openai-codex"] as? [String: Any],
              let t = st["tokens"] as? [String: Any], let at = t["access_token"] as? String, !at.isEmpty else { return nil }
        var f = Family.codex(access: at, refresh: t["refresh_token"] as? String, idToken: t["id_token"] as? String,
                             accountId: t["account_id"] as? String)
        var last = (st["last_refresh"] as? String).flatMap(JSON.parseDate)
        // A pool entry that rotated after the singleton holds the live end of the chain.
        let pool = ((o["credential_pool"] as? [String: Any])?["openai-codex"] as? [[String: Any]]) ?? []
        if let e = pool.first(where: { $0["source"] as? String == "device_code" }),
           let pa = e["access_token"] as? String, pa != at,
           let pl = (e["last_refresh"] as? String).flatMap(JSON.parseDate), pl > (last ?? .distantPast) {
            f = Family.codex(access: pa, refresh: e["refresh_token"] as? String, idToken: f.idToken, accountId: f.accountId)
            last = pl
        }
        var dead: String?
        if let err = st["last_auth_error"] as? [String: Any], err["relogin_required"] as? Bool == true,
           ((err["at"] as? String).flatMap(JSON.parseDate) ?? .distantFuture) > (last ?? .distantPast) {
            dead = (err["code"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "needs a new sign-in"
        }
        return Holding(tool: .hermes, provider: .codex, location: home, home: home, family: f, dead: dead, account: f.key)
    }

    static func codexHomes() -> [String] {
        homes().filter { h in
            let o = Files.object(try? Data(contentsOf: h.url.appendingPathComponent("auth.json")))
            return ((o?["providers"] as? [String: Any])?["openai-codex"] as? [String: Any])?["tokens"] != nil
        }.map(\.name)
    }

    /// Installs `f` as one home's Codex login, under Hermes's own `auth.lock`.
    static func installCodex(_ f: Family, home: String) throws -> [Holding] {
        let dir = url(home)
        let file = dir.appendingPathComponent("auth.json")
        let lock = try FileLock(dir.appendingPathComponent("auth.lock"), timeout: 10)
        defer { lock.release() }
        let data = try Data(contentsOf: file)
        guard var o = Files.object(data) else { throw ProviderError.other("\(file.path) isn't JSON") }
        let old = codex(o, home: home)
        try Backup.save("hermes-\(home)-auth.json", data)

        let now = Stamp.iso(Date())
        var providers = o["providers"] as? [String: Any] ?? [:]
        var st = providers["openai-codex"] as? [String: Any] ?? [:]
        st["tokens"] = CodexCLI.tokens(f)
        st["last_refresh"] = now
        st["auth_mode"] = "chatgpt"
        st["last_auth_error"] = nil
        providers["openai-codex"] = st
        o["providers"] = providers
        if var pool = o["credential_pool"] as? [String: Any], var list = pool["openai-codex"] as? [[String: Any]] {
            for i in list.indices where list[i]["source"] as? String == "device_code" {
                list[i]["access_token"] = f.access
                list[i]["refresh_token"] = f.refresh ?? ""
                list[i]["last_refresh"] = now
                for k in ["last_status", "last_status_at", "last_error_code", "last_error_reason", "last_error_message", "last_error_reset_at"] {
                    list[i][k] = NSNull()
                }
            }
            pool["openai-codex"] = list
            o["credential_pool"] = pool
        }
        o["updated_at"] = now
        try Files.write(try Files.json(o), to: file)
        return old.map { [$0] } ?? []
    }
}

// MARK: - OMP

/// `~/.omp/agent/agent.db`, table `auth_credentials`. OMP lists rows with no `disabled_cause`
/// and re-reads them whenever `auth_change_revision` moves (the table's triggers bump it), on its
/// next credential lookup. A row under an unexpired refresh lease is never moved.
enum OMP {
    static func provider(_ p: Provider) -> String { p == .claude ? "anthropic" : "openai-codex" }

    static func query(_ sql: String) -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: Paths.ompDB.path) else { return nil }
        let r = Shell.exec("/usr/bin/sqlite3", ["-readonly", "-json", Paths.ompDB.path, sql])
        guard r.status == 0 else { return nil }
        if r.out.isEmpty { return [] }
        return (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]]
    }

    static func read() -> [Holding] {
        let rows = query("SELECT id, provider, data, disabled_cause FROM auth_credentials WHERE provider IN ('anthropic', 'openai-codex') ORDER BY id") ?? []
        return rows.compactMap(holding)
    }

    static func holding(_ row: [String: Any]) -> Holding? {
        guard let d = Files.object((row["data"] as? String).map { Data($0.utf8) }), let at = d["access"] as? String else { return nil }
        let p: Provider = row["provider"] as? String == "anthropic" ? .claude : .codex
        var f = p == .codex
            ? Family.codex(access: at, refresh: d["refresh"] as? String, idToken: nil, accountId: d["accountId"] as? String)
            : Family(provider: .claude, access: at, refresh: d["refresh"] as? String, accountId: d["accountId"] as? String)
        f.expiresAt = (d["expires"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        f.email = d["email"] as? String ?? f.email
        f.orgId = d["orgId"] as? String
        f.orgName = d["orgName"] as? String
        let id = (row["id"] as? NSNumber)?.intValue ?? 0
        return Holding(tool: .omp, provider: p, location: "row \(id)", family: f,
                       dead: row["disabled_cause"] as? String, account: f.key)
    }

    /// Replaces the live rows for f's provider with one row for `f`, in one transaction that
    /// first checks no refresh lease is out on them. Dead rows and other providers stay.
    static func install(_ f: Family) throws -> [Holding] {
        let pid = provider(f.provider)
        guard let all = query("SELECT * FROM auth_credentials") else { throw ProviderError.other("can't read \(Paths.ompDB.path)") }
        try Backup.save("omp-auth_credentials", try Files.json(all))

        var data: [String: Any] = ["access": f.access, "refresh": f.refresh ?? "", "expires": Stamp.ms(f.expiresAt)]
        data["email"] = f.email
        data["accountId"] = f.accountId
        if f.provider == .claude {
            data["orgId"] = f.orgId
            data["orgName"] = f.orgName
            data["authorizedAt"] = Stamp.ms(Date())
        }
        let email = f.email.map { "email:\($0.trimmingCharacters(in: .whitespaces).lowercased())" }
        let identity = f.provider == .claude ? [email, f.orgId.map { "org:\($0)" }].compactMap { $0 }.joined(separator: "|") : email
        let json = String(data: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let live = "SELECT id FROM auth_credentials WHERE provider = \(q(pid)) AND disabled_cause IS NULL"

        for _ in 0..<40 {
            let sql = """
            .bail on
            .timeout 5000
            .mode json
            BEGIN IMMEDIATE;
            CREATE TEMP TABLE brim_lease_check (leased INTEGER CHECK (leased = 0));
            INSERT INTO brim_lease_check SELECT count(*) FROM auth_credential_refresh_leases WHERE expires_at_ms > \(Stamp.ms(Date())) AND credential_id IN (\(live));
            SELECT id, provider, data, disabled_cause FROM auth_credentials WHERE id IN (\(live)) ORDER BY id;
            DELETE FROM auth_credentials WHERE id IN (\(live));
            INSERT INTO auth_credentials (provider, credential_type, data, identity_key) VALUES (\(q(pid)), 'oauth', \(q(json)), \(identity.map { $0.isEmpty ? "NULL" : q($0) } ?? "NULL"));
            COMMIT;
            """
            let r = Shell.exec("/usr/bin/sqlite3", [Paths.ompDB.path], stdin: sql)
            if r.status == 0 {
                let rows = r.out.isEmpty ? [] : ((try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] ?? [])
                return rows.compactMap(holding)
            }
            guard r.err.contains("CHECK constraint failed") else { throw ProviderError.other("OMP write failed: \(r.err)") }
            usleep(500_000)     // OMP is refreshing that login right now; its lease lasts 15 s at most.
        }
        throw ProviderError.other("OMP is refreshing its login, try again")
    }
}

// MARK: - All of them

enum Tools {
    /// What every tool on this Mac holds now. Reads only.
    static func scan(minted: [String: Minted]) -> [Holding] {
        var out: [Holding] = []
        if let h = ClaudeCode.read() { out.append(h) }
        if let h = CodexCLI.read() { out.append(h) }
        out += Hermes.read(minted: minted)
        out += OMP.read()
        return out
    }

    static func read(_ t: Tool, _ p: Provider, minted: [String: Minted]) -> [Holding] {
        switch t {
        case .claudeCode: return ClaudeCode.read().map { [$0] } ?? []
        case .codex: return CodexCLI.read().map { [$0] } ?? []
        case .hermes: return Hermes.read(minted: minted).filter { $0.provider == p }
        case .omp: return OMP.read().filter { $0.provider == p }
        }
    }

    /// The vault homes a switch of `t` writes for `p`: one per Hermes home for Codex, else one.
    static func places(_ t: Tool, _ p: Provider) -> [String?] {
        t == .hermes && p == .codex ? Hermes.codexHomes() : [nil]
    }

    /// Installs `f` and returns the logins it displaced.
    static func install(_ t: Tool, home: String?, _ f: Family, profile: [String: Any]?, minted: [String: Minted]) throws -> [Holding] {
        switch t {
        case .claudeCode: return try ClaudeCode.install(f, profile: profile ?? [:])
        case .codex: return try CodexCLI.install(f)
        case .hermes:
            if f.provider == .claude { return try Hermes.installToken(f, minted: minted) }
            guard let home else { throw ProviderError.other("no Hermes home") }
            return try Hermes.installCodex(f, home: home)
        case .omp: return try OMP.install(f)
        }
    }
}

// MARK: - Editing one key of a large JSON file

enum JSONText {
    /// Replaces one top-level key's value, leaving every other byte of the file as it was.
    static func replacing(_ key: String, in data: Data, with value: [String: Any]) throws -> Data {
        let b = [UInt8](data)
        let bad = ProviderError.other("unexpected JSON")
        var i = 0
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }
        func ws() { while i < b.count, isSpace(b[i]) { i += 1 } }
        func string() throws {
            i += 1
            while i < b.count {
                if b[i] == 0x5c { i += 2; continue }
                i += 1
                if b[i - 1] == 0x22 { return }
            }
            throw bad
        }
        func skipValue() throws {
            guard i < b.count else { throw bad }
            switch b[i] {
            case 0x22: try string()
            case 0x7b, 0x5b:
                var depth = 0
                while i < b.count {
                    if b[i] == 0x22 { try string(); continue }
                    if b[i] == 0x7b || b[i] == 0x5b { depth += 1 }
                    if b[i] == 0x7d || b[i] == 0x5d { depth -= 1; if depth == 0 { i += 1; return } }
                    i += 1
                }
                throw bad
            default:
                while i < b.count, b[i] != 0x2c, b[i] != 0x7d, !isSpace(b[i]) { i += 1 }
            }
        }
        var rendered = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        rendered = Data(String(decoding: rendered, as: UTF8.self).replacingOccurrences(of: "\n", with: "\n  ").utf8)

        ws()
        guard i < b.count, b[i] == 0x7b else { throw bad }
        let open = i
        i += 1
        var out: Data?
        while out == nil {
            ws()
            if i < b.count, b[i] == 0x7d { break }
            guard i < b.count, b[i] == 0x22 else { throw bad }
            let k0 = i
            try string()
            let name = try JSONSerialization.jsonObject(with: Data(b[k0..<i]), options: .fragmentsAllowed) as? String
            ws()
            guard i < b.count, b[i] == 0x3a else { throw bad }
            i += 1
            ws()
            let v0 = i
            try skipValue()
            if name == key { out = Data(b[..<v0]) + rendered + Data(b[i...]); break }
            ws()
            guard i < b.count, b[i] == 0x2c else { break }
            i += 1
        }
        if out == nil {
            // Not there yet: add it as the first key.
            var j = open + 1
            while j < b.count, isSpace(b[j]) { j += 1 }
            let empty = j < b.count && b[j] == 0x7d
            out = Data(b[...open]) + Data("\n  \"\(key)\": ".utf8) + rendered + Data((empty ? "\n" : ",").utf8) + Data(b[(open + 1)...])
        }
        // Never hand back something the tool can't read.
        guard let result = out, let check = Files.object(result), check[key] != nil else { throw bad }
        return result
    }
}

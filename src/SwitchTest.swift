import Foundation

// `brim selftest`, part 2: account switching against throwaway copies of every tool's store,
// with a fake OAuth server that kills a refresh token the moment it's used (as Claude and
// ChatGPT do). Nothing here touches the real stores: every path points into a temp dir, and
// Claude Code's Keychain item is a throwaway service name, deleted at the end.

extension Selftest {
    /// The fake server: who each token belongs to, and which refresh tokens are spent.
    final class Server {
        var owner: [String: String] = [:]      // token -> remote account id
        var spent: Set<String> = []
        var browser = ""                       // the account the browser is signed in as
        var signIns = 0
        var refreshes = 0
        var n = 0

        func mint(_ p: Provider, _ acct: String, longLived: Bool = false) -> Family {
            n += 1
            if p == .codex {
                let at = Selftest.jwt(["exp": Date().addingTimeInterval(10 * 86400).timeIntervalSince1970,
                                       "https://api.openai.com/auth": ["chatgpt_account_id": acct]])
                let idt = Selftest.jwt(["email": "\(acct)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": acct]])
                let rt = "rt-\(acct)-\(n)"
                owner[at] = acct; owner[rt] = acct
                return Family.codex(access: at, refresh: rt, idToken: idt)
            }
            let at = "sk-ant-oat-\(acct)-\(n)"
            owner[at] = acct
            if longLived { return Family(provider: .claude, access: at, expiresAt: Date().addingTimeInterval(365 * 86400), accountId: acct, email: "\(acct)@example.com") }
            let rt = "sk-ant-ort-\(acct)-\(n)"
            owner[rt] = acct
            return Family(provider: .claude, access: at, refresh: rt, expiresAt: Date().addingTimeInterval(8 * 3600),
                          accountId: acct, email: "\(acct)@example.com", orgId: "org-\(acct)", orgName: "\(acct) org",
                          scopes: Claude.scopes, subscriptionType: "max")
        }

        /// A tool (or Brim) refreshing: the old refresh token dies.
        func rotate(_ f: Family) throws -> Family {
            guard let rt = f.refresh, let acct = owner[rt], !spent.contains(rt) else { throw ProviderError.auth("invalid_grant") }
            spent.insert(rt)
            refreshes += 1
            var n = mint(f.provider, acct)
            n.idToken = f.idToken ?? n.idToken
            return n
        }

        var net: Net {
            Net(refresh: { try self.rotate($0) },
                profile: { tok in
                    guard let a = self.owner[tok] else { throw ProviderError.auth("signed out (401)") }
                    return ["account": ["uuid": a, "email": "\(a)@example.com", "display_name": a],
                            "organization": ["uuid": "org-\(a)", "name": "\(a) org", "organization_type": "claude_max",
                                             "rate_limit_tier": "default_claude_max_20x"]]
                },
                signIn: { p, long in self.signIns += 1; return self.mint(p, self.browser, longLived: long) })
        }
    }

    static func jwt(_ claims: [String: Any]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: claims)
        return "e30.\(d.base64url).sig"
    }

    static func switching() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("brim-selftest-\(getpid())")
        try? fm.removeItem(at: tmp)
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = "brim-selftest-\(getpid())"
        let env = ["BRIM_HOME": "brim", "CODEX_HOME": "codex", "BRIM_CLAUDE_JSON": "claude.json", "CLAUDE_CONFIG_DIR": "claude",
                   "BRIM_HERMES_ROOT": "hermes", "BRIM_OMP_DB": "omp.db"]
        for (k, v) in env { setenv(k, tmp.appendingPathComponent(v).path, 1) }
        setenv("BRIM_KEYCHAIN_SERVICE", service, 1)
        defer {
            _ = Shell.exec("/usr/bin/security", ["delete-generic-password", "-a", ClaudeCode.user, "-s", service])
            try? fm.removeItem(at: tmp)
        }
        expect(Paths.vault.path.hasPrefix(tmp.path) && Paths.ompDB.path.hasPrefix(tmp.path) && Paths.keychainService == service,
               "every store path points into the temp dir")
        guard Paths.ompDB.path.hasPrefix(tmp.path), Paths.keychainService == service else { return }
        for d in ["brim", "codex", "claude", "hermes/profiles/p1", "hermes/profiles/p2", "hermes/profiles/p3"] {
            try! fm.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        let srv = Server()
        let net = srv.net
        func run(_ t: Tool, _ a: Account) -> Error? {
            do { _ = try CLI.await_ { try await Switcher.run(t, to: a, net: net) }; return nil } catch { return error }
        }
        func account(_ p: Provider, _ id: String, _ label: String) -> Account {
            Account(id: "id-\(id)", provider: p, source: .tool, label: label, remoteId: id)
        }

        /// No family in two places, and none holding a spent refresh token. Hermes's Claude token
        /// in several homes is one holder; so is a Hermes home's Codex singleton and its pool copy.
        func invariant(_ when: String) {
            var holders: [String: Set<String>] = [:]
            func add(_ holder: String, _ f: Family?) {
                guard let f else { return }
                holders[f.refresh ?? f.access, default: []].insert(holder)
                if let rt = f.refresh { expect(!srv.spent.contains(rt), "\(when): \(holder) holds a spent refresh token") }
            }
            let minted = Vault.load().minted
            add("claude-code", ClaudeCode.read()?.family)
            add("codex", CodexCLI.read()?.family)
            for h in Hermes.read(minted: minted) { add("hermes\(h.provider == .codex ? "-\(h.home ?? "")" : "")", h.family) }
            for h in Hermes.homes() {
                let o = Files.object(try? Data(contentsOf: h.url.appendingPathComponent("auth.json")))
                for e in ((o?["credential_pool"] as? [String: Any])?["openai-codex"] as? [[String: Any]]) ?? [] {
                    if let rt = e["refresh_token"] as? String, !rt.isEmpty {
                        holders[rt, default: []].insert("hermes-\(h.name)")
                        expect(!srv.spent.contains(rt), "\(when): hermes pool holds a spent refresh token")
                    }
                }
            }
            for h in OMP.read() where h.dead == nil { add("omp", h.family) }
            for s in Vault.load().slots { add("vault", s.family) }
            for (_, hs) in holders { expect(hs.count == 1, "\(when): one family in \(hs.sorted().joined(separator: " + "))") }
        }
        func backups(_ prefix: String) -> Int {
            ((try? fm.contentsOfDirectory(atPath: Paths.backups.path)) ?? []).filter { $0.hasPrefix(prefix) }.count
        }
        func slot(_ acct: String, _ t: Tool, _ home: String? = nil) -> Family? {
            Vault.load().slot("\(acct.hasPrefix("x") ? "codex" : "claude"):\(acct)", t, home)?.family
        }

        // MARK: Claude Code

        let alpha = account(.claude, "ua", "Alpha"), beta = account(.claude, "ub", "Beta")
        let a1 = srv.mint(.claude, "ua")
        try! ClaudeCode.write(["claudeAiOauth": ClaudeCode.record(a1, profile: [:]), "mcpOAuth": ["keep": "me"]], expecting: a1.access)
        let claudeJSON = """
        {
          "numStartups": 41,
          "oauthAccount": {
            "accountUuid": "ua",
            "emailAddress": "ua@example.com"
          },
          "projects": {"/x": {"allowedTools": []}},
          "tipsHistory": {"a": 1}
        }
        """
        try! Data(claudeJSON.utf8).write(to: Paths.claudeJSON)
        expect(ClaudeCode.read()?.account == "claude:ua", "claude code: reads who it holds")
        invariant("claude code start")

        srv.browser = "ub"
        expect(run(.claudeCode, beta) == nil, "claude code: switch to Beta")
        let b1 = ClaudeCode.read()?.family
        expect(ClaudeCode.read()?.account == "claude:ub" && srv.signIns == 1, "claude code: holds Beta after one sign-in")
        expect(slot("ua", .claudeCode)?.refresh == a1.refresh, "claude code: Alpha parked")
        expect((ClaudeCode.payload()?["mcpOAuth"] as? [String: String])?["keep"] == "me", "claude code: other Keychain keys kept")
        let cj = (try? String(contentsOf: Paths.claudeJSON, encoding: .utf8)) ?? ""
        expect(cj.hasPrefix("{\n  \"numStartups\": 41,\n  \"oauthAccount\": ") &&
               cj.hasSuffix(",\n  \"projects\": {\"/x\": {\"allowedTools\": []}},\n  \"tipsHistory\": {\"a\": 1}\n}"),
               "claude code: ~/.claude.json changed only in oauthAccount")
        expect((ClaudeCode.oauthAccount()?["accountUuid"] as? String) == "ub", "claude code: oauthAccount is Beta")
        expect(backups("claude-code-keychain") == 1 && backups("claude-code-claude.json") == 1, "claude code: backed up before writing")
        invariant("claude code -> Beta")

        // Claude Code refreshes Beta while it holds it.
        let b2 = try! srv.rotate(b1!)
        var p = ClaudeCode.payload()!
        p["claudeAiOauth"] = ClaudeCode.record(b2, profile: [:])
        try! ClaudeCode.write(p, expecting: b2.access)
        invariant("claude code refreshed Beta")

        expect(run(.claudeCode, alpha) == nil, "claude code: back to Alpha")
        expect(ClaudeCode.read()?.family.refresh == a1.refresh && srv.signIns == 1, "claude code: Alpha back, no sign-in")
        expect(slot("ub", .claudeCode)?.refresh == b2.refresh, "claude code: save-back kept Beta's refreshed token")
        invariant("claude code -> Alpha")
        expect(run(.claudeCode, beta) == nil && ClaudeCode.read()?.family.refresh == b2.refresh, "claude code: Beta again, refreshed family")
        invariant("claude code -> Beta again")
        expect(run(.claudeCode, beta) == nil && srv.signIns == 1, "claude code: switching to who it already holds is a no-op")

        // A failure mid-switch: ~/.claude.json can't be replaced, so the Keychain is put back too.
        let before = ClaudeCode.payload().flatMap { try? Files.json($0) }
        let dir = Paths.claudeJSON.deletingLastPathComponent()
        chmod(dir.path, 0o500)
        let err = run(.claudeCode, alpha)
        chmod(dir.path, 0o700)
        expect(err != nil, "claude code: unwritable ~/.claude.json fails the switch")
        expect(ClaudeCode.payload().flatMap { try? Files.json($0) } == before && ClaudeCode.read()?.account == "claude:ub",
               "claude code: failed switch leaves the Keychain as it was")
        expect(slot("ua", .claudeCode)?.refresh == a1.refresh, "claude code: failed switch keeps Alpha in the vault")
        invariant("claude code failed switch")

        // MARK: Codex CLI

        let xa = account(.codex, "xa", "Xavier"), xb = account(.codex, "xb", "Yvonne")
        let x1 = srv.mint(.codex, "xa")
        let codexFile: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": CodexCLI.tokens(x1), "last_refresh": "2026-10-01T00:00:00Z"]
        try! Files.write(try! Files.json(codexFile), to: CodexCLI.file)
        expect(CodexCLI.read()?.account == "codex:xa" && CodexCLI.read()?.family.email == "xa@example.com", "codex: reads who it holds")
        srv.browser = "xb"
        expect(run(.codex, xb) == nil && CodexCLI.read()?.account == "codex:xb", "codex: switch to Yvonne")
        expect(backups("codex-auth.json") == 1, "codex: backed up before writing")
        invariant("codex -> Yvonne")
        let y2 = try! srv.rotate(CodexCLI.read()!.family)
        var cf = Files.object(try? Data(contentsOf: CodexCLI.file))!
        cf["tokens"] = CodexCLI.tokens(y2)
        try! Files.write(try! Files.json(cf), to: CodexCLI.file)
        expect(run(.codex, xa) == nil && CodexCLI.read()?.family.refresh == x1.refresh, "codex: back to Xavier")
        expect(slot("xb", .codex)?.refresh == y2.refresh, "codex: save-back kept Yvonne's refreshed token")
        invariant("codex -> Xavier")

        // A failure mid-switch: the directory is read-only, so auth.json can't be replaced.
        let codexBefore = try? Data(contentsOf: CodexCLI.file)
        chmod(Paths.codexHome.path, 0o500)
        let cerr = run(.codex, xb)
        chmod(Paths.codexHome.path, 0o700)
        expect(cerr != nil && (try? Data(contentsOf: CodexCLI.file)) == codexBefore, "codex: failed switch leaves auth.json byte for byte")
        expect(slot("xb", .codex)?.refresh == y2.refresh, "codex: failed switch keeps Yvonne in the vault")
        invariant("codex failed switch")
        expect(run(.codex, xb) == nil && CodexCLI.read()?.family.refresh == y2.refresh, "codex: Yvonne again after the failure")
        invariant("codex -> Yvonne again")

        // MARK: Hermes, Claude: one long-lived token in every .env that sets one

        let unknown = "sk-ant-oat01-not-minted-by-brim"
        let envs = [
            "hermes/.env": "# root\nOPENROUTER_API_KEY=or-1\n",
            "hermes/profiles/p1/.env": "A=1\nANTHROPIC_TOKEN=\(unknown)\nB=2\n",
            "hermes/profiles/p2/.env": "export ANTHROPIC_TOKEN=\"\(unknown)\"\r\nC=3\r\n",
            "hermes/profiles/p3/.env": "# ANTHROPIC_TOKEN=commented\nANTHROPIC_TOKEN=\nD=4\n",
        ]
        for (f, s) in envs { try! Data(s.utf8).write(to: tmp.appendingPathComponent(f)) }
        func dotenv(_ f: String) -> String { (try? String(contentsOf: tmp.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        let hc = Hermes.read(minted: [:]).filter { $0.provider == .claude }
        expect(hc.count == 2 && hc.allSatisfy { $0.account == nil }, "hermes: a token Brim didn't mint is an unknown account")
        srv.browser = "ua"
        expect(run(.hermes, alpha) == nil, "hermes: switch Claude to Alpha")
        let la = Hermes.read(minted: Vault.load().minted).filter { $0.provider == .claude }
        expect(la.count == 2 && la.allSatisfy { $0.account == "claude:ua" && $0.family.refresh == nil }, "hermes: both homes hold Alpha's minted token")
        let laTok = la.first?.family.access ?? "?"
        expect(dotenv("hermes/profiles/p1/.env") == "A=1\nANTHROPIC_TOKEN=\(laTok)\nB=2\n", "hermes: p1 .env changed only on the token line")
        expect(dotenv("hermes/profiles/p2/.env") == "export ANTHROPIC_TOKEN=\"\(laTok)\"\r\nC=3\r\n", "hermes: p2 keeps export, quotes, CRLF")
        expect(dotenv("hermes/profiles/p3/.env") == envs["hermes/profiles/p3/.env"] && dotenv("hermes/.env") == envs["hermes/.env"],
               "hermes: homes without a token are untouched")
        expect(backups("hermes-p1-env") == 1 && backups("hermes-p2-env") == 1 && backups("hermes-p3-env") == 0, "hermes: backed up each .env it wrote")
        invariant("hermes -> Alpha")
        srv.browser = "ub"
        expect(run(.hermes, beta) == nil && srv.signIns == 4, "hermes: switch Claude to Beta mints one token")
        expect(slot("ua", .hermes)?.access == laTok, "hermes: Alpha's token parked")
        expect(run(.hermes, alpha) == nil && srv.signIns == 4, "hermes: back to Alpha without a sign-in")
        expect(Hermes.read(minted: Vault.load().minted).filter { $0.provider == .claude }.allSatisfy { $0.family.access == laTok },
               "hermes: Alpha's token back in every home")
        invariant("hermes -> Alpha again")

        // MARK: Hermes, Codex: the home's providers.openai-codex, and its pool copy

        let h1 = srv.mint(.codex, "xa")
        let hermesAuth: [String: Any] = [
            "version": 1,
            "providers": ["openai-codex": ["tokens": CodexCLI.tokens(h1), "last_refresh": "2026-10-20T00:00:00.000000Z", "auth_mode": "chatgpt",
                                           "last_auth_error": ["code": "refresh_token_reused", "relogin_required": true, "at": "2026-10-01T00:00:00Z"]]],
            "credential_pool": ["openai-codex": [["id": "c1", "source": "device_code", "access_token": h1.access, "refresh_token": h1.refresh!,
                                                  "last_refresh": "2026-10-20T00:00:00.000000Z", "last_status": "exhausted"]],
                                "openrouter": [["id": "o1", "source": "env:OPENROUTER_API_KEY"]]],
        ]
        let hauth = tmp.appendingPathComponent("hermes/auth.json")
        try! Files.write(try! Files.json(hermesAuth), to: hauth)
        expect(Tools.places(.hermes, .codex) == ["default"], "hermes: Codex lives in the root home only")
        srv.browser = "xb"
        expect(run(.hermes, xb) == nil, "hermes: switch Codex to Yvonne")
        var ho = Files.object(try? Data(contentsOf: hauth))!
        var st = (ho["providers"] as! [String: Any])["openai-codex"] as! [String: Any]
        var pool = ((ho["credential_pool"] as! [String: Any])["openai-codex"] as! [[String: Any]])[0]
        expect(Hermes.read(minted: [:]).first { $0.provider == .codex }?.account == "codex:xb", "hermes: Codex holds Yvonne")
        expect(st["last_auth_error"] == nil && pool["refresh_token"] as? String == (st["tokens"] as? [String: Any])?["refresh_token"] as? String
               && pool["last_status"] is NSNull, "hermes: error cleared, pool entry follows the singleton")
        expect(((ho["credential_pool"] as! [String: Any])["openrouter"] as? [[String: Any]])?.count == 1, "hermes: other pools untouched")
        expect(slot("xa", .hermes, "default")?.refresh == h1.refresh, "hermes: Xavier's Codex login parked for that home")
        invariant("hermes codex -> Yvonne")
        // Hermes refreshes it (singleton and pool), then we switch back.
        let hy = try! srv.rotate(Hermes.read(minted: [:]).first { $0.provider == .codex }!.family)
        st["tokens"] = CodexCLI.tokens(hy)
        pool["access_token"] = hy.access; pool["refresh_token"] = hy.refresh!
        ho["providers"] = ["openai-codex": st]
        var hp = ho["credential_pool"] as! [String: Any]
        hp["openai-codex"] = [pool]
        ho["credential_pool"] = hp
        try! Files.write(try! Files.json(ho), to: hauth)
        expect(run(.hermes, xa) == nil, "hermes: Codex back to Xavier")
        expect(slot("xb", .hermes, "default")?.refresh == hy.refresh, "hermes: save-back kept Yvonne's refreshed token")
        invariant("hermes codex -> Xavier")

        // MARK: OMP

        let schema = """
        CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY AUTOINCREMENT, provider TEXT NOT NULL, credential_type TEXT NOT NULL,
          data TEXT NOT NULL, disabled_cause TEXT DEFAULT NULL, identity_key TEXT DEFAULT NULL,
          created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
          updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)));
        CREATE TABLE auth_credential_refresh_leases (credential_id INTEGER PRIMARY KEY, owner TEXT NOT NULL, expires_at_ms INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE auth_change_revision (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
        INSERT INTO auth_change_revision VALUES (1, 0);
        CREATE TRIGGER r1 AFTER INSERT ON auth_credentials BEGIN UPDATE auth_change_revision SET revision = revision + 1 WHERE id = 1; END;
        CREATE TRIGGER r2 AFTER UPDATE ON auth_credentials BEGIN UPDATE auth_change_revision SET revision = revision + 1 WHERE id = 1; END;
        CREATE TRIGGER r3 AFTER DELETE ON auth_credentials BEGIN UPDATE auth_change_revision SET revision = revision + 1 WHERE id = 1; END;
        """
        func sql(_ s: String) -> String { Shell.exec("/usr/bin/sqlite3", [Paths.ompDB.path], stdin: s).out }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        func row(_ f: Family) -> String {
            let d: [String: Any] = ["access": f.access, "refresh": f.refresh!, "expires": Stamp.ms(f.expiresAt), "email": f.email!, "accountId": f.accountId!]
            return q(String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self))
        }
        let o1 = srv.mint(.claude, "ua"), deadFam = srv.mint(.claude, "ua")
        _ = sql(schema + """
        INSERT INTO auth_credentials (provider, credential_type, data) VALUES ('google-antigravity', 'oauth', '{"access":"g","refresh":"g"}');
        INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES ('anthropic', 'oauth', \(row(deadFam)), 'invalid_grant');
        INSERT INTO auth_credentials (provider, credential_type, data) VALUES ('anthropic', 'oauth', \(row(o1)));
        """)
        func revision() -> Int { Int(sql("SELECT revision FROM auth_change_revision;")) ?? -1 }
        let rev = revision()
        expect(OMP.read().filter { $0.provider == .claude }.map { $0.dead != nil } == [true, false], "omp: reads a dead and a live row")
        srv.browser = "ub"
        expect(run(.omp, beta) == nil, "omp: switch Claude to Beta")
        let live = OMP.read().filter { $0.provider == .claude && $0.dead == nil }
        expect(live.count == 1 && live[0].account == "claude:ub", "omp: one live Claude row, Beta's")
        expect(OMP.read().contains { $0.dead != nil && $0.family.refresh == deadFam.refresh }, "omp: the dead row stays where it was")
        expect(sql("SELECT count(*) FROM auth_credentials WHERE provider = 'google-antigravity';") == "1", "omp: other providers untouched")
        expect(revision() > rev, "omp: auth_change_revision moved, so running OMPs re-read")
        expect(sql("SELECT identity_key FROM auth_credentials WHERE provider = 'anthropic' AND disabled_cause IS NULL;") == "email:ub@example.com|org:org-ub",
               "omp: identity key the way OMP derives it")
        expect(slot("ua", .omp)?.refresh == o1.refresh, "omp: Alpha parked")
        expect(backups("omp-auth_credentials") == 1, "omp: backed up before writing")
        invariant("omp -> Beta")
        // OMP refreshes Beta, then holds a lease while refreshing again: the switch waits it out.
        let ob = try! srv.rotate(live[0].family)
        _ = sql("UPDATE auth_credentials SET data = \(row(ob)) WHERE provider = 'anthropic' AND disabled_cause IS NULL;")
        let leaseEnd = Stamp.ms(Date().addingTimeInterval(1.5))
        _ = sql("INSERT INTO auth_credential_refresh_leases SELECT id, 'omp-test', \(leaseEnd), 0 FROM auth_credentials WHERE provider = 'anthropic' AND disabled_cause IS NULL;")
        let t0 = Date()
        expect(run(.omp, alpha) == nil, "omp: back to Alpha once the lease ends")
        expect(Date().timeIntervalSince(t0) >= 1.2, "omp: the switch waited for the refresh lease")
        expect(OMP.read().first { $0.provider == .claude && $0.dead == nil }?.family.refresh == o1.refresh, "omp: Alpha's family back")
        expect(slot("ub", .omp)?.refresh == ob.refresh, "omp: save-back kept Beta's refreshed token")
        invariant("omp -> Alpha")

        // MARK: keeping parked logins fresh

        var v = Vault.load()
        guard let i = v.index("claude:ub", .claudeCode, nil) ?? v.index("claude:ua", .claudeCode, nil) else {
            return expect(false, "vault: a Claude Code slot is parked")
        }
        let old = v.slots[i].family
        v.slots[i].family.expiresAt = Date().addingTimeInterval(600)
        try! v.save()
        _ = try? CLI.await_ { await Switcher.keepFresh(net: net); return true }
        let fresh = Vault.load().slots[i]
        expect(fresh.family.refresh != old.refresh && srv.spent.contains(old.refresh!) && fresh.refreshedAt != nil,
               "vault: a parked login about to expire is refreshed")
        invariant("keep fresh")
        v = Vault.load()
        v.slots[i].family.refresh = "sk-ant-ort-unknown"
        v.slots[i].family.expiresAt = Date().addingTimeInterval(60)
        try! v.save()
        _ = try? CLI.await_ { await Switcher.keepFresh(net: net); return true }
        expect(Vault.load().slots[i].error != nil, "vault: a refresh the server rejects marks the slot dead")
        expect(Switcher.needsSignIn(.claudeCode, Account(id: "x", provider: .claude, source: .tool, label: "x", remoteId: Vault.load().slots[i].account.split(separator: ":").last.map(String.init))),
               "vault: a dead slot means the next switch signs in")

        // MARK: where

        let w = Where.now(accounts: [alpha, beta, xa, xb], holdings: Tools.scan(minted: Vault.load().minted), vault: Vault.load())
        let json = String(decoding: (try? JSONEncoder().encode(w)) ?? Data(), as: UTF8.self)
        expect(!json.contains("sk-ant-") && !json.contains("rt-x") && !json.contains(".sig"), "where: no token in the output")
        expect(w.tools.contains { $0.tool == .claudeCode && $0.label == "Beta" } && w.vault.contains { $0.tool == .omp && $0.label == "Beta" },
               "where: names holders and parked slots by label")
    }

    static func migration() {
        // The shape of a real accounts.json from before switching (ids kept, tokens fake).
        let old = """
        [
          {"email": "auernet@albastov.com", "hidden": true, "id": "2FD81426-A6D1-415E-B4DE-6E279A6158C0", "label": "Claude",
           "plan": "default_claude_max_20x", "provider": "claude", "remoteId": "521bf36c-709a-47b9-98b1-eaee69c8b867", "source": "claudeCode"},
          {"email": "adam7792@gmail.com", "id": "D8DC8185-8174-4B7E-9B8F-234E07D4CFE8", "label": "ChatGPT", "plan": "plus",
           "provider": "codex", "remoteId": "aaf624b1-5efc-4a65-943c-beed604e24f0", "source": "codexCLI"},
          {"accessToken": "sk-ant-fake-access", "email": "adam7792@gmail.com", "expiresAt": "2026-10-30T09:07:37Z",
           "id": "726C8E9E-6800-4CA8-AB65-278388776DD4", "label": "Adam7792", "plan": "default_claude_max_20x", "provider": "claude",
           "refreshToken": "sk-ant-fake-refresh", "remoteId": "ddd3e4ac-f06f-4dae-8c7d-5c2f72b6a148", "source": "signIn"},
          {"id": "78580883-E400-4A73-AAE8-AAC4225A8084", "keyVar": "OPENROUTER_API_KEY", "label": "OpenRouter",
           "provider": "openrouter", "source": "apiKey"}
        ]
        """
        let list = (try? JSON.decoder.decode([Account].self, from: Data(old.utf8))).map(Accounts.migrate) ?? []
        expect(list.count == 4, "migration: every account kept")
        expect(list.map(\.source) == [.tool, .tool, .signIn, .apiKey], "migration: CLI logins become tool-held identities")
        expect(list[0].label == "Claude" && list[0].isHidden && list[0].key == "claude:521bf36c-709a-47b9-98b1-eaee69c8b867",
               "migration: label, hidden flag and identity kept")
        expect(list[2].refreshToken == "sk-ant-fake-refresh" && list[2].expiresAt != nil, "migration: Brim's own sign-in keeps its tokens")
        let again = (try? JSON.decoder.decode([Account].self, from: JSON.encoder.encode(list))) ?? []
        expect(again == list && !(String(data: (try? JSON.encoder.encode(list)) ?? Data(), encoding: .utf8) ?? "").contains("claudeCode"),
               "migration: round trip in the new shape")

        // A CLI row for an account Brim also signed in to becomes one row: the sign-in, still visible.
        let dup = [Account(id: "t", provider: .claude, source: .tool, label: "Claude", email: "a@x", remoteId: "u1", hidden: true),
                   Account(id: "s", provider: .claude, source: .signIn, label: "Work", remoteId: "u1", accessToken: "x")]
        let merged = Accounts.migrate(dup)
        expect(merged.count == 1 && merged[0].source == .signIn && merged[0].label == "Work" && merged[0].email == "a@x" && !merged[0].isHidden,
               "migration: same account twice merges into the sign-in")
        let up = try? Accounts.adding(Account(id: "n", provider: .claude, source: .signIn, label: "New", remoteId: "u1", accessToken: "y"),
                                      to: [dup[0]])
        expect(up?.count == 1 && up?[0].id == "t" && up?[0].label == "Claude" && up?[0].source == .signIn, "migration: signing in upgrades the tool row")

        // Pieces of the tool writers.
        expect(Hermes.rewrite("X=1\nANTHROPIC_TOKEN=a\n", token: "b") == "X=1\nANTHROPIC_TOKEN=b\n", "hermes .env: rewrite one line")
        expect(Hermes.rewrite("X=1\n# ANTHROPIC_TOKEN=a\n", token: "b") == nil, "hermes .env: a comment is not a token")
        let big = Data("{\n  \"a\": [1, {\"oauthAccount\": 2}],\n  \"oauthAccount\": {\"x\": \"}\"},\n  \"z\": \"\\\"\"\n}\n".utf8)
        let rep = (try? JSONText.replacing("oauthAccount", in: big, with: ["y": 1])).map { String(decoding: $0, as: UTF8.self) }
        expect(rep == "{\n  \"a\": [1, {\"oauthAccount\": 2}],\n  \"oauthAccount\": {\n    \"y\" : 1\n  },\n  \"z\": \"\\\"\"\n}\n",
               "~/.claude.json: replaces only the top-level key")
        let added = (try? JSONText.replacing("oauthAccount", in: Data("{\"a\": 1}".utf8), with: [:])).flatMap { Files.object($0) }
        expect(added?["a"] as? Int == 1 && added?["oauthAccount"] != nil, "~/.claude.json: adds the key when missing")
    }
}

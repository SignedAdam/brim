import Foundation

// Reading usage from Claude and Codex, and signing in to new accounts.

enum ProviderError: Error, CustomStringConvertible {
    case auth(String), http(Int, String), other(String)
    var description: String {
        switch self {
        case .auth(let s): return s
        case .http(let c, let s): return "HTTP \(c)\(s.isEmpty ? "" : ": \(s)")"
        case .other(let s): return s
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "brim/\(VERSION)"]
        return URLSession(configuration: c)
    }()

    static func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            if code == 401 || code == 403 { throw ProviderError.auth("signed out (\(code))") }
            throw ProviderError.http(code, body.replacingOccurrences(of: "\n", with: " "))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.other("unexpected response")
        }
        return obj
    }

    static func post(_ url: String, json body: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = form.map { "\($0.key)=\(urlencode($0.value))" }.joined(separator: "&").data(using: .utf8)
        }
        return try await json(r)
    }

    static func urlencode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }
}

/// Decodes a JWT payload without verifying it (we only read our own tokens' claims).
func jwtClaims(_ token: String?) -> [String: Any] {
    guard let token else { return [:] }
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return [:] }
    var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// MARK: - Claude

enum Claude {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// Exactly what Claude Code asks for; claude.ai rejects other combinations ("Invalid request format").
    static let scopes = ["org:create_api_key", "user:profile", "user:inference", "user:sessions:claude_code",
                         "user:mcp_servers", "user:file_upload", "user:plugins"]
    static let refreshScopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers",
                                "user:file_upload", "user:plugins"]

    static func request(_ path: String, _ token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    static func profile(_ token: String) async throws -> (id: String?, email: String?, name: String?, plan: String?) {
        let o = try await HTTP.json(request("profile", token))
        let acct = o["account"] as? [String: Any] ?? [:]
        let org = o["organization"] as? [String: Any] ?? [:]
        return (acct["uuid"] as? String, acct["email"] as? String ?? acct["email_address"] as? String,
                acct["display_name"] as? String, org["rate_limit_tier"] as? String ?? org["organization_type"] as? String)
    }

    static func usage(_ token: String) async throws -> [String: Any] {
        try await HTTP.json(request("usage", token))
    }

    /// Turns /api/oauth/usage into windows. Prefers the newer `limits` list, falls back to
    /// the `five_hour` / `seven_day*` objects.
    static func parse(_ o: [String: Any]) -> [UsageWindow] {
        var out: [UsageWindow] = []
        if let limits = o["limits"] as? [[String: Any]], !limits.isEmpty {
            for l in limits {
                let kind = l["kind"] as? String ?? ""
                let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
                let reset = (l["resets_at"] as? String).flatMap(JSON.parseDate)
                switch kind {
                case "session": out.append(.init(kind: .session, label: "Session", percent: pct, resetsAt: reset, length: 5 * 3600))
                case "weekly_all": out.append(.init(kind: .weekly, label: "Week", percent: pct, resetsAt: reset, length: 7 * 86400))
                default:
                    let scope = l["scope"] as? [String: Any]
                    let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    let label = model ?? (kind.replacingOccurrences(of: "weekly_", with: "").capitalized)
                    if kind.hasPrefix("weekly") {
                        out.append(.init(kind: .model, label: label, percent: pct, resetsAt: reset, length: 7 * 86400))
                    }
                }
            }
            return out
        }
        func win(_ key: String, _ kind: UsageWindow.Kind, _ label: String, _ len: TimeInterval) {
            guard let w = o[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return }
            out.append(.init(kind: kind, label: label, percent: u, resetsAt: (w["resets_at"] as? String).flatMap(JSON.parseDate), length: len))
        }
        win("five_hour", .session, "Session", 5 * 3600)
        win("seven_day", .weekly, "Week", 7 * 86400)
        win("seven_day_opus", .model, "Opus", 7 * 86400)
        win("seven_day_sonnet", .model, "Sonnet", 7 * 86400)
        return out
    }

    static func refresh(_ refresh: String) async throws -> (access: String, refresh: String, expiresAt: Date) {
        let o = try await HTTP.post(tokenURL, json: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                     "client_id": clientId, "scope": refreshScopes.joined(separator: " ")])
        guard let at = o["access_token"] as? String else { throw ProviderError.auth("refresh failed") }
        let exp = Date().addingTimeInterval((o["expires_in"] as? Double) ?? 3600)
        return (at, (o["refresh_token"] as? String) ?? refresh, exp)
    }

    /// `claude setup-token`'s grant: one year.
    static let longLivedSeconds = 365 * 86400

    static func authorizeURL(port: Int, pkce: PKCE, scopes: [String] = Claude.scopes) -> URL {
        var c = URLComponents(string: authorizeURL)!
        c.queryItems = [
            .init(name: "code", value: "true"), .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: "http://localhost:\(port)/callback"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
        ]
        return c.url!
    }

    static func exchange(code: String, port: Int, pkce: PKCE, expiresIn: Int? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["grant_type": "authorization_code", "code": code,
                                   "redirect_uri": "http://localhost:\(port)/callback", "client_id": clientId,
                                   "code_verifier": pkce.verifier, "state": pkce.state]
        if let expiresIn { body["expires_in"] = expiresIn }
        return try await HTTP.post(tokenURL, json: body)
    }
}

// MARK: - Codex

enum Codex {
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let port = 1455

    /// The ChatGPT claims block OpenAI puts in its tokens.
    static func auth(_ token: String?) -> [String: Any] { jwtClaims(token)["https://api.openai.com/auth"] as? [String: Any] ?? [:] }

    static func usage(_ token: String, accountId: String?) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId { r.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await HTTP.json(r)
    }

    static func parse(_ o: [String: Any], now: Date = Date()) -> (windows: [UsageWindow], plan: String?, credits: Int?) {
        var out: [UsageWindow] = []
        func win(_ w: [String: Any]?, _ fallback: UsageWindow.Kind) {
            guard let w, let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return }
            let len = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
            var reset: Date?
            if let at = (w["reset_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: at) }
            else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue { reset = now.addingTimeInterval(after) }
            let kind: UsageWindow.Kind = len.map { $0 <= 6 * 3600 ? .session : .weekly } ?? fallback
            out.append(.init(kind: kind, label: kind == .session ? "Session" : "Week", percent: pct, resetsAt: reset, length: len))
        }
        let rl = o["rate_limit"] as? [String: Any]
        win(rl?["primary_window"] as? [String: Any], .session)
        win(rl?["secondary_window"] as? [String: Any], .weekly)
        let credits = ((o["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? NSNumber)?.intValue
        return (out, o["plan_type"] as? String, credits)
    }

    static func refresh(_ refresh: String) async throws -> (access: String, refresh: String, idToken: String?) {
        let o = try await HTTP.post("\(issuer)/oauth/token", json: ["client_id": clientId, "grant_type": "refresh_token",
                                                                   "refresh_token": refresh, "scope": "openid profile email"])
        guard let at = o["access_token"] as? String else { throw ProviderError.auth("refresh failed") }
        return (at, (o["refresh_token"] as? String) ?? refresh, o["id_token"] as? String)
    }

    static func authorizeURL(pkce: PKCE) -> URL {
        var c = URLComponents(string: "\(issuer)/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: "http://localhost:\(port)/auth/callback"),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: pkce.state), .init(name: "originator", value: "codex_cli_rs"),
        ]
        return c.url!
    }

    static func exchange(code: String, pkce: PKCE) async throws -> [String: Any] {
        try await HTTP.post("\(issuer)/oauth/token", form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientId,
            "redirect_uri": "http://localhost:\(port)/auth/callback", "code_verifier": pkce.verifier])
    }
}

// MARK: - OpenRouter

enum OpenRouter {
    static let base = "https://openrouter.ai/api/v1"

    /// The key: stored on the account, or looked up by name in the environment, then in
    /// ~/.config/secrets/global.env (LaunchAgents don't see shell env).
    static func key(_ a: Account) -> String? {
        if let k = a.accessToken, !k.isEmpty { return k }
        guard let v = a.keyVar else { return nil }
        return env(v)
    }

    static func env(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/secrets/global.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix(name + "=") else { continue }
            var v = String(line.dropFirst(name.count + 1))
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    static func get(_ path: String, _ key: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: base + path)!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return (try await HTTP.json(r))["data"] as? [String: Any] ?? [:]
    }

    /// Balance from /credits (whole account) when the key may read it, else the key's own limit.
    static func balance(_ key: String) async throws -> (Balance, label: String?) {
        let k = try await get("/key", key)
        let credits = try? await get("/credits", key)
        return (parse(key: k, credits: credits), k["label"] as? String)
    }

    static func parse(key k: [String: Any], credits c: [String: Any]?) -> Balance {
        func num(_ o: [String: Any]?, _ f: String) -> Double? { (o?[f] as? NSNumber)?.doubleValue }
        var b = Balance(today: num(k, "usage_daily"), week: num(k, "usage_weekly"))
        if let total = num(c, "total_credits"), let used = num(c, "total_usage") {
            b.total = total
            b.remaining = max(0, total - used)
        }
        if let left = num(k, "limit_remaining") {
            // A key with its own cap: whichever runs out first is what matters.
            if b.remaining == nil || left < b.remaining! { b.remaining = left; b.total = num(k, "limit") }
        }
        return b
    }
}

// MARK: - Fetching one account

enum Fetcher {
    /// Fetches usage. For `.signIn` accounts it may refresh tokens; the updated account is returned
    /// so the caller can persist it. `.tool` accounts read with `borrowed`, a token some holder
    /// keeps fresh; it is never refreshed here.
    static func fetch(_ a: Account, borrowed: Family? = nil, now: Date = Date()) async -> (Usage, Account) {
        var acct = a
        var u = Usage(accountId: a.id, fetchedAt: now)
        do {
            switch (a.provider, a.source) {
            case (.claude, .tool):
                guard let f = borrowed else { throw ProviderError.auth("no tool on this Mac holds it") }
                u.windows = Claude.parse(try await Claude.usage(f.access))
                u.plan = f.rateLimitTier ?? f.subscriptionType
            case (.claude, _):
                try await refreshIfNeeded(&acct, now: now)
                u.windows = Claude.parse(try await Claude.usage(acct.accessToken ?? ""))
                u.plan = acct.plan
            case (.codex, .tool):
                guard let f = borrowed else { throw ProviderError.auth("no tool on this Mac holds it") }
                let r = Codex.parse(try await Codex.usage(f.access, accountId: f.accountId))
                (u.windows, u.plan, u.resetCredits) = (r.windows, r.plan, r.credits)
            case (.codex, _):
                try await refreshIfNeeded(&acct, now: now)
                let r = Codex.parse(try await Codex.usage(acct.accessToken ?? "", accountId: acct.remoteId))
                (u.windows, u.plan, u.resetCredits) = (r.windows, r.plan, r.credits)
            case (.openrouter, _):
                guard let key = OpenRouter.key(a) else { throw ProviderError.auth("no API key") }
                u.balance = try await OpenRouter.balance(key).0
            }
            if let p = u.plan { acct.plan = p }
        } catch let e as ProviderError {
            u.error = e.description
            if case .auth = e { u.needsAuth = true }
        } catch {
            u.error = (error as NSError).localizedDescription
        }
        return (u, acct)
    }

    static func refreshIfNeeded(_ a: inout Account, now: Date) async throws {
        guard a.source == .signIn, let rt = a.refreshToken else {
            if a.accessToken == nil { throw ProviderError.auth("not signed in") }
            return
        }
        let exp: Date? = a.expiresAt ?? (jwtClaims(a.accessToken)["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        guard a.accessToken == nil || exp == nil || exp! < now.addingTimeInterval(300) else { return }
        do {
            switch a.provider {
            case .claude:
                let r = try await Claude.refresh(rt)
                (a.accessToken, a.refreshToken, a.expiresAt) = (r.access, r.refresh, r.expiresAt)
            case .codex:
                let r = try await Codex.refresh(rt)
                (a.accessToken, a.refreshToken) = (r.access, r.refresh)
                a.expiresAt = (jwtClaims(r.access)["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            case .openrouter: break
            }
            log("refreshed \(a.provider.rawValue) \(a.label)")
        } catch {
            throw ProviderError.auth("sign in again (\(error))")
        }
    }
}

enum Shell {
    /// Runs a tool and returns trimmed stdout, or nil on failure.
    static func run(_ path: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:]) -> String? {
        let r = exec(path, args, stdin: stdin, env: env)
        return r.status == 0 ? r.out : nil
    }

    /// Runs a tool; exit status and trimmed stdout / stderr. Status -1: it couldn't start.
    static func exec(_ path: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        let inp = Pipe(); if stdin != nil { p.standardInput = inp }
        do { try p.run() } catch { return (-1, "", "\(path) didn't start") }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        let trim = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, trim(data), trim(errData))
    }
}

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
    static let keychainService = "Claude Code-credentials"

    struct Creds { var access: String; var refresh: String?; var expiresAt: Date?; var plan: String? }

    /// Claude Code's login, read through `security` (it is on the item's ACL, so no prompt).
    static func claudeCodeCreds() -> Creds? {
        guard let raw = Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"]),
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = o["claudeAiOauth"] as? [String: Any], let at = c["accessToken"] as? String else { return nil }
        let exp = (c["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(access: at, refresh: c["refreshToken"] as? String, expiresAt: exp,
                     plan: (c["rateLimitTier"] as? String) ?? (c["subscriptionType"] as? String))
    }

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

    static func authorizeURL(port: Int, pkce: PKCE) -> URL {
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

    static func exchange(code: String, port: Int, pkce: PKCE) async throws -> [String: Any] {
        try await HTTP.post(tokenURL, json: ["grant_type": "authorization_code", "code": code,
                                             "redirect_uri": "http://localhost:\(port)/callback", "client_id": clientId,
                                             "code_verifier": pkce.verifier, "state": pkce.state])
    }
}

// MARK: - Codex

enum Codex {
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let port = 1455

    struct Creds { var access: String; var refresh: String?; var accountId: String?; var idToken: String? }

    static func home(_ path: String?) -> URL {
        if let path, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func cliCreds(_ path: String?) -> Creds? {
        let url = home(path).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = o["tokens"] as? [String: Any], let at = t["access_token"] as? String else { return nil }
        return Creds(access: at, refresh: t["refresh_token"] as? String, accountId: t["account_id"] as? String,
                     idToken: t["id_token"] as? String)
    }

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

// MARK: - Fetching one account

enum Fetcher {
    /// Fetches usage. For `.signIn` accounts it may refresh tokens; the updated account is returned
    /// so the caller can persist it.
    static func fetch(_ a: Account, now: Date = Date()) async -> (Usage, Account) {
        var acct = a
        var u = Usage(accountId: a.id, fetchedAt: now)
        do {
            switch (a.provider, a.source) {
            case (.claude, .claudeCode):
                guard let c = Claude.claudeCodeCreds() else { throw ProviderError.auth("Claude Code is signed out") }
                if let e = c.expiresAt, e < now { throw ProviderError.auth("token expired, open Claude Code once") }
                u.windows = Claude.parse(try await Claude.usage(c.access))
                u.plan = c.plan
            case (.claude, _):
                try await refreshIfNeeded(&acct, now: now)
                u.windows = Claude.parse(try await Claude.usage(acct.accessToken ?? ""))
                u.plan = acct.plan
            case (.codex, .codexCLI):
                guard let c = Codex.cliCreds(a.path) else { throw ProviderError.auth("Codex is signed out") }
                let r = Codex.parse(try await Codex.usage(c.access, accountId: c.accountId))
                (u.windows, u.plan, u.resetCredits) = (r.windows, r.plan, r.credits)
            case (.codex, _):
                try await refreshIfNeeded(&acct, now: now)
                let r = Codex.parse(try await Codex.usage(acct.accessToken ?? "", accountId: acct.remoteId))
                (u.windows, u.plan, u.resetCredits) = (r.windows, r.plan, r.credits)
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        let inp = Pipe(); if stdin != nil { p.standardInput = inp }
        do { try p.run() } catch { return nil }
        if let stdin { inp.fileHandleForWriting.write(stdin.data(using: .utf8)!); try? inp.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

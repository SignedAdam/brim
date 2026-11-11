import Foundation
import CryptoKit
import AppKit

struct PKCE {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        func rand(_ n: Int) -> String {
            var b = [UInt8](repeating: 0, count: n)
            _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
            return Data(b).base64url
        }
        verifier = rand(32)
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64url
        state = rand(32)
    }
}

extension Data {
    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class Loopback {
    let port: Int
    private var fd: Int32 = -1

    init(port: Int = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProviderError.other("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw ProviderError.other("port \(port) is busy (is another sign-in open?)")
        }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        self.fd = fd
    }

    deinit { if fd >= 0 { close(fd) } }

    final class Callback {
        let query: [String: String]
        private var c: Int32

        init(_ c: Int32, _ query: [String: String]) { self.c = c; self.query = query }
        deinit { reply(query["code"] != nil ? "Signed in. You can close this tab." : "Sign-in was cancelled.") }

        func reply(_ text: String, next: URL? = nil) {
            guard c >= 0 else { return }
            let go = next.map { "<meta http-equiv=refresh content=\"1;url=\(Loopback.escape($0.absoluteString))\">" } ?? ""
            Loopback.reply(c, 200, text, head: go)
            close(c)
            c = -1
        }
    }

    func wait(path: String, timeout: TimeInterval = 300) async throws -> Callback {
        let fd = self.fd
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&pfd, 1, 1000) > 0 else { continue }
                    let c = accept(fd, nil, nil)
                    guard c >= 0 else { continue }
                    var buf = [UInt8](repeating: 0, count: 8192)
                    let n = read(c, &buf, buf.count)
                    let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                    let target = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let comps = URLComponents(string: "http://x\(target)")
                    guard comps?.path == path else {
                        Loopback.reply(c, 404, "Not here."); close(c); continue
                    }
                    var q: [String: String] = [:]
                    comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
                    cont.resume(returning: Callback(c, q))
                    return
                }
                cont.resume(throwing: ProviderError.other("sign-in timed out"))
            }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func reply(_ c: Int32, _ code: Int, _ text: String, head: String = "") {
        let html = """
        <!doctype html><meta charset=utf-8><title>Brim</title>\(head)
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#000;color:#eee;
        font:500 15px -apple-system,system-ui">\(escape(text))</body>
        """
        let resp = "HTTP/1.1 \(code) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = resp.withCString { write(c, $0, strlen($0)) }
    }
}

enum SignIn {
    static func openRouter(key: String, keyVar: String?, label: String?) async throws -> Account {
        let (_, keyLabel) = try await OpenRouter.balance(key)
        let fingerprint = Data(SHA256.hash(data: Data(key.utf8))).base64url.prefix(12)
        return Account(id: UUID().uuidString, provider: .openrouter, source: .apiKey, label: label ?? "OpenRouter",
                       email: keyLabel, remoteId: String(fingerprint), keyVar: keyVar,
                       accessToken: keyVar == nil ? key : nil)
    }

    static func run(_ provider: Provider, label: String?, open: Bool = true) async throws -> Account {
        guard provider != .openrouter else { throw ProviderError.other("OpenRouter uses an API key") }
        let f: Family
        if provider == .codex {
            let logins = try await codex(open: open) { f in f.key.map { Switcher.wanted($0, except: nil, own: 1) } ?? 0 }
            f = logins[0]
            if let key = f.key, logins.count > 1 {
                try await Vault.locked { v in
                    Switcher.park(Array(logins.dropFirst()), key, in: &v, except: nil)
                    try v.save()
                }
            }
        } else {
            f = try await family(provider, open: open)
        }
        var a = Account(id: UUID().uuidString, provider: provider, source: .signIn, label: label ?? provider.name,
                        email: f.email, plan: f.subscriptionType, remoteId: f.accountId,
                        accessToken: f.access, refreshToken: f.refresh, expiresAt: f.expiresAt)
        if provider == .claude, let p = try? await Claude.profile(f.access) {
            a.remoteId = a.remoteId ?? p.id; a.email = a.email ?? p.email; a.plan = p.plan
        }
        if label == nil, let e = a.email { a.label = defaultLabel(e) }
        return a
    }

    static func present(_ url: URL, open: Bool) {
        if open { NSWorkspace.shared.open(url); return }
        print(url.absoluteString)
        fflush(stdout)
    }

    static func family(_ provider: Provider, longLived: Bool = false, open: Bool = true) async throws -> Family {
        let pkce = PKCE()
        switch provider {
        case .openrouter:
            throw ProviderError.other("OpenRouter uses an API key")
        case .claude:
            let lb = try Loopback()
            present(Claude.authorizeURL(port: lb.port, pkce: pkce, scopes: longLived ? ["user:inference"] : Claude.scopes), open: open)
            let q = try await lb.wait(path: "/callback").query
            guard let code = q["code"], q["state"] == pkce.state else { throw ProviderError.other("sign-in cancelled") }
            let t = try await Claude.exchange(code: code, port: lb.port, pkce: pkce, expiresIn: longLived ? Claude.longLivedSeconds : nil)
            guard let at = t["access_token"] as? String else { throw ProviderError.other("no token") }
            let acct = t["account"] as? [String: Any]
            let org = t["organization"] as? [String: Any]
            return Family(provider: .claude, access: at, refresh: t["refresh_token"] as? String,
                          expiresAt: Date().addingTimeInterval((t["expires_in"] as? Double) ?? 3600),
                          accountId: acct?["uuid"] as? String, email: acct?["email_address"] as? String,
                          orgId: org?["uuid"] as? String, orgName: org?["name"] as? String,
                          scopes: (t["scope"] as? String)?.split(separator: " ").map(String.init))
        case .codex:
            return try await codex(open: open) { _ in 0 }[0]
        }
    }

    static func codex(open: Bool, extra: (Family) -> Int) async throws -> [Family] {
        let lb = try Loopback(port: Codex.port)
        var pkce = PKCE()
        present(Codex.authorizeURL(pkce: pkce), open: open)
        var logins: [Family] = []
        var total = 1
        while true {
            let cb: Loopback.Callback
            do { cb = try await lb.wait(path: "/auth/callback", timeout: logins.isEmpty ? 300 : 180) } catch {
                if logins.isEmpty { throw error }
                break
            }
            guard let code = cb.query["code"], cb.query["state"] == pkce.state else {
                if logins.isEmpty { throw ProviderError.other("sign-in cancelled") }
                cb.reply("Brim kept \(logins.count) of \(total) logins and skipped the rest. You can close this tab.")
                break
            }
            let f: Family
            do {
                let t = try await Codex.exchange(code: code, pkce: pkce)
                guard let at = t["access_token"] as? String else { throw ProviderError.other("no token") }
                f = Family.codex(access: at, refresh: t["refresh_token"] as? String, idToken: t["id_token"] as? String)
            } catch {
                if logins.isEmpty { throw error }
                cb.reply("Brim kept \(logins.count) of \(total) logins; the next one failed (\(error)). You can close this tab.")
                break
            }
            if let first = logins.first, f.key != first.key {
                cb.reply("That was \(f.email ?? "another account"), not \(first.email ?? "the first account"). Brim kept \(logins.count) of \(total) logins. You can close this tab.")
                break
            }
            logins.append(f)
            if logins.count == 1 { total = 1 + extra(f) }
            guard logins.count < total else {
                cb.reply(total == 1 ? "Signed in. You can close this tab."
                         : "Signed in. Brim saved \(total) logins for \(f.email ?? "this account"), one for each app. You can close this tab.")
                break
            }
            pkce = PKCE()
            cb.reply("Login \(logins.count) of \(total) saved. Next: login \(logins.count + 1), for another app. OpenAI may ask you to sign in again.",
                     next: Codex.authorizeURL(pkce: pkce, hint: logins[0].email))
        }
        return logins
    }

    static func defaultLabel(_ email: String) -> String {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return email }
        let domain = parts[1].split(separator: ".").first.map(String.init) ?? ""
        let common = ["gmail", "icloud", "me", "outlook", "hotmail", "proton", "protonmail", "yahoo", "fastmail", "hey"]
        let word = common.contains(domain.lowercased()) ? String(parts[0]) : domain
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}

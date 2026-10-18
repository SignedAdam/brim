import Foundation
import CryptoKit
import AppKit

// Browser sign-in: PKCE plus a one-shot loopback HTTP listener.

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

/// Accepts exactly one GET on 127.0.0.1:port and hands back its query items.
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

    /// Waits (off the main thread) for a request whose path matches; replies with a small page.
    func wait(path: String, timeout: TimeInterval = 300) async throws -> [String: String] {
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
                    let ok = q["code"] != nil
                    Loopback.reply(c, 200, ok ? "Signed in. You can close this tab." : "Sign-in was cancelled.")
                    close(c)
                    cont.resume(returning: q)
                    return
                }
                cont.resume(throwing: ProviderError.other("sign-in timed out"))
            }
        }
    }

    private static func reply(_ c: Int32, _ code: Int, _ text: String) {
        let html = """
        <!doctype html><meta charset=utf-8><title>Brim</title>
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#000;color:#eee;
        font:500 15px -apple-system,system-ui">\(text)</body>
        """
        let resp = "HTTP/1.1 \(code) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = resp.withCString { write(c, $0, strlen($0)) }
    }
}

enum SignIn {
    /// Opens the browser, waits for the callback, exchanges the code, and returns a new account.
    static func run(_ provider: Provider, label: String?) async throws -> Account {
        let pkce = PKCE()
        switch provider {
        case .claude:
            let lb = try Loopback()
            NSWorkspace.shared.open(Claude.authorizeURL(port: lb.port, pkce: pkce))
            let q = try await lb.wait(path: "/callback")
            guard let code = q["code"], q["state"] == pkce.state else { throw ProviderError.other("sign-in cancelled") }
            let t = try await Claude.exchange(code: code, port: lb.port, pkce: pkce)
            guard let at = t["access_token"] as? String else { throw ProviderError.other("no token") }
            let acct = t["account"] as? [String: Any]
            var a = Account(id: UUID().uuidString, provider: .claude, source: .signIn, label: label ?? "Claude",
                            email: acct?["email_address"] as? String, remoteId: acct?["uuid"] as? String,
                            accessToken: at, refreshToken: t["refresh_token"] as? String,
                            expiresAt: Date().addingTimeInterval((t["expires_in"] as? Double) ?? 3600))
            if let p = try? await Claude.profile(at) {
                a.remoteId = a.remoteId ?? p.id; a.email = a.email ?? p.email; a.plan = p.plan
            }
            if label == nil, let e = a.email { a.label = defaultLabel(e) }
            return a
        case .codex:
            let lb = try Loopback(port: Codex.port)
            NSWorkspace.shared.open(Codex.authorizeURL(pkce: pkce))
            let q = try await lb.wait(path: "/auth/callback")
            guard let code = q["code"], q["state"] == pkce.state else { throw ProviderError.other("sign-in cancelled") }
            let t = try await Codex.exchange(code: code, pkce: pkce)
            guard let at = t["access_token"] as? String else { throw ProviderError.other("no token") }
            let idt = t["id_token"] as? String
            let auth = Codex.auth(idt).isEmpty ? Codex.auth(at) : Codex.auth(idt)
            let email = jwtClaims(idt)["email"] as? String
            return Account(id: UUID().uuidString, provider: .codex, source: .signIn,
                           label: label ?? email.map(defaultLabel) ?? "Codex", email: email,
                           plan: auth["chatgpt_plan_type"] as? String, remoteId: auth["chatgpt_account_id"] as? String,
                           accessToken: at, refreshToken: t["refresh_token"] as? String,
                           expiresAt: (jwtClaims(at)["exp"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// "adam@work.com" → "Work", "someone@gmail.com" → "Someone".
    static func defaultLabel(_ email: String) -> String {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return email }
        let domain = parts[1].split(separator: ".").first.map(String.init) ?? ""
        let common = ["gmail", "icloud", "me", "outlook", "hotmail", "proton", "protonmail", "yahoo", "fastmail", "hey"]
        let word = common.contains(domain.lowercased()) ? String(parts[0]) : domain
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}

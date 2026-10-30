import Foundation
import CryptoKit

// Account switching, part 1: what a login is and where Brim parks it.
//
// A login ("token family": one sign-in's access + refresh tokens) always has exactly one holder.
// Claude and Codex refresh tokens rotate, so a copy two holders share dies the moment either one
// refreshes. A family is either parked in Brim's vault (Brim keeps it fresh) or installed in
// exactly one tool (the tool owns it; Brim never refreshes or reuses it there).

enum Tool: String, Codable, CaseIterable {
    case claudeCode = "claude-code", codex, hermes, omp

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .hermes: return "Hermes"
        case .omp: return "OMP"
        }
    }

    var providers: [Provider] {
        switch self {
        case .claudeCode: return [.claude]
        case .codex: return [.codex]
        case .hermes, .omp: return [.claude, .codex]
        }
    }

    /// Whether the tool is set up on this Mac at all.
    var installed: Bool {
        let fm = FileManager.default
        switch self {
        case .claudeCode: return fm.fileExists(atPath: Paths.claudeJSON.path) || ClaudeCode.payload() != nil
        case .codex: return fm.fileExists(atPath: Paths.codexHome.path)
        case .hermes: return fm.fileExists(atPath: Paths.hermesRoot.path)
        case .omp: return fm.fileExists(atPath: Paths.ompDB.path)
        }
    }

    /// When a running copy of the tool notices a switch, if it's not on its next request.
    var pickup: String? { self == .codex ? "new Codex sessions use it" : nil }
}

/// One sign-in's tokens, and whose they are.
struct Family: Codable, Equatable {
    var provider: Provider
    var access: String
    var refresh: String?
    var expiresAt: Date?
    /// When the grant itself ends (Claude grants die about 30 days after sign-in, refreshed or not).
    var refreshExpiresAt: Date?
    var idToken: String?
    /// Claude account uuid, ChatGPT account id.
    var accountId: String?
    var email: String?
    var orgId: String?
    var orgName: String?
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?

    var key: String? { accountId.map { "\(provider.rawValue):\($0)" } }
    /// Names the family without revealing it.
    var fingerprint: String { Secret.fingerprint(refresh ?? access) }
    func expired(_ now: Date) -> Bool { (expiresAt ?? .distantFuture) <= now }
    /// Past saving: the grant ended, or a token without a refresh token expired.
    func gone(_ now: Date) -> Bool {
        if let r = refreshExpiresAt, r <= now { return true }
        return refresh == nil && expired(now)
    }

    /// A ChatGPT family; account and email come from the tokens' own claims.
    static func codex(access: String, refresh: String?, idToken: String?, accountId: String? = nil) -> Family {
        let auth = Codex.auth(idToken).isEmpty ? Codex.auth(access) : Codex.auth(idToken)
        let profile = jwtClaims(access)["https://api.openai.com/profile"] as? [String: Any]
        return Family(provider: .codex, access: access, refresh: refresh,
                      expiresAt: (jwtClaims(access)["exp"] as? Double).map { Date(timeIntervalSince1970: $0) },
                      idToken: idToken, accountId: accountId ?? auth["chatgpt_account_id"] as? String,
                      email: (jwtClaims(idToken)["email"] as? String) ?? profile?["email"] as? String,
                      subscriptionType: auth["chatgpt_plan_type"] as? String)
    }
}

/// A family parked in the vault: the login `account` uses in `tool`, while the tool holds another.
struct Slot: Codable, Equatable {
    var account: String
    var tool: Tool
    /// The Hermes home, for families that live in one home's auth.json (Codex). Nil elsewhere.
    var home: String?
    var family: Family
    var parkedAt: Date
    /// Last time Brim refreshed it while parked.
    var refreshedAt: Date?
    /// Set when keeping it fresh failed for good; the next switch signs in again instead.
    var error: String?
}

struct Minted: Codable, Equatable {
    var account: String
    var expiresAt: Date?
}

/// `~/.brim/vault.json`, owner-only. Not the Keychain: Brim is rebuilt and re-signed often, and
/// Keychain ACLs tied to the signature would ask for a password after every build.
struct Vault: Codable, Equatable {
    var slots: [Slot] = []
    /// Hermes long-lived tokens Brim minted, by fingerprint, so one sitting in a `.env` is known.
    var minted: [String: Minted] = [:]

    /// The vault on disk. A file that exists but can't be read is an error, never an empty vault.
    static func read() throws -> Vault {
        guard let data = try? Data(contentsOf: Paths.vault) else { return Vault() }
        return try JSON.decoder.decode(Vault.self, from: data)
    }

    static func load() -> Vault { (try? read()) ?? Vault() }

    func save() throws { try JSON.write(self, Paths.vault) }

    func index(_ account: String, _ tool: Tool, _ home: String?) -> Int? {
        slots.firstIndex { $0.account == account && $0.tool == tool && $0.home == home }
    }

    func slot(_ account: String, _ tool: Tool, _ home: String?) -> Slot? { index(account, tool, home).map { slots[$0] } }

    mutating func put(_ s: Slot) {
        if let i = index(s.account, s.tool, s.home) { slots[i] = s } else { slots.append(s) }
    }

    mutating func take(_ account: String, _ tool: Tool, _ home: String?) -> Slot? {
        index(account, tool, home).map { slots.remove(at: $0) }
    }

    /// Runs `body` on a freshly read vault while holding the vault lock, which the app and the CLI
    /// share, so a switch and a keep-fresh refresh never work on the same family at once.
    static func locked<T>(_ body: (inout Vault) async throws -> T) async throws -> T {
        Paths.ensure()
        let lock = try FileLock(Paths.vaultLock, timeout: 120)
        defer { lock.release() }
        var v = try read()
        return try await body(&v)
    }
}

enum Secret {
    static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// An exclusive `flock`, the kind Hermes takes on `auth.lock`. Retries until `timeout`.
final class FileLock {
    private var fd: Int32

    init(_ url: URL, timeout: TimeInterval) throws {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ProviderError.other("can't open \(url.path)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd); fd = -1
                throw ProviderError.other("\(url.path) is locked by another process")
            }
            usleep(50_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    deinit { release() }
}

enum Files {
    /// Replaces a file in one step (temp file + rename), keeping its mode; follows a symlink.
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).brim-\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw ProviderError.other("can't write \(target.path)")
        }
        guard rename(tmp.path, target.path) == 0 else {
            unlink(tmp.path)
            throw ProviderError.other("can't replace \(target.path)")
        }
    }

    static func json(_ o: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Copies of a tool's store taken before every write: `~/.brim/backups/<name>-<time>`, owner-only,
/// the newest 20 of each kept.
enum Backup {
    static func save(_ name: String, _ data: Data) throws {
        let dir = Paths.backups
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("\(name)-\(f.string(from: Date()))")
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ProviderError.other("can't back up \(name) to \(dir.path)")
        }
        let mine = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("\(name)-2") }.sorted()
        for old in mine.dropLast(20) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }
}

enum Stamp {
    /// "2026-10-30T09:07:37.123456Z", the shape Codex and Hermes write.
    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return f.string(from: d)
    }

    static func ms(_ d: Date?) -> Int64 { Int64(((d ?? Date()).timeIntervalSince1970 * 1000).rounded()) }
}

import Foundation

// Pure data: accounts, usage, persistence, formatting. No UI imports, so the
// selftest can exercise all of it.

let VERSION = "0.1.0"

enum Provider: String, Codable, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
}

/// Where an account's credentials come from.
enum Source: String, Codable {
    /// Claude Code's own login on this Mac (Keychain "Claude Code-credentials"). Read-only:
    /// Claude Code refreshes it, we never do, so the two never fight over a rotating token.
    case claudeCode
    /// Codex CLI's login (`$CODEX_HOME/auth.json`). Read-only for the same reason.
    case codexCLI
    /// Brim's own sign-in. Brim owns and refreshes these tokens.
    case signIn
}

struct Account: Codable, Identifiable, Equatable {
    var id: String
    var provider: Provider
    var source: Source
    var label: String
    var email: String?
    var plan: String?
    /// Provider-side account id, used to spot the same account added twice.
    var remoteId: String?
    /// For `.codexCLI`: the CODEX_HOME directory. Nil = ~/.codex.
    var path: String?
    var hidden: Bool?

    // Tokens, only for `.signIn`.
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?

    var isHidden: Bool { hidden ?? false }
}

/// One rate-limit window: "5h session", "week", a per-model weekly cap.
struct UsageWindow: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case session, weekly, model }
    var kind: Kind
    var label: String
    /// 0...100
    var percent: Double
    var resetsAt: Date?
    var length: TimeInterval?

    var id: String { kind.rawValue + label }

    /// How far through the window we are, 0...1. Nil when the window has no known length.
    func elapsed(at now: Date) -> Double? {
        guard let resetsAt, let length, length > 0 else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / length))
    }

    /// Projected use at reset if the current pace holds. >100 means you'll run out early.
    func projected(at now: Date) -> Double? {
        guard let e = elapsed(at: now), e > 0.05 else { return nil }
        return percent / e
    }

    /// When the window runs dry at the current pace, if before the reset.
    func runsOut(at now: Date) -> Date? {
        guard let resetsAt, let length, let e = elapsed(at: now), e > 0.05, percent > 0, percent < 100 else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let rate = percent / now.timeIntervalSince(start)            // percent per second
        let t = now.addingTimeInterval((100 - percent) / rate)
        return t < resetsAt ? t : nil
    }
}

struct Usage: Codable, Equatable {
    var accountId: String
    var fetchedAt: Date
    var windows: [UsageWindow] = []
    var plan: String?
    /// Codex: banked "reset my limits" credits.
    var resetCredits: Int?
    var error: String?
    /// True when the credentials are gone or expired and the user must act.
    var needsAuth: Bool?

    var session: UsageWindow? { windows.first { $0.kind == .session } }
    var weekly: UsageWindow? { windows.first { $0.kind == .weekly } }
    /// The tightest window right now.
    var peak: Double { windows.map(\.percent).max() ?? 0 }
}

// MARK: - Settings

struct Settings: Codable, Equatable {
    var refreshSeconds: Double = 180
    /// Alert when any window crosses these percents.
    var thresholds: [Double] = [80, 95]
    /// "Use it or lose it": alert when a weekly window resets within this many hours
    /// with at least `leftoverPercent` unused.
    var leftoverLeadHours: Double = 12
    var leftoverPercent: Double = 30
    /// Alert when a window resets (usage drops back) — handy to restart paused work.
    var alertOnReset: Bool = true
    /// Shell commands run for every alert, with the alert as JSON on stdin and in $BRIM_ALERT.
    var hooks: [String] = []
    /// Raise a Pager panel for alerts (if `pager` is installed).
    var pager: Bool = true
    /// Which display gets the notch: "auto" = the built-in one with a notch, else main.
    var display: String = "auto"
    /// Watch resets.albastov.com for announced resets (OpenAI / Anthropic posting "limits reset").
    var announcements: Bool = true

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = Settings()
        refreshSeconds = max(60, (try? c.decode(Double.self, forKey: .refreshSeconds)) ?? z.refreshSeconds)
        thresholds = ((try? c.decode([Double].self, forKey: .thresholds)) ?? z.thresholds).filter { $0 > 0 && $0 <= 100 }.sorted()
        leftoverLeadHours = (try? c.decode(Double.self, forKey: .leftoverLeadHours)) ?? z.leftoverLeadHours
        leftoverPercent = (try? c.decode(Double.self, forKey: .leftoverPercent)) ?? z.leftoverPercent
        alertOnReset = (try? c.decode(Bool.self, forKey: .alertOnReset)) ?? z.alertOnReset
        hooks = (try? c.decode([String].self, forKey: .hooks)) ?? z.hooks
        pager = (try? c.decode(Bool.self, forKey: .pager)) ?? z.pager
        display = (try? c.decode(String.self, forKey: .display)) ?? z.display
        announcements = (try? c.decode(Bool.self, forKey: .announcements)) ?? z.announcements
    }
}

// MARK: - Alerts

struct Alert: Codable, Equatable {
    enum Kind: String, Codable { case threshold, leftover, reset, credits, auth, announced }
    var kind: Kind
    var accountId: String
    var account: String
    var provider: Provider
    var window: String?
    var percent: Double?
    var resetsAt: Date?
    var title: String
    /// Dedupe key: the same alert never fires twice for the same window cycle.
    var key: String
    var at: Date
}

enum Alerts {
    /// Compares the previous and current usage of one account and returns what's worth saying.
    static func evaluate(account a: Account, old: Usage?, new: Usage, settings s: Settings,
                         fired: Set<String>, now: Date) -> [Alert] {
        var out: [Alert] = []
        func add(_ kind: Alert.Kind, _ w: UsageWindow?, _ title: String, _ key: String) {
            guard !fired.contains(key) else { return }
            out.append(Alert(kind: kind, accountId: a.id, account: a.label, provider: a.provider,
                             window: w?.label, percent: w?.percent, resetsAt: w?.resetsAt,
                             title: title, key: key, at: now))
        }
        if new.needsAuth == true, old?.needsAuth != true {
            add(.auth, nil, "\(a.label): sign in again", "auth:\(a.id):\(Int(now.timeIntervalSince1970 / 86400))")
        }
        for w in new.windows {
            let cycle = w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 600)) } ?? "-"
            // Threshold crossings: only the highest one crossed, once per cycle.
            if let t = s.thresholds.last(where: { w.percent >= $0 }) {
                add(.threshold, w, "\(a.label) \(w.label) at \(Int(w.percent))%", "thr:\(a.id):\(w.id):\(Int(t)):\(cycle)")
            }
            // Use-it-or-lose-it on weekly windows.
            if w.kind == .weekly, let r = w.resetsAt {
                let left = r.timeIntervalSince(now)
                if left > 0, left < s.leftoverLeadHours * 3600, 100 - w.percent >= s.leftoverPercent {
                    add(.leftover, w, "\(a.label): \(Int(100 - w.percent))% of the week left, resets in \(Fmt.duration(left))",
                        "left:\(a.id):\(w.id):\(cycle)")
                }
            }
            // Resets: the window moved on and usage fell.
            if s.alertOnReset, let o = old?.windows.first(where: { $0.id == w.id }),
               let or = o.resetsAt, or <= now.addingTimeInterval(60), o.percent >= 1, w.percent < o.percent {
                add(.reset, w, "\(a.label) \(w.label) reset", "reset:\(a.id):\(w.id):\(Int(or.timeIntervalSince1970 / 600))")
            }
        }
        if let c = new.resetCredits, c > (old?.resetCredits ?? c) {
            add(.credits, nil, "\(a.label): a new limit reset is available (\(c) banked)", "cred:\(a.id):\(c)")
        }
        return out
    }
}

// MARK: - Formatting

enum Fmt {
    /// "7m", "2h14", "3d 4h"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "now" }
        let m = s / 60, h = m / 60, d = h / 24
        if h == 0 { return "\(m)m" }
        if d == 0 { return m % 60 == 0 ? "\(h)h" : String(format: "%dh%02d", h, m % 60) }
        return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h"
    }

    /// Short reset label: always a countdown ("37m", "2h14", "3d 4h").
    static func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        return duration(date.timeIntervalSince(now))
    }

    /// "Mon 06:52", for tooltips.
    static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM HH:mm"
        return f.string(from: date)
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let r = raw.lowercased()
        if r.contains("max_20x") || r.contains("max20") { return "Max 20×" }
        if r.contains("max_5x") || r.contains("max5") { return "Max 5×" }
        if r == "max" { return "Max" }
        if r.contains("enterprise") { return "Enterprise" }
        if r.contains("team") { return "Team" }
        if r.contains("pro") { return "Pro" }
        if r.contains("plus") { return "Plus" }
        if r.contains("business") { return "Business" }
        if r.contains("edu") { return "Edu" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

// MARK: - Persistence

enum Paths {
    static var home: URL {
        if let p = ProcessInfo.processInfo.environment["BRIM_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".brim")
    }
    static var accounts: URL { home.appendingPathComponent("accounts.json") }
    static var usage: URL { home.appendingPathComponent("usage.json") }
    static var settings: URL { home.appendingPathComponent("settings.json") }
    static var alerts: URL { home.appendingPathComponent("alerts.jsonl") }
    static var fired: URL { home.appendingPathComponent("fired.json") }
    static var socket: URL { home.appendingPathComponent("brim.sock") }
    static var lock: URL { home.appendingPathComponent("brim.lock") }
    static var log: URL { home.appendingPathComponent("brim.log") }

    static func ensure() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            let s = try c.decode(String.self)
            if let d = parseDate(s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Microsecond fractions ("…00.163298+00:00") trip ISO8601DateFormatter: trim to millis.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = String(s[r].prefix(4))
            return parseDate(s.replacingCharacters(in: r, with: frac))
        }
        return nil
    }

    static func load<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(t, from: data)
    }

    /// Atomic write, owner-only (accounts.json holds tokens).
    static func save<T: Encodable>(_ v: T, _ url: URL) {
        Paths.ensure()
        guard let data = try? encoder.encode(v) else { return }
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

func log(_ s: String) {
    Paths.ensure()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        FileManager.default.createFile(atPath: Paths.log.path, contents: line.data(using: .utf8))
    }
}

/// A reset announced in public (from resets.albastov.com).
struct Announcement: Codable, Equatable, Identifiable {
    var id: String
    var provider: Provider
    var summary: String
    var product: String?
    var url: String?
    var at: Date

    /// One short line: "Codex limits reset".
    var short: String { "\(product ?? (provider == .claude ? "Claude" : "Codex")) limits reset" }

    static func parse(_ o: [String: Any]) -> [Announcement] {
        ((o["resets"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["id"] as? String, let s = r["summary"] as? String,
                  let at = ((r["posted_at"] as? String) ?? (r["detected_at"] as? String)).flatMap(JSON.parseDate) else { return nil }
            let p: Provider = (r["provider"] as? String) == "anthropic" ? .claude : .codex
            let product = (r["product"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Announcement(id: id, provider: p, summary: s, product: product, url: r["source_url"] as? String, at: at)
        }
    }
}

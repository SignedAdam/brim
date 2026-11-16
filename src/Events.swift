import Foundation

struct Event: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case app, switched = "switch", signIn = "sign_in", account, refresh, fetch, vault, reset, alert
    }
    var at: Date
    var kind: Kind
    var text: String
    var error: String?
    var account: String?
    var label: String?
    var tool: Tool?
    var from: String?
    var via: String
}

enum Events {
    static var via = "cli"
    static let keepBytes = 1 << 20

    static func record(_ kind: Event.Kind, _ text: String, error: String? = nil, account a: Account? = nil,
                       tool: Tool? = nil, from: String? = nil) {
        let e = Event(at: Date(), kind: kind, text: text, error: error, account: a?.id, label: a?.label,
                      tool: tool, from: from, via: via)
        guard let line = try? JSONEncoder.compact.encode(e) else { return }
        Paths.ensure()
        let fd = open(Paths.events.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let out = line + Data("\n".utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    static func record(_ kind: Event.Kind, _ text: String, failure: Error, account a: Account? = nil, tool: Tool? = nil) {
        record(kind, text, error: (failure as? ProviderError)?.description ?? "\(failure)", account: a, tool: tool)
    }

    static func trim() {
        guard let data = try? Data(contentsOf: Paths.events), data.count > 2 * keepBytes else { return }
        let tail = data.suffix(keepBytes)
        guard let nl = tail.firstIndex(of: 0x0a) else { return }
        let tmp = Paths.events.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(tail[(nl + 1)...]), attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(Paths.events, withItemAt: tmp)
    }

    static func parse(_ data: Data) -> [Event] {
        data.split(separator: 0x0a).compactMap { try? JSON.decoder.decode(Event.self, from: Data($0)) }
    }
}

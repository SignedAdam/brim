import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let cmd = args.first ?? "run"
        if !args.isEmpty { args.removeFirst() }
        switch cmd {
        case "run": App.run()
        case "status": CLI.status(args)
        case "list": CLI.list()
        case "where": CLI.whereNow(args)
        case "switch": CLI.switchTool(args)
        case "add": CLI.add(args)
        case "rename": CLI.rename(args)
        case "remove", "rm": CLI.remove(args)
        case "alerts": CLI.alerts(args)
        case "snapshot": Snapshot.run(args)
        case "selftest": exit(Selftest.run() ? 0 : 1)
        case "install": Agent.install()
        case "uninstall": Agent.uninstall()
        case "quit": CLI.signal(SIGTERM, "quit")
        case "--version", "-v", "version": print("brim \(VERSION)")
        case "--help", "-h", "help": CLI.help()
        default:
            FileHandle.standardError.write("brim: unknown command \(cmd)\n".data(using: .utf8)!)
            CLI.help(); exit(2)
        }
    }
}

// MARK: - App

@MainActor
final class App: NSObject, NSApplicationDelegate {
    static var shared: App!
    let store = Store()
    var notch: NotchController!
    var settingsWindow: NSWindow?
    private var signals: [DispatchSourceSignal] = []

    static func run() {
        Paths.ensure()
        guard Lock.acquire() else {
            print("brim is already running (pid \(Lock.holder() ?? "?"))")
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let d = App()
            shared = d
            app.delegate = d
            withExtendedLifetime(d) { app.run() }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        log("start \(VERSION)")
        notch = NotchController(store: store)
        notch.onSettings = { [weak self] in self?.openSettings() }
        notch.onAdd = { [weak self] p in self?.signIn(p) }
        store.start()
        notch.show()
        for (sig, f) in [(SIGTERM, { NSApp.terminate(nil) }), (SIGINT, { NSApp.terminate(nil) }),
                         (SIGHUP, { [weak self] in self?.reload() }),
                         (SIGUSR1, { [weak self] in Task { await self?.store.refresh() } })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { f() } }
            s.resume()
            signals.append(s)
        }
    }

    /// `brim add/rename/remove/switch` edit the files and send SIGHUP.
    func reload() {
        store.accounts = JSON.load([Account].self, Paths.accounts).map(Accounts.migrate) ?? store.accounts
        store.settings = JSON.load(Settings.self, Paths.settings) ?? store.settings
        store.schedule()
        notch.place()
        Task { await store.refresh() }
        log("reloaded")
    }

    func signIn(_ p: Provider) {
        if p == .openrouter { return addKey() }
        store.show(Flash(text: "Finish signing in to \(p.name) in your browser", provider: p), seconds: 30)
        Task {
            do {
                let a = try await SignIn.run(p, label: nil)
                try store.add(a)
                store.show(Flash(text: "Added \(a.label)\(a.email.map { " · \($0)" } ?? "")", provider: p, tone: .accent))
            } catch {
                store.show(Flash(text: "\(p.name) sign-in: \(error)", provider: p, tone: .warn), seconds: 8)
            }
        }
    }

    /// Asks for an OpenRouter key in a small native sheet, checks it, then adds it.
    func addKey() {
        let alert = NSAlert()
        alert.messageText = "Add OpenRouter Key"
        alert.informativeText = "openrouter.ai/settings/keys"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "sk-or-v1-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.window.collectionBehavior = [.moveToActiveSpace]
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            do {
                let a = try await SignIn.openRouter(key: key, keyVar: nil, label: nil)
                try store.add(a)
                store.show(Flash(text: "Added \(a.label)", provider: .openrouter, tone: .accent))
            } catch {
                store.show(Flash(text: "OpenRouter key: \(error)", provider: .openrouter, tone: .warn), seconds: 8)
            }
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store, onAdd: { [weak self] p in self?.signIn(p) },
                                                                  onDisplay: { [weak self] in self?.notch.place() }))
            let w = NSWindow(contentViewController: host)
            w.title = "Brim Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Open on the Space you're on, never pull you to the one it was last shown on.
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ n: Notification) {
        store.save()
        log("stop")
    }
}

// MARK: - Single instance

enum Lock {
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    static func holder() -> String? {
        (try? String(contentsOf: Paths.lock, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pid of a running brim, if any.
    static func running() -> pid_t? {
        let f = open(Paths.lock.path, O_RDONLY)
        guard f >= 0 else { return nil }
        defer { close(f) }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { flock(f, LOCK_UN); return nil }
        return holder().flatMap { pid_t($0) }
    }
}

// MARK: - LaunchAgent

enum Agent {
    static let label = "com.signedadam.brim"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var installed: Bool { FileManager.default.fileExists(atPath: plist.path) }

    /// `restart: false` from inside the app: write and load the agent without killing ourselves
    /// (the agent's copy sees the lock and exits quietly; it takes over at the next login).
    static func install(restart: Bool = true) {
        let bin = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let p: [String: Any] = [
            "Label": label, "ProgramArguments": [bin, "run"], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": Paths.home.appendingPathComponent("stderr.log").path,
        ]
        Paths.ensure()
        let data = try! PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
        try! data.write(to: plist)
        if restart, let pid = Lock.running() { kill(pid, SIGTERM); usleep(400_000) }
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
        print("brim runs at login now (\(plist.path))")
    }

    static func uninstall() {
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
        print("removed the LaunchAgent")
    }
}

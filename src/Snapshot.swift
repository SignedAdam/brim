import AppKit
import SwiftUI

// `brim snapshot out.png`: renders the notch offscreen over a fake desktop, open and closed.
// Used to check the design without anyone's screen, and for the README.

enum Snapshot {
    static func run(_ args: [String]) {
        guard let out = args.first(where: { !$0.hasPrefix("--") }) else { print("usage: brim snapshot <png> [--open] [--flash] [--live] [--settings]"); exit(2) }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            let store = args.contains("--live") ? Store(load: true) : sample()
            let now = args.contains("--live") ? Date() : sampleNow
            store.now = now
            if args.contains("--flash") {
                store.flash = Flash(text: "Studio session at 85%", provider: .claude, tone: .warn)
            }
            let png: Data
            if args.contains("--settings") {
                png = render(SettingsView(store: store, onAdd: { _ in }), size: CGSize(width: 460, height: 720))
            } else {
                let model = NotchModel()
                model.notchWidth = 160; model.notchHeight = 28
                if args.contains("--external") { model.hasNotch = false; model.notchWidth = 14; model.notchHeight = 19; model.topInset = 3 }
                model.open = args.contains("--open")
                let size = CGSize(width: 640, height: model.open ? 290 : 90)
                let view = ZStack(alignment: .top) {
                    Desktop(menuHeight: model.hasNotch ? model.notchHeight : 25)
                    NotchView(store: store, model: model)
                        .frame(width: NotchController.canvas.width, height: NotchController.canvas.height)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                }
                png = render(view.frame(width: size.width, height: size.height), size: size)
            }
            try! png.write(to: URL(fileURLWithPath: out))
            print(out)
        }
    }

    @MainActor
    static func render<V: View>(_ v: V, size: CGSize) -> Data {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        w.orderOut(nil)
        return rep.representation(using: .png, properties: [:])!
    }

    static let sampleNow = Date(timeIntervalSince1970: 1_792_230_000)

    @MainActor
    static func sample() -> Store {
        let s = Store(load: false)
        let now = sampleNow
        func w(_ k: UsageWindow.Kind, _ pct: Double, _ resetIn: TimeInterval) -> UsageWindow {
            let len: TimeInterval = k == .session ? 5 * 3600 : 7 * 86400
            return UsageWindow(kind: k, label: k == .session ? "Session" : "Week", percent: pct,
                               resetsAt: now.addingTimeInterval(resetIn), length: len)
        }
        let rows: [(String, Provider, String, Double, TimeInterval, Double, TimeInterval, Int?)] = [
            ("Personal", .claude, "default_claude_max_20x", 17, 2 * 3600 + 14 * 60, 21, 1.8 * 86400, nil),
            ("Studio", .claude, "default_claude_max_5x", 64, 3 * 3600 + 40 * 60, 48, 4.2 * 86400, nil),
            ("ChatGPT", .codex, "plus", 7, 8 * 60, 34, 5.3 * 86400, 2),
            ("Auernet", .claude, "claude_team", 88, 52 * 60, 71, 2.6 * 86400, nil),
            ("Auernet GPT", .codex, "business", 100, 37 * 60, 55, 3.1 * 86400, nil),
        ]
        for (i, r) in rows.enumerated() {
            let id = "sample-\(i)"
            s.accounts.append(Account(id: id, provider: r.1, source: .signIn, label: r.0, plan: r.2))
            s.usage[id] = Usage(accountId: id, fetchedAt: now.addingTimeInterval(-50),
                                windows: [w(.session, r.3, r.4), w(.weekly, r.5, r.6)], plan: r.2, resetCredits: r.7)
        }
        s.announcement = Announcement(id: "x", provider: .codex, summary: "Codex usage limits reset", url: nil,
                                      at: now.addingTimeInterval(-3 * 3600))
        return s
    }
}

/// A menu bar over a wallpaper, so the notch is judged in context.
struct Desktop: View {
    let menuHeight: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.55, green: 0.36, blue: 0.52),
                                    Color(red: 0.93, green: 0.62, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color(white: 0.12).opacity(0.55)).frame(height: menuHeight)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13))
                Text("Finder").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("View")
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Text("Sat 17 Oct  14:20")
            }
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14).frame(height: menuHeight)
        }
    }
}

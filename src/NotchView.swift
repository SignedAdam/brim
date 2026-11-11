import SwiftUI
import AppKit

enum Theme {
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.56)
    static let faint = Color.white.opacity(0.4)
    static let track = Color.white.opacity(0.11)
    static let accent = Color(red: 0.80, green: 0.96, blue: 0.27)
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.38, blue: 0.34)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func level(_ pct: Double) -> Color { pct >= 100 ? bad : pct >= 85 ? warn : text }
    static func brand(_ p: Provider) -> Color {
        switch p {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.06, green: 0.70, blue: 0.53)
        case .openrouter: return Color(red: 0.55, green: 0.58, blue: 1.0)
        }
    }

    static func mono(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w, design: .monospaced) }
    static func num(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w).monospacedDigit() }
    static func ui(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w) }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var open = false
    @Published var notchWidth: CGFloat = 186
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true
    @Published var topInset: CGFloat = 0
    @Published var hoveredRow: String?

    static let wing: CGFloat = 66
    static let topRadius: CGFloat = 8
    static let openWidth: CGFloat = 500
    static let rowHeight: CGFloat = 34
    static let flashHeight: CGFloat = 26

    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * (hasNotch ? Self.wing : Self.wing - 10), height: notchHeight) }
    var headerHeight: CGFloat { hasNotch || !open ? notchHeight : 32 }

    func openSize(rows: Int, footer: Bool = false, logins: Int = 0) -> CGSize {
        var body = rows == 0 ? 64 : 14 + CGFloat(rows) * Self.rowHeight + 4
        if footer { body += 22 }
        if logins > 0 { body += 6 + Logins.headerHeight + CGFloat(logins) * Logins.rowHeight }
        let header = hasNotch ? notchHeight : 32
        return CGSize(width: max(Self.openWidth, notchWidth + 2 * 100 + 2 * Self.topRadius), height: header + body)
    }
}

struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let b = min(bottom, (r.height - top) / 1.2, (r.width - 2 * top) / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + b, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - b), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var store: Store
    @ObservedObject var model: NotchModel
    var onSettings: () -> Void = {}
    var onAdd: (Provider) -> Void = { _ in }

    private var rows: [Account] { store.visible }
    private var flashing: Bool { store.flash != nil && !model.open }

    private var size: CGSize {
        if model.open { return model.openSize(rows: rows.count, footer: store.announcement != nil) }
        var s = model.collapsedSize
        if flashing { s.height += NotchModel.flashHeight; s.width = max(s.width, 360) }
        return s
    }

    var body: some View {
        let t = model.hasNotch ? NotchModel.topRadius : 0
        ZStack(alignment: .top) {
            Group {
                if model.hasNotch {
                    NotchShape(top: t, bottom: model.open ? 22 : (flashing ? 16 : 10)).fill(Color.black)
                } else {
                    let r = model.open ? 16 : min(14, size.height / 2)
                    RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                }
            }
            .shadow(color: .black.opacity(model.open ? 0.55 : (model.hasNotch ? 0 : 0.25)), radius: model.open ? 18 : 4, y: model.open ? 8 : 1)
            VStack(spacing: 0) {
                header
                if model.open {
                    panel
                        .transition(.opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.18).delay(0.07)))
                } else if let f = store.flash {
                    FlashLine(flash: f)
                        .frame(height: NotchModel.flashHeight - 4)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, t)
            .clipped()
        }
        .frame(width: size.width, height: size.height)
        .padding(.top, model.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.open)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: flashing)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: rows.count)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        let t = model.hasNotch ? NotchModel.topRadius : 0
        let wing = max(0, (size.width - 2 * t - model.notchWidth) / 2)
        let edge: CGFloat = model.open ? 14 : (model.hasNotch ? 12 : 8)
        return HStack(spacing: 0) {
            Group {
                if model.open {
                    Text(updatedText).font(Theme.ui(10)).foregroundStyle(Theme.faint).lineLimit(1)
                        .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.08)))
                } else {
                    Minis(store: store).transition(.opacity)
                }
            }
            .padding(.leading, edge)
            .frame(width: wing, alignment: .leading)
            .clipped()
            Color.clear.frame(width: model.notchWidth)
            Group {
                if model.open {
                    HStack(spacing: 2) {
                        AddMenu(onAdd: onAdd)
                        IconButton(symbol: "arrow.clockwise", help: "Refresh now", spinning: store.refreshing) {
                            Task { await store.refresh() }
                        }
                        IconButton(symbol: "gearshape", help: "Settings", action: onSettings)
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.08)))
                } else {
                    NextReset(store: store)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .transition(.opacity)
                }
            }
            .padding(.trailing, model.open ? 8 : edge)
            .frame(width: wing, alignment: .trailing)
            .clipped()
        }
        .frame(height: model.headerHeight)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                EmptyState(onAdd: onAdd).frame(height: 64)
            } else {
                HStack(spacing: 0) {
                    Spacer()
                    ColumnLabel("Session").frame(width: Row.meterWidth, alignment: .leading)
                    ColumnLabel("Week").frame(width: Row.meterWidth, alignment: .leading).padding(.leading, Row.gap)
                }
                .padding(.horizontal, 16)
                .frame(height: 14, alignment: .bottom)
                ForEach(rows) { a in
                    Row(account: a, usage: store.usage[a.id], now: store.now, lowBalance: store.settings.lowBalance,
                        chips: store.chips(a), hovering: model.hoveredRow == a.id,
                        resetting: store.resetting.contains(a.id), resetFailure: store.resetFailure[a.id],
                        onSwitch: { store.switchTool($0, to: a) }, onReset: { store.useReset(a) })
                        .frame(height: NotchModel.rowHeight)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                        .onHover { model.hoveredRow = $0 ? a.id : (model.hoveredRow == a.id ? nil : model.hoveredRow) }
                        .contextMenu {
                            Button("Refresh") { Task { await store.refresh() } }
                            Button("Settings…", action: onSettings)
                            Divider()
                            Button("Move Up") { store.shift(a.id, by: -1) }.disabled(rows.first?.id == a.id)
                            Button("Move Down") { store.shift(a.id, by: 1) }.disabled(rows.last?.id == a.id)
                            Divider()
                            Button("Remove \(a.label)") { store.remove(a.id) }
                        }
                }
            }
            if let an = store.announcement {
                Announced(item: an, now: store.now).frame(height: 18).padding(.horizontal, 16).padding(.top, 4)
            }
        }
    }

    private var updatedText: String {
        let latest = store.usage.values.map(\.fetchedAt).max()
        guard let latest else { return "" }
        let s = store.now.timeIntervalSince(latest)
        return s < 60 ? "updated just now" : "updated \(Fmt.duration(s)) ago"
    }
}

struct Announced: View {
    let item: Announcement
    let now: Date

    var body: some View {
        Button {
            if let u = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 0) {
                Circle().fill(Theme.accent).frame(width: 4, height: 4).frame(width: 13)
                Text(item.short).foregroundStyle(Theme.dim).lineLimit(1).padding(.leading, 8)
                Spacer(minLength: 6)
                Text("\(Fmt.duration(now.timeIntervalSince(item.at))) ago").font(Theme.num(10)).foregroundStyle(Theme.faint)
            }
            .font(Theme.ui(10.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.summary). Opens the post.")
    }
}

struct ColumnLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(Theme.ui(8.5, .semibold)).kerning(0.8).foregroundStyle(Theme.faint)
    }
}

struct Minis: View {
    @ObservedObject var store: Store

    var body: some View {
        let cols = columns
        let shown = cols.flatMap { $0 }
        let tall = (cols.map(\.count).max() ?? 0) > 4
        let h: CGFloat = tall ? 1.5 : 2
        let gap: CGFloat = tall ? 2 : 2.5
        let w: CGFloat = cols.count > 1 ? 24 : 26
        HStack(alignment: .top, spacing: 4) {
            ForEach(cols.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(cols[i]) { a in
                        let u = store.usage[a.id]
                        let pct = min(u?.peak ?? 0, 100)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(u?.needsAuth == true ? Theme.faint : pct >= 85 ? Theme.level(pct) : Theme.brand(a.provider))
                                .frame(width: u == nil ? 0 : max(h, w * pct / 100))
                        }
                        .frame(width: w, height: h)
                    }
                }
            }
            if shown.isEmpty {
                Capsule().fill(Theme.track).frame(width: 26, height: 2)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: store.usage)
        .help(shown.map { "\($0.label) \(Int(store.usage[$0.id]?.peak ?? 0))%" }.joined(separator: " · "))
    }

    private var columns: [[Account]] {
        var list = store.visible
        if list.count > 6 && store.settings.hideUsedUp {
            list = list.filter { (store.usage[$0.id]?.peak ?? 0) < 100 }
        }
        guard list.count > 6 && store.settings.pairLines else { return list.isEmpty ? [] : [Array(list.prefix(6))] }
        var left = list.filter { $0.provider == .claude }
        var right = list.filter { $0.provider == .codex }
        for a in list where a.provider == .openrouter {
            if left.count <= right.count { left.append(a) } else { right.append(a) }
        }
        return [left, right].filter { !$0.isEmpty }.map { Array($0.prefix(6)) }
    }
}

struct NextReset: View {
    @ObservedObject var store: Store

    var body: some View {
        if let (w, blocked) = pick() {
            HStack(spacing: 3) {
                Image(systemName: blocked ? "pause.fill" : "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .bold))
                Text(Fmt.reset(w.resetsAt, now: store.now)).font(Theme.num(11.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(blocked ? Theme.warn : Theme.text.opacity(0.8))
            .help(blocked ? "A maxed-out window resets in \(Fmt.reset(w.resetsAt, now: store.now))" : "Next reset")
        }
    }

    private func pick() -> (UsageWindow, Bool)? {
        let now = store.now
        let all = store.visible.compactMap { store.usage[$0.id] }.flatMap(\.windows)
            .filter { ($0.resetsAt ?? .distantPast) > now }
        if let b = all.filter({ $0.percent >= 100 }).min(by: { $0.resetsAt! < $1.resetsAt! }) { return (b, true) }
        if let w = all.filter({ $0.percent >= 1 }).min(by: { $0.resetsAt! < $1.resetsAt! }) { return (w, false) }
        return nil
    }
}

struct FlashLine: View {
    let flash: Flash

    var body: some View {
        HStack(spacing: 7) {
            if let p = flash.provider { Mark(provider: p, tint: Theme.brand(p)).frame(width: 11, height: 11) }
            Text(flash.text).font(Theme.ui(11.5)).foregroundStyle(Theme.text).lineLimit(1)
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 14)
    }

    private var color: Color {
        switch flash.tone {
        case .accent: return Theme.accent
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        case .plain: return Theme.dim
        }
    }
}

struct Row: View {
    let account: Account
    let usage: Usage?
    let now: Date
    var lowBalance: Double = 5
    var chips: [Chip] = []
    var hovering = false
    var resetting = false
    var resetFailure: String?
    var onSwitch: (Tool) -> Void = { _ in }
    var onReset: () -> Void = {}

    static let meterWidth: CGFloat = 100
    static let gap: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Mark(provider: account.provider, tint: Theme.brand(account.provider)).frame(width: 13, height: 13)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(account.label).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
                        if let c = usage?.resetCredits, c > 0 {
                            ResetCredits(count: c, busy: resetting, failure: resetFailure, onUse: onReset)
                        }
                    }
                    Text(subtitle).font(Theme.ui(10)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 6)
                ToolChips(chips: chips, hovering: hovering, onSwitch: onSwitch).padding(.trailing, 10).layoutPriority(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let u = usage, u.needsAuth == true || (!u.hasData && u.error != nil) {
                Text(u.needsAuth == true ? (account.source == .apiKey ? "Key rejected" : "Sign in again") : (u.error ?? ""))
                    .font(Theme.ui(11)).foregroundStyle(Theme.warn).lineLimit(1)
                    .frame(width: 2 * Self.meterWidth + Self.gap, alignment: .leading)
            } else if account.provider == .openrouter {
                Spend(today: usage?.balance?.today, week: usage?.balance?.week).frame(width: Self.meterWidth)
                BalanceMeter(balance: usage?.balance, low: lowBalance).frame(width: Self.meterWidth).padding(.leading, Self.gap)
            } else {
                Meter(window: usage?.session, now: now, tint: Theme.brand(account.provider)).frame(width: Self.meterWidth)
                Meter(window: usage?.weekly, now: now, tint: Theme.brand(account.provider)).frame(width: Self.meterWidth).padding(.leading, Self.gap)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if account.provider == .openrouter { parts.append("Credits") }
        if let p = Fmt.plan(account.plan ?? usage?.plan, account.provider) { parts.append(p) }
        if let m = usage?.windows.first(where: { $0.kind == .model && $0.percent >= 40 }) { parts.append("\(m.label) \(Int(m.percent))%") }
        if parts.isEmpty { parts.append(account.provider.name) }
        if usage?.error != nil, usage?.needsAuth != true, !(usage?.windows.isEmpty ?? true) { parts.append("stale") }
        return parts.joined(separator: " · ")
    }
}

struct ResetCredits: View {
    let count: Int
    let busy: Bool
    let failure: String?
    let onUse: () -> Void
    @State private var pressing = false
    @State private var fill: CGFloat = 0
    @State private var failed = false
    @State private var hover = false

    static let hold = 0.8

    var body: some View {
        Group {
            if busy {
                label.phaseAnimator([1, 0.35]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.6) }
            } else {
                label
            }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onLongPressGesture(minimumDuration: Self.hold, maximumDistance: 12) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onUse()
        } onPressingChanged: { p in
            pressing = p
            withAnimation(p ? .linear(duration: Self.hold) : .easeOut(duration: 0.2)) { fill = p ? 1 : 0 }
        }
        .allowsHitTesting(!busy)
        .onChange(of: failure) { _, f in
            failed = f != nil
            guard f != nil else { return }
            Task { try? await Task.sleep(for: .seconds(2)); failed = false }
        }
        .help(failure.map { "Reset failed: \($0). Hold to try again" }
              ?? "\(count) limit reset\(count == 1 ? "" : "s") banked with OpenAI. Hold to use one")
    }

    private var wording: String {
        if busy { return "Resetting" }
        if failed { return "Failed" }
        if hover || pressing { return "Reset?" }
        return "\(count) reset\(count == 1 ? "" : "s")"
    }

    private var label: some View {
        ZStack(alignment: .leading) {
            face("Resetting", solid: false).hidden()
            face(wording, solid: busy || (hover && !pressing))
                .overlay(alignment: .leading) {
                    face(wording, solid: true)
                        .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * fill) } }
                }
        }
    }

    private func face(_ text: String, solid: Bool) -> some View {
        Text(text).font(Theme.ui(9.5, .semibold))
            .foregroundStyle(solid ? Color.black : failed ? Theme.warn : Theme.accent)
            .padding(.horizontal, 3).padding(.vertical, 0.5)
            .background(RoundedRectangle(cornerRadius: 2.5)
                .fill(solid ? Theme.accent : pressing ? Theme.accent.opacity(0.2) : .clear))
    }
}

struct Spend: View {
    let today: Double?
    let week: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 7)
            HStack(spacing: 0) {
                Text(today.map(Fmt.money) ?? "—").font(Theme.num(10.5, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Text("today").font(Theme.num(10.5)).foregroundStyle(Theme.dim)
            }
        }
        .help(week.map { "This key spent \(Fmt.money($0)) this week (UTC)" } ?? "Spent today")
    }
}

struct BalanceMeter: View {
    let balance: Balance?
    let low: Double

    var body: some View {
        let left = balance?.remaining
        let isLow = left.map { $0 < low } ?? false
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    if let p = balance?.usedPercent {
                        Capsule().fill(isLow ? Theme.warn : Theme.brand(.openrouter))
                            .frame(width: max(p > 0 ? 3 : 0, g.size.width * p / 100))
                    }
                }
                .frame(height: 3).frame(maxHeight: .infinity)
            }
            .frame(height: 7)
            HStack(spacing: 0) {
                Text(left.map(Fmt.money) ?? "—").font(Theme.num(10.5, .semibold)).foregroundStyle(isLow ? Theme.warn : Theme.text)
                Spacer(minLength: 4)
                Text("left").font(Theme.num(10.5)).foregroundStyle(Theme.dim)
            }
        }
        .help(balance?.total.map { "Balance: \(Fmt.money(left ?? 0)) of \(Fmt.money($0))" } ?? "Balance")
    }
}

struct Meter: View {
    let window: UsageWindow?
    let now: Date
    var tint: Color = Color.white.opacity(0.88)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    if let win = window {
                        Capsule().fill(fill(win)).frame(width: max(win.percent > 0 ? 3 : 0, w * min(win.percent, 100) / 100))
                    }
                }
                .frame(width: w, height: 3)
                .overlay(alignment: .leading) {
                    if let win = window, let e = win.elapsed(at: now), e > 0.03, e < 0.97 {
                        let inFill = e * 100 < win.percent
                        Capsule().fill(inFill ? Color.black : Color.white.opacity(0.45))
                            .frame(width: inFill ? 1.5 : 1, height: inFill ? 3 : 7)
                            .offset(x: w * e - 0.75)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 7)
            HStack(spacing: 0) {
                if let win = window {
                    Text("\(Int(win.percent.rounded()))%").font(Theme.num(10.5, .semibold)).foregroundStyle(pctColor(win))
                    Spacer(minLength: 4)
                    Text(Fmt.reset(win.resetsAt, now: now)).font(Theme.num(10.5)).foregroundStyle(Theme.dim)
                } else {
                    Text("—").font(Theme.num(10.5)).foregroundStyle(Theme.faint)
                }
            }
        }
        .help(help)
    }

    private func fill(_ w: UsageWindow) -> Color {
        w.percent >= 85 ? Theme.level(w.percent) : tint
    }

    private func pctColor(_ w: UsageWindow) -> Color {
        if w.percent >= 85 { return Theme.level(w.percent) }
        return Theme.text
    }

    private var help: String {
        guard let w = window else { return "No data" }
        var s = "\(w.label): \(Int(w.percent))% used"
        if let r = w.resetsAt { s += ", resets \(Fmt.when(r))" }
        if let out = w.runsOut(at: now) { s += ". At this pace it runs out in \(Fmt.duration(out.timeIntervalSince(now)))" }
        else if let p = w.projected(at: now) { s += ". At this pace: \(Int(min(p, 100)))% by reset" }
        return s
    }
}

struct EmptyState: View {
    var onAdd: (Provider) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("No accounts yet").font(Theme.ui(12)).foregroundStyle(Theme.dim)
            Spacer()
            ForEach(Provider.allCases, id: \.self) { p in
                Button { onAdd(p) } label: {
                    HStack(spacing: 5) { Mark(provider: p).frame(width: 11, height: 11); Text("Add \(p.name)") }
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct AddMenu: View {
    var onAdd: (Provider) -> Void
    var body: some View {
        Menu {
            Button("Add Claude Account…") { onAdd(.claude) }
            Button("Add ChatGPT Account…") { onAdd(.codex) }
            Button("Add OpenRouter Key…") { onAdd(.openrouter) }
        } label: {
            Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.dim)
        .frame(width: 22, height: 22)
        .help("Add an account")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .foregroundStyle(hover ? Theme.text : Theme.dim)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Mark: View {
    let provider: Provider
    var tint: Color? = nil

    var body: some View {
        if let img = Self.images[provider] {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .foregroundStyle(tint ?? Theme.text.opacity(0.85))
        }
    }

    static let images: [Provider: NSImage] = {
        var out: [Provider: NSImage] = [:]
        for (p, svg) in [(Provider.claude, MarkSVG.claude), (.codex, MarkSVG.openai), (.openrouter, MarkSVG.openrouter)] {
            if let img = NSImage(data: Data(svg.replacingOccurrences(of: "<svg ", with: "<svg width=\"48\" height=\"48\" ").utf8)) {
                img.isTemplate = true
                out[p] = img
            }
        }
        return out
    }()
}

struct ToolChips: View {
    let chips: [Chip]
    let hovering: Bool
    let onSwitch: (Tool) -> Void

    static let size: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips) { c in
                ToolChip(chip: c, shown: c.active || c.busy || hovering) { onSwitch(c.tool) }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct ToolChip: View {
    let chip: Chip
    let shown: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if chip.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if shown {
                    ToolGlyph(tool: chip.tool)
                        .saturation(chip.active ? 1 : 0)
                        .opacity(chip.active ? 1 : hover ? 0.9 : 0.35)
                }
            }
            .frame(width: ToolChips.size, height: ToolChips.size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chip.busy || chip.active || !shown)
        .onHover { hover = $0 }
        .help(chip.active ? "\(chip.tool.name) uses this account" : "Switch \(chip.tool.name) to this account")
    }
}

struct ToolGlyph: View {
    let tool: Tool

    var body: some View {
        if let img = Self.icons[tool] {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Text(tool.name.prefix(1)).font(.system(size: 9, weight: .bold))
        }
    }

    static let icons: [Tool: NSImage] = {
        var out: [Tool: NSImage] = [:]
        let apps: [Tool: [String]] = [.claudeCode: ["/Applications/Claude.app"],
                                      .codex: ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
                                      .hermes: ["/Applications/Hermes.app"]]
        for (t, paths) in apps {
            if let p = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                out[t] = NSWorkspace.shared.icon(forFile: p)
            }
        }
        out[.omp] = NSImage(data: Data(Self.ompSVG.utf8))
        return out
    }()

    static let ompSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 120 90\" width=\"120\" height=\"90\">   <!-- Pi symbol with plugin connector -->   <!-- Horizontal bar -->   <rect x=\"10\" y=\"8\" width=\"100\" height=\"12\" rx=\"2\" fill=\"#fafafa\"/>   <!-- Left leg -->   <rect x=\"25\" y=\"20\" width=\"12\" height=\"62\" rx=\"2\" fill=\"#fafafa\"/>   <!-- Right leg -->   <rect x=\"75\" y=\"20\" width=\"12\" height=\"45\" rx=\"2\" fill=\"#fafafa\"/>   <!-- Plugin connector -->   <rect x=\"71\" y=\"55\" width=\"20\" height=\"16\" rx=\"3\" fill=\"#f97316\"/>   <rect x=\"76\" y=\"59\" width=\"3\" height=\"8\" rx=\"1\" fill=\"#0d0d0d\"/>   <rect x=\"82\" y=\"59\" width=\"3\" height=\"8\" rx=\"1\" fill=\"#0d0d0d\"/>   <!-- Decorative dots -->   <circle cx=\"18\" cy=\"14\" r=\"2\" fill=\"#f97316\" opacity=\"0.8\"/>   <circle cx=\"102\" cy=\"14\" r=\"2\" fill=\"#f97316\" opacity=\"0.8\"/> </svg> "
}

struct Logins: View {
    @ObservedObject var store: Store
    static let rowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack { ColumnLabel("Logins"); Spacer() }.frame(height: Self.headerHeight, alignment: .bottom)
            ForEach(store.loginTools, id: \.self) { t in
                HStack(spacing: 0) {
                    Text(t.name).font(Theme.ui(11.5)).foregroundStyle(Theme.dim)
                        .frame(width: 96, alignment: .leading)
                    Menu {
                        ForEach(store.visible.filter { $0.provider == store.loginProvider(t) }) { a in
                            Button {
                                store.switchTool(t, to: a)
                            } label: {
                                Text(store.loginLabel(t) == a.label ? "✓ \(a.label)" : a.label)
                            }
                            .disabled(store.loginLabel(t) == a.label)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.isSwitching(t) ? "Switching…" : store.loginLabel(t))
                                .font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                }
                .frame(height: Self.rowHeight)
            }
        }
    }
}

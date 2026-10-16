import SwiftUI

// Settings window: accounts and alerts. Same ink, hairline cards, one accent.

struct SettingsView: View {
    @ObservedObject var store: Store
    var onAdd: (Provider) -> Void

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Brim").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.text)
                        Text(VERSION).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    }
                    .padding(.top, 30)
                    Card(title: "Accounts") {
                        ForEach(store.accounts.filter { !$0.isHidden }) { a in
                            AccountRow(store: store, account: a)
                        }
                        HStack(spacing: 8) {
                            ForEach(Provider.allCases, id: \.self) { p in
                                Button { onAdd(p) } label: {
                                    HStack(spacing: 6) {
                                        Mark(provider: p).frame(width: 11, height: 11)
                                        Text("Add \(p == .claude ? "Claude" : "ChatGPT") account")
                                    }
                                    .font(Theme.ui(11.5)).foregroundStyle(Theme.text)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.top, 6)
                        let hidden = store.accounts.filter(\.isHidden)
                        if !hidden.isEmpty {
                            HStack(spacing: 6) {
                                Text("Hidden:").foregroundStyle(Theme.faint)
                                ForEach(hidden) { a in
                                    Button(a.label) { store.update(a.id) { $0.hidden = false }; Task { await store.refresh() } }
                                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                                }
                            }
                            .font(Theme.ui(11))
                        }
                    }
                    Card(title: "Alerts") {
                        SettingRow(name: "Thresholds", hint: "percent, comma separated") {
                            NumberList(values: $store.settings.thresholds, onCommit: store.saveSettings)
                        }
                        SettingRow(name: "Use it or lose it", hint: "weekly window resets soon with this much left") {
                            HStack(spacing: 4) {
                                NumberField(value: $store.settings.leftoverPercent, onCommit: store.saveSettings)
                                Text("% within").foregroundStyle(Theme.faint)
                                NumberField(value: $store.settings.leftoverLeadHours, onCommit: store.saveSettings)
                                Text("h").foregroundStyle(Theme.faint)
                            }
                            .font(Theme.ui(11))
                        }
                        SettingRow(name: "Resets", hint: "say when a window starts over") {
                            Toggle("", isOn: Binding(get: { store.settings.alertOnReset },
                                                     set: { store.settings.alertOnReset = $0; store.saveSettings() }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        SettingRow(name: "Pager", hint: Store.pagerPath == nil ? "pager isn't installed" : "a line on the ambient stream") {
                            Toggle("", isOn: Binding(get: { store.settings.pager },
                                                     set: { store.settings.pager = $0; store.saveSettings() }))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .disabled(Store.pagerPath == nil)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Hooks").font(Theme.ui(12)).foregroundStyle(Theme.text)
                            Text("One command per line. Each alert arrives as JSON on stdin and in $BRIM_ALERT, so an agent can act on it: spend leftover quota, pause heavy work.")
                                .font(Theme.ui(10.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            HooksEditor(store: store)
                        }
                        .padding(.vertical, 6)
                    }
                    Card(title: "Refresh") {
                        SettingRow(name: "Every", hint: "the notch also refreshes when you open it") {
                            HStack(spacing: 4) {
                                NumberField(value: Binding(get: { store.settings.refreshSeconds / 60 },
                                                           set: { store.settings.refreshSeconds = max(1, $0) * 60 }),
                                            onCommit: store.saveSettings)
                                Text("min").foregroundStyle(Theme.faint)
                            }
                            .font(Theme.ui(11))
                        }
                    }
                    Text("Terminal: brim status --json · brim add claude|codex · ~/.brim")
                        .font(Theme.mono(10)).foregroundStyle(Theme.faint)
                        .padding(.bottom, 16)
                }
                .frame(width: g.size.width - 36, alignment: .leading)
                .padding(.horizontal, 18)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Color(white: 0.035))
        .environment(\.colorScheme, .dark)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(Theme.ui(9.5, .semibold)).kerning(0.9).foregroundStyle(Theme.faint)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08)))
        }
    }
}

struct SettingRow<Control: View>: View {
    let name: String
    let hint: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.ui(12)).foregroundStyle(Theme.text)
                Text(hint).font(Theme.ui(10.5)).foregroundStyle(Theme.dim)
            }
            Spacer()
            control
        }
        .frame(minHeight: 36)
    }
}

struct AccountRow: View {
    @ObservedObject var store: Store
    let account: Account
    @State private var label = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Mark(provider: account.provider).frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $label, onCommit: commit)
                    .textFieldStyle(.plain).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Button { store.remove(account.id) } label: {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help(account.source == .signIn ? "Remove" : "Hide (the login stays with the CLI)")
            .opacity(hover ? 1 : 0)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onAppear { label = account.label }
        .onChange(of: account.label) { _, new in label = new }
    }

    private var detail: String {
        let src: String? = account.source == .claudeCode ? "via Claude Code" : account.source == .codexCLI ? "via Codex CLI" : nil
        return [account.email, Fmt.plan(account.plan ?? store.usage[account.id]?.plan), src].compactMap { $0 }.joined(separator: " · ")
    }

    private func commit() {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { label = account.label; return }
        store.update(account.id) { $0.label = l }
    }
}

struct NumberField: View {
    @Binding var value: Double
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, onCommit: {
            if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { value = v }
            text = fmt(value); onCommit()
        })
        .textFieldStyle(.plain).font(Theme.mono(11)).multilineTextAlignment(.trailing)
        .frame(width: 34).padding(.horizontal, 5).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
        .onAppear { text = fmt(value) }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

struct NumberList: View {
    @Binding var values: [Double]
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("80, 95", text: $text, onCommit: {
            values = text.split(whereSeparator: { ", ".contains($0) }).compactMap { Double($0) }.filter { $0 > 0 && $0 <= 100 }.sorted()
            text = values.map { String(Int($0)) }.joined(separator: ", "); onCommit()
        })
        .textFieldStyle(.plain).font(Theme.mono(11)).multilineTextAlignment(.trailing)
        .frame(width: 90).padding(.horizontal, 6).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
        .onAppear { text = values.map { String(Int($0)) }.joined(separator: ", ") }
    }
}

struct HooksEditor: View {
    @ObservedObject var store: Store
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(11)).scrollContentBackground(.hidden)
            .padding(6).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("hermes chat -q \"$(jq -r .title)\"").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .onAppear { text = store.settings.hooks.joined(separator: "\n") }
            .onChange(of: text) { _, t in
                store.settings.hooks = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                store.saveSettings()
            }
    }
}

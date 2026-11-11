import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store
    var onAdd: (Provider) -> Void
    var onDisplay: () -> Void = {}
    @State private var atLogin = Agent.installed

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts) { a in
                    AccountRow(store: store, account: a)
                }
                HStack {
                    Button("Add Claude Account…") { onAdd(.claude) }
                    Button("Add ChatGPT Account…") { onAdd(.codex) }
                    Button("Add OpenRouter Key…") { onAdd(.openrouter) }
                    Spacer()
                }
            }

            Section {
                Toggle("Show Claude and Codex side by side", isOn: bind(\.pairLines))
                Toggle("Hide accounts that are used up", isOn: bind(\.hideUsedUp))
            } header: {
                Text("Closed notch")
            } footer: {
                Text("Both apply only when the closed notch has more than 6 accounts to show. The open notch always lists every checked account.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Alerts") {
                LabeledContent("Warn at") {
                    HStack(spacing: 4) {
                        PercentList(values: $store.settings.thresholds, onCommit: store.saveSettings)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Unused quota warning") {
                    HStack(spacing: 4) {
                        NumberField(value: $store.settings.leftoverPercent, onCommit: store.saveSettings)
                        Text("% left,").foregroundStyle(.secondary)
                        NumberField(value: $store.settings.leftoverLeadHours, onCommit: store.saveSettings)
                        Text("h before reset").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Low balance") {
                    HStack(spacing: 4) {
                        Text("$").foregroundStyle(.secondary)
                        NumberField(value: $store.settings.lowBalance, onCommit: store.saveSettings)
                    }
                }
                Toggle("Limit resets", isOn: bind(\.alertOnReset))
                Toggle("Announced resets", isOn: bind(\.announcements))
                Toggle("Send to Pager", isOn: bind(\.pager)).disabled(Store.pagerPath == nil)
                LabeledContent("Run on alert") {
                    HooksField(store: store)
                }
            }

            Section("General") {
                Picker("Refresh every", selection: Binding(get: { Int(store.settings.refreshSeconds / 60) },
                                                           set: { store.settings.refreshSeconds = Double($0 * 60); store.saveSettings() })) {
                    ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Display", selection: Binding(get: { store.settings.display },
                                                     set: { store.settings.display = $0; store.saveSettings(); onDisplay() })) {
                    Text("Follow pointer").tag("auto")
                    ForEach(NSScreen.screens, id: \.localizedName) { s in Text(s.localizedName).tag(s.localizedName) }
                }
                Toggle("Open at login", isOn: Binding(get: { atLogin }, set: { on in
                    if on { Agent.install(restart: false) } else { Agent.uninstall() }
                    atLogin = Agent.installed
                }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 560)
    }

    private func bind(_ k: WritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: k] }, set: { store.settings[keyPath: k] = $0; store.saveSettings() })
    }
}

struct AccountRow: View {
    @ObservedObject var store: Store
    let account: Account
    @State private var label = ""

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Show \(account.label)", isOn: Binding(get: { !account.isHidden },
                                                          set: { $0 ? store.restore(account.id) : store.hide(account.id) }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(account.isHidden ? "Hidden from the notch. Check to show \(account.label) again." : "Shown in the notch. Uncheck to hide \(account.label) until checked again.")
            Group {
                Mark(provider: account.provider, tint: .primary).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("", text: $label, prompt: Text("Name"))
                        .labelsHidden().textFieldStyle(.plain).fontWeight(.medium)
                        .onSubmit(commit)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(account.isHidden ? 0.5 : 1)
            Spacer()
            if !(account.isHidden && Store.discovered(account)) {
                Button { store.remove(account.id) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        .onAppear { label = account.label }
        .onChange(of: account.label) { _, new in label = new }
    }

    private var detail: String {
        [account.email, Fmt.plan(account.plan ?? store.usage[account.id]?.plan, account.provider)].compactMap { $0 }.joined(separator: " · ")
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
        TextField("", text: $text)
            .multilineTextAlignment(.trailing).frame(width: 40).labelsHidden()
            .onSubmit {
                if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { value = v }
                text = fmt(value); onCommit()
            }
            .onAppear { text = fmt(value) }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

struct PercentList: View {
    @Binding var values: [Double]
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("80, 95"))
            .multilineTextAlignment(.trailing).frame(width: 80).labelsHidden()
            .onSubmit {
                values = text.split(whereSeparator: { ", ".contains($0) }).compactMap { Double($0) }.filter { $0 > 0 && $0 <= 100 }.sorted()
                text = values.map { String(Int($0)) }.joined(separator: ", "); onCommit()
            }
            .onAppear { text = values.map { String(Int($0)) }.joined(separator: ", ") }
    }
}

struct HooksField: View {
    @ObservedObject var store: Store
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("command"), axis: .vertical)
            .font(.system(.body, design: .monospaced)).lineLimit(1...4)
            .frame(width: 220).labelsHidden()
            .onAppear { text = store.settings.hooks.joined(separator: "\n") }
            .onChange(of: text) { _, _ in save() }
    }

    private func save() {
        store.settings.hooks = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.saveSettings()
    }
}

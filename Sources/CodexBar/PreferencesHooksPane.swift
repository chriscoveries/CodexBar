import CodexBarCore
import SwiftUI

@MainActor
struct HooksPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.enabledBinding) {
                    SettingsRowLabel(L("hooks_enable_title"), subtitle: L("hooks_enable_subtitle"))
                }
                Label(L("hooks_trust_warning"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("tab_hooks"))
            }

            Section {
                if self.settings.hookRules.isEmpty {
                    Text(L("hooks_empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.settings.hookRules) { rule in
                        HookRuleRow(
                            rule: self.binding(for: rule),
                            onDelete: { self.settings.removeHookRule(id: rule.id) })
                    }
                }

                Button {
                    self.settings.addHookRule(HookRule(event: .quotaReached, executable: ""))
                } label: {
                    Label(L("hooks_add_rule"), systemImage: "plus")
                }
            } header: {
                Text(L("hooks_rules_header"))
            }
        }
        .formStyle(.grouped)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.hooksEnabled },
            set: { self.settings.setHooksEnabled($0) })
    }

    private func binding(for rule: HookRule) -> Binding<HookRule> {
        Binding(
            get: { self.settings.hookRules.first(where: { $0.id == rule.id }) ?? rule },
            set: { self.settings.updateHookRule($0) })
    }
}

@MainActor
private struct HookRuleRow: View {
    @Binding var rule: HookRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(L("hooks_rule_enabled"), isOn: self.$rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Picker(L("hooks_event"), selection: self.$rule.event) {
                    ForEach(HookEventType.allCases, id: \.self) { event in
                        Text(event.rawValue).tag(event)
                    }
                }
                .labelsHidden()

                Picker(L("hooks_provider"), selection: self.providerBinding) {
                    Text(L("hooks_any_provider")).tag(String?.none)
                    ForEach(UsageProvider.allCases, id: \.self) { provider in
                        Text(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
                            .tag(String?.some(provider.rawValue))
                    }
                }
                .labelsHidden()

                Spacer()

                Button(role: .destructive, action: self.onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("hooks_delete_rule"))
            }

            if self.rule.event == .quotaLow {
                HStack {
                    Text(L("hooks_threshold"))
                        .foregroundStyle(.secondary)
                    TextField(L("hooks_threshold_placeholder"), value: self.thresholdPercentBinding, format: .number)
                        .frame(width: 60)
                    Text(verbatim: "%")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            TextField(L("hooks_executable_placeholder"), text: self.$rule.executable)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            TextField(L("hooks_arguments_placeholder"), text: self.argumentsBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.vertical, 4)
    }

    private var providerBinding: Binding<String?> {
        Binding(get: { self.rule.provider }, set: { self.rule.provider = $0 })
    }

    /// Threshold stored as a 0...1 fraction, edited as a 0...100 percentage.
    private var thresholdPercentBinding: Binding<Double?> {
        Binding(
            get: { self.rule.threshold.map { $0 * 100 } },
            set: { self.rule.threshold = $0.map { min(max($0, 0), 100) / 100 } })
    }

    /// Whitespace-joined arguments. Simple split by spaces; adequate for v1.
    private var argumentsBinding: Binding<String> {
        Binding(
            get: { self.rule.arguments.joined(separator: " ") },
            set: { self.rule.arguments = $0.split(separator: " ").map(String.init) })
    }
}

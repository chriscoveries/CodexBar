import CodexBarCore
import SwiftUI

@MainActor
struct ProviderConfettiPaletteSettingsView: View {
    private static let maximumColorCount = ProviderBranding.confettiPaletteCountRange.upperBound

    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @State private var draftHexValues: [String]

    init(provider: UsageProvider, settings: SettingsStore) {
        self.provider = provider
        self.settings = settings
        self._draftHexValues = State(initialValue: Self.padded(settings.confettiPaletteHexValues(for: provider)))
    }

    var body: some View {
        Section {
            ForEach(0..<Self.maximumColorCount, id: \.self) { index in
                HStack(spacing: 8) {
                    Circle()
                        .fill(self.color(at: index))
                        .overlay {
                            Circle()
                                .stroke(.quaternary)
                        }
                        .frame(width: 18, height: 18)

                    TextField(text: self.$draftHexValues[index], prompt: Text(verbatim: "#RRGGBB")) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote.monospaced())
                    .frame(width: 100)
                    .accessibilityLabel(Text(L("confetti_palette_color", index + 1)))
                    .onSubmit { self.applyDraft() }
                }
            }

            HStack(spacing: 10) {
                Button(L("Default")) {
                    self.settings.resetConfettiPalette(for: self.provider)
                    self.reloadDraft()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!self.settings.hasConfettiPaletteOverride(for: self.provider))

                Button(L("Done")) {
                    self.applyDraft()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } header: {
            Text(L("section_celebrations"))
        } footer: {
            SettingsSectionFooter(L("confetti_palette_hint"))
        }
        .onChange(of: self.settings.confettiPaletteHexValues(for: self.provider)) { _, _ in
            self.reloadDraft()
        }
    }

    private func color(at index: Int) -> Color {
        guard let color = ProviderColor(hexString: self.draftHexValues[index]) else { return .clear }
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private func applyDraft() {
        guard self.settings.setConfettiPaletteHexValues(self.draftHexValues, for: self.provider) else { return }
        self.reloadDraft()
    }

    private func reloadDraft() {
        self.draftHexValues = Self.padded(self.settings.confettiPaletteHexValues(for: self.provider))
    }

    private static func padded(_ values: [String]) -> [String] {
        Array(values.prefix(self.maximumColorCount))
            + Array(repeating: "", count: max(0, self.maximumColorCount - values.count))
    }
}

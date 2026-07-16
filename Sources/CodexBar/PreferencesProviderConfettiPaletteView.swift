#if os(macOS)
import AppKit
#endif
import CodexBarCore
import SwiftUI

@MainActor
struct ProviderConfettiPaletteSettingsView: View {
    private static let maximumColorCount = ProviderBranding.confettiPaletteCountRange.upperBound
    private static let validationDelay = Duration.milliseconds(150)

    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @State private var draftHexValues: [String]
    @State private var processingColorIndices: Set<Int> = []
    @State private var validationRevisions: [Int: Int] = [:]
    @FocusState private var focusedColorIndex: Int?

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

                    self.colorField(at: index)
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
                    if self.applyDraft() {
                        self.clearFocus()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!self.canApplyDraft)

                Button(L("Preview")) {
                    guard self.applyDraft() else { return }
                    self.clearFocus()
                    NotificationCenter.default.post(
                        name: .codexbarConfettiPreviewRequested,
                        object: ConfettiPreviewEvent(provider: self.provider))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!self.canApplyDraft)
            }
        } header: {
            Text(L("section_celebrations"))
        } footer: {
            SettingsSectionFooter(L("confetti_palette_hint"))
        }
        .onChange(of: self.settings.confettiPaletteHexValues(for: self.provider)) { _, _ in
            self.reloadDraft()
        }
        .onChange(of: self.focusedColorIndex) { previous, current in
            if let previous, previous != current {
                self.stopValidation(for: previous)
            }
        }
        .onDisappear { self.stopAllValidation() }
    }

    private func colorField(at index: Int) -> some View {
        HStack(spacing: 6) {
            TextField(text: self.$draftHexValues[index], prompt: Text(verbatim: "#RRGGBB")) {
                EmptyView()
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.footnote.monospaced())
            .frame(width: 100)
            .focused(self.$focusedColorIndex, equals: index)
            .accessibilityLabel(Text(L("confetti_palette_color", index + 1)))
            .onChange(of: self.draftHexValues[index]) { _, _ in
                self.beginValidation(for: index)
            }
            .onSubmit {
                if self.applyDraft() {
                    self.clearFocus()
                }
            }
            .background(self.focusMonitor(isActive: self.focusedColorIndex == index))

            if self.focusedColorIndex == index {
                Circle()
                    .fill(self.validationStatus(at: index).color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                    .animation(.easeInOut(duration: 0.15), value: self.validationStatus(at: index))
            }
        }
    }

    private func color(at index: Int) -> Color {
        guard let color = ProviderColor(hexString: self.draftHexValues[index]) else { return .clear }
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private var canApplyDraft: Bool {
        SettingsStore.normalizedConfettiPaletteHexValues(self.draftHexValues) != nil
    }

    @discardableResult
    private func applyDraft() -> Bool {
        guard self.settings.setConfettiPaletteHexValues(self.draftHexValues, for: self.provider) else { return false }
        self.reloadDraft()
        return true
    }

    private func reloadDraft() {
        self.draftHexValues = Self.padded(self.settings.confettiPaletteHexValues(for: self.provider))
    }

    private static func padded(_ values: [String]) -> [String] {
        Array(values.prefix(self.maximumColorCount))
            + Array(repeating: "", count: max(0, self.maximumColorCount - values.count))
    }

    private func validationStatus(at index: Int) -> ProviderConfettiPaletteColorValidationStatus {
        ProviderConfettiPaletteColorValidationStatus.status(
            for: self.draftHexValues[index],
            isProcessing: self.processingColorIndices.contains(index))
    }

    private func beginValidation(for index: Int) {
        guard self.focusedColorIndex == index else { return }

        let revision = (self.validationRevisions[index] ?? 0) + 1
        self.validationRevisions[index] = revision
        self.processingColorIndices.insert(index)

        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.validationDelay)
            } catch {
                return
            }

            guard self.focusedColorIndex == index,
                  self.validationRevisions[index] == revision
            else { return }
            self.processingColorIndices.remove(index)
        }
    }

    private func stopValidation(for index: Int) {
        self.validationRevisions[index] = (self.validationRevisions[index] ?? 0) + 1
        self.processingColorIndices.remove(index)
    }

    private func stopAllValidation() {
        self.validationRevisions.removeAll()
        self.processingColorIndices.removeAll()
    }

    private func clearFocus() {
        #if os(macOS)
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        #endif
        self.focusedColorIndex = nil
    }

    @ViewBuilder
    private func focusMonitor(isActive: Bool) -> some View {
        #if os(macOS)
        FocusResigningMonitor(isActive: isActive) {
            self.clearFocus()
        }
        #else
        EmptyView()
        #endif
    }
}

extension ProviderConfettiPaletteColorValidationStatus {
    fileprivate var color: Color {
        switch self {
        case .valid: .green
        case .invalid: .red
        case .processing: .yellow
        }
    }
}

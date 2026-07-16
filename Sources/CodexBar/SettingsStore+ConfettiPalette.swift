import CodexBarCore
import Foundation

extension SettingsStore {
    private var confettiPaletteOverridesRaw: [String: [String]] {
        get { self.defaultsState.confettiPaletteOverridesRaw }
        set {
            guard self.defaultsState.confettiPaletteOverridesRaw != newValue else { return }
            self.defaultsState.confettiPaletteOverridesRaw = newValue
            self.userDefaults.set(newValue, forKey: Self.confettiPaletteOverridesKey)
        }
    }

    func confettiPalette(for provider: UsageProvider) -> [ProviderColor] {
        if let rawOverride = self.confettiPaletteOverridesRaw[provider.rawValue],
           let override = Self.confettiPalette(from: rawOverride)
        {
            return override
        }
        return ProviderDescriptorRegistry.descriptor(for: provider).branding.confettiPalette
    }

    func confettiPaletteHexValues(for provider: UsageProvider) -> [String] {
        self.confettiPalette(for: provider).map(\.hexString)
    }

    func hasConfettiPaletteOverride(for provider: UsageProvider) -> Bool {
        self.confettiPaletteOverridesRaw[provider.rawValue] != nil
    }

    @discardableResult
    func setConfettiPaletteHexValues(_ hexValues: [String], for provider: UsageProvider) -> Bool {
        guard let normalizedHexValues = Self.normalizedConfettiPaletteHexValues(hexValues) else { return false }

        var overrides = self.confettiPaletteOverridesRaw
        overrides[provider.rawValue] = normalizedHexValues
        self.confettiPaletteOverridesRaw = overrides
        return true
    }

    static func normalizedConfettiPaletteHexValues(_ hexValues: [String]) -> [String]? {
        self.confettiPalette(from: hexValues)?.map(\.hexString)
    }

    func resetConfettiPalette(for provider: UsageProvider) {
        var overrides = self.confettiPaletteOverridesRaw
        guard overrides.removeValue(forKey: provider.rawValue) != nil else { return }
        self.confettiPaletteOverridesRaw = overrides
    }

    private static func confettiPalette(from hexValues: [String]) -> [ProviderColor]? {
        let nonEmptyValues = hexValues.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard ProviderBranding.confettiPaletteCountRange.contains(nonEmptyValues.count) else { return nil }

        let colors = nonEmptyValues.compactMap(ProviderColor.init(hexString:))
        guard colors.count == nonEmptyValues.count else { return nil }
        return colors
    }
}

import Foundation

public struct ProviderColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        precondition(hex <= 0xFFFFFF, "Provider colors must use a six-digit RGB hex value.")
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
    }

    public init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6,
              digits.allSatisfy(\.isHexDigit),
              let hex = UInt32(digits, radix: 16)
        else {
            return nil
        }
        self.init(hex: hex)
    }

    public var hexString: String {
        let red = min(max(Int((self.red * 255).rounded()), 0), 255)
        let green = min(max(Int((self.green * 255).rounded()), 0), 255)
        let blue = min(max(Int((self.blue * 255).rounded()), 0), 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

public struct ProviderBranding: Sendable {
    public static let confettiPaletteCountRange = 2...3

    public let iconStyle: IconStyle
    public let iconResourceName: String
    public let color: ProviderColor
    public let confettiPalette: [ProviderColor]

    /// Compatibility fallback for external CodexBarCore clients. Registered provider descriptors must provide
    /// a curated 2–3-color palette through the designated initializer below.
    @available(*, deprecated, message: "Provide a curated 2–3-color confettiPalette.")
    public init(iconStyle: IconStyle, iconResourceName: String, color: ProviderColor) {
        self.init(
            iconStyle: iconStyle,
            iconResourceName: iconResourceName,
            color: color,
            confettiPalette: [color, color])
    }

    public init(
        iconStyle: IconStyle,
        iconResourceName: String,
        color: ProviderColor,
        confettiPalette: [ProviderColor])
    {
        precondition(
            Self.confettiPaletteCountRange.contains(confettiPalette.count),
            "Provider confetti palettes require 2–3 colors.")
        self.iconStyle = iconStyle
        self.iconResourceName = iconResourceName
        self.color = color
        self.confettiPalette = confettiPalette
    }
}

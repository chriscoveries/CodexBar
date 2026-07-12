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
}

public struct ProviderBranding: Sendable {
    public let iconStyle: IconStyle
    public let iconResourceName: String
    public let color: ProviderColor
    public let confettiPalette: [ProviderColor]

    public init(
        iconStyle: IconStyle,
        iconResourceName: String,
        color: ProviderColor,
        confettiPalette: [ProviderColor])
    {
        precondition((2...3).contains(confettiPalette.count), "Provider confetti palettes require 2–3 colors.")
        self.iconStyle = iconStyle
        self.iconResourceName = iconResourceName
        self.color = color
        self.confettiPalette = confettiPalette
    }
}

import CodexBarCore

enum ProviderConfettiPaletteColorValidationStatus: Equatable {
    case valid
    case invalid
    case processing

    static func status(for hexValue: String, isProcessing: Bool) -> Self {
        if isProcessing {
            return .processing
        }
        return ProviderColor(hexString: hexValue) == nil ? .invalid : .valid
    }
}

import Testing
@testable import CodexBar

struct ProviderConfettiPaletteColorValidationStatusTests {
    @Test
    func `palette color validation reports valid invalid and processing states`() {
        #expect(ProviderConfettiPaletteColorValidationStatus.status(for: "#736BD4", isProcessing: false) == .valid)
        #expect(ProviderConfettiPaletteColorValidationStatus.status(for: "97a9f7", isProcessing: false) == .valid)
        #expect(ProviderConfettiPaletteColorValidationStatus.status(for: "#abc", isProcessing: false) == .invalid)
        #expect(ProviderConfettiPaletteColorValidationStatus.status(for: "#736BD4", isProcessing: true) == .processing)
    }
}

import CodexBarCore
import Testing
@testable import CodexBar

struct QoderProviderTests {
    @Test
    func `descriptor metadata is correct`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .qoder)

        #expect(descriptor.metadata.displayName == "Qoder")
        #expect(descriptor.metadata.dashboardURL == "https://qoder.com/account/usage")
        #expect(descriptor.metadata.cliName == "qoder")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-qoder")
        #expect(descriptor.branding.iconStyle == .qoder)
        #expect(!descriptor.metadata.supportsCredits)
        #if os(macOS)
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #else
        #expect(descriptor.metadata.browserCookieOrder == nil)
        #endif
    }

    @MainActor
    @Test
    func `implementation is registered`() {
        #expect(ProviderCatalog.implementation(for: .qoder) != nil)
    }
}

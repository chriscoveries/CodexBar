#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct MiniMaxLinuxTests {
    @Test
    func `configured API key does not require macOS web support`() {
        // The MiniMax API fetch is plain HTTPS + Bearer auth, so a configured API key must
        // be usable off macOS (matches the Factory/Kimi credential exemptions).
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.apiTokenKey: "sk-api-test"]))
    }

    @Test
    func `coding plan API key also skips the web-support gate`() {
        // `config set-api-key --provider minimax` resolves through the same reader, which
        // accepts the coding-plan key as well.
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.codingPlanAPITokenKey: "sk-cp-test"]))
    }

    @Test
    func `auto without an API key still requires web support off macOS`() {
        // Without a credential the only remaining Auto path is the web/cookie one, which
        // genuinely needs macOS — the gate must still fire.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .minimax,
            environment: [:]))
    }

    @Test
    func `explicit web source still requires web support even with an API key`() {
        // The exemption is scoped to Auto; asking for the web source explicitly must not
        // be silently redirected to the API path.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .minimax,
            environment: [MiniMaxAPISettingsReader.apiTokenKey: "sk-api-test"]))
    }
}
#endif

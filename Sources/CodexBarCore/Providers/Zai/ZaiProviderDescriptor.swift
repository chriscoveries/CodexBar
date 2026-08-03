import Foundation

public enum ZaiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zai,
            metadata: ProviderMetadata(
                id: .zai,
                displayName: "z.ai",
                sessionLabel: "Tokens",
                weeklyLabel: "MCP",
                opusLabel: "5-hour",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show z.ai usage",
                cliName: "zai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: ZaiAPIRegion.global.dashboardURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .zai),
                iconResourceName: "ProviderIcon-zai",
                color: ProviderColor(red: 232 / 255, green: 90 / 255, blue: 106 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x126EF6),
                    ProviderColor(hex: 0x2D2D2D),
                    ProviderColor(hex: 0xDFE2E7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "z.ai cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ZaiAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "zai",
                aliases: ["z.ai"],
                versionDetector: nil))
    }
}

struct ZaiAPIFetchStrategy: ProviderFetchStrategy {
    let id = "zai.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport
    private let homeDirectory: URL

    init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    {
        self.transport = transport
        self.homeDirectory = homeDirectory
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ZaiSettingsReader.apiToken(
            for: self.region(context),
            environment: context.env,
            homeDirectory: self.homeDirectory) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let settings = context.settings?.zai
        let region = self.region(context)
        guard let apiKey = ZaiSettingsReader.apiToken(
            for: region,
            environment: context.env,
            homeDirectory: self.homeDirectory)
        else {
            throw ZaiSettingsError.missingToken
        }
        let usage = try await ZaiUsageFetcher.fetchUsageWithModelUsage(
            apiKey: apiKey,
            region: region,
            usageScope: settings?.usageScope,
            teamContext: settings?.teamContext,
            environment: context.env,
            transport: self.transport)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func region(_ context: ProviderFetchContext) -> ZaiAPIRegion {
        context.settings?.zai?.apiRegion ?? .global
    }
}

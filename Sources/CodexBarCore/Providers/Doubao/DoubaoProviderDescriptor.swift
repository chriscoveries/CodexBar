import Foundation

public enum DoubaoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    public static func primaryLabel(window: RateWindow?) -> String? {
        guard window?.windowMinutes == nil,
              window?.resetDescription?.localizedCaseInsensitiveContains("request") == true
        else {
            return nil
        }
        return "Requests"
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .doubao,
            metadata: ProviderMetadata(
                id: .doubao,
                displayName: "Doubao",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Doubao usage",
                cliName: "doubao",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .doubao,
                iconResourceName: "ProviderIcon-doubao",
                color: ProviderColor(red: 51 / 255, green: 112 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Doubao cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [DoubaoAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "doubao",
                aliases: ["volcengine", "ark", "bytedance"],
                versionDetector: nil))
    }
}

struct DoubaoAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.api"
    let kind: ProviderFetchKind = .apiToken
    private let cliUsageLoader: @Sendable () async throws -> DoubaoUsageSnapshot
    private let arkUsageLoader: @Sendable (String) async throws -> DoubaoUsageSnapshot

    init(
        cliUsageLoader: @escaping @Sendable () async throws -> DoubaoUsageSnapshot = {
            try await DoubaoUsageFetcher.fetchCodingPlanUsage()
        },
        arkUsageLoader: @escaping @Sendable (String) async throws -> DoubaoUsageSnapshot = { apiKey in
            try await DoubaoUsageFetcher.fetchUsage(apiKey: apiKey)
        })
    {
        self.cliUsageLoader = cliUsageLoader
        self.arkUsageLoader = arkUsageLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        DoubaoAPIFetchStrategy.arkcliInstalled(environment: context.env) ||
            ProviderTokenResolver.doubaoToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // 1) Try arkcli CLI (SSO-based, no credentials needed).
        // The loader throws quickly if arkcli is not installed.
        do {
            let usage = try await self.cliUsageLoader()
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "cli")
        } catch {
            if Self.isCancellation(error) {
                throw error
            }
            // Fall through to API key probe
        }

        // 2) Fall back to Ark API key probe (rate-limit headers)
        let apiKey = ProviderTokenResolver.doubaoToken(environment: context.env)
        guard let apiKey else {
            throw DoubaoUsageError.missingCredentials
        }
        let usage = try await self.arkUsageLoader(apiKey)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private static func arkcliInstalled(environment: [String: String]) -> Bool {
        if let envPath = environment["ARKCLI_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath)
        {
            return true
        }
        let candidates = ["/usr/local/bin/arkcli", "/opt/homebrew/bin/arkcli"]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

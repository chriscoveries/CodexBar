import Foundation

public enum OpenAIAPIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey,
        apiKeyDebugLabel: OpenAIAPISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.workspaceID(OpenAIAPISettingsReader.projectIDEnvironmentKey)],
        resolve: OpenAIAPISettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple OpenAI API keys.",
            placeholder: "sk-admin-...",
            injection: .environment(key: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentKeysToScrub: [OpenAIAPISettingsReader.projectIDEnvironmentKey]))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openai,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 1),
            metadata: ProviderMetadata(
                id: .openai,
                displayName: "OpenAI",
                sessionLabel: "Spend",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenAI usage",
                cliName: "openai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://platform.openai.com/usage",
                statusPageURL: "https://status.openai.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .openai),
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0.06, green: 0.51, blue: 0.43),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x808080),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 15 / 255, green: 130 / 255, blue: 110 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "OpenAI usage needs an Admin API key for organization usage." },
                menuHintLines: [.literal("Reported by OpenAI Admin API organization usage.")],
                showsCostMenuSection: false),
            pace: .calendarMonthResetWindow,
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                        ? .apiSpend
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        context.snapshot?.openAIAPIUsage.map(ProviderUsageNotesResolution.openAIAPI) ?? .unhandled
                    },
                    costVisibilityResolver: { $0.snapshot?.openAIAPIUsage == nil },
                    usesProviderCostHistoryAsPrimaryDashboard: true,
                    primaryCostHistoryResolver: { snapshot, tokenSnapshot in
                        if let projected = snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot() {
                            return projected
                        }
                        return snapshot == nil ? tokenSnapshot : nil
                    }),
                optionalDetails: ProviderOptionalDetailsPresentation(
                    costSummaryTitles: ["Usage summary"])),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "openai",
                aliases: ["openai-api"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = OpenAIAPIBalanceFetchStrategy()
                // The openai.js plugin conversion cannot attach a spend budget to its snapshot, so
                // when a budget is configured the Admin API strategy is authoritative and the script
                // path is skipped rather than silently dropping the budget-paced window.
                guard ProviderPluginPrototype.isEnabled(environment: context.env),
                      OpenAIAPISettingsReader.monthlyBudgetUSD(environment: context.env) == nil
                else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "openai.js",
                        provider: .openai,
                        bundledPlugin: "openai",
                        secretKey: OpenAIAPISettingsReader.apiKeyEnvironmentKey,
                        resolveValues: { context in
                            guard let credential = OpenAIAPIUsageCredential(environment: context.env)
                            else { return nil }
                            var settings: [String: String] = [:]
                            if let projectID = credential.projectID {
                                settings[OpenAIAPISettingsReader.projectIDEnvironmentKey] = projectID
                            }
                            settings["OPENAI_HISTORY_DAYS"] = String(context.costUsageHistoryDays)
                            settings["OPENAI_ALLOW_BALANCE_FALLBACK"] =
                                credential.allowsLegacyBalanceFallback ? "1" : "0"
                            return ScriptFetchStrategy.Values(
                                settings: settings,
                                secrets: [OpenAIAPISettingsReader.apiKeyEnvironmentKey: credential.apiKey])
                        }),
                    swift,
                ]
            }))
    }
}

struct OpenAIAPIBalanceFetchStrategy: ProviderFetchStrategy {
    let id: String = "openai.api.balance"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (OpenAIAPIUsageCredential, Int) async throws -> OpenAIAPIUsageSnapshot
    let balanceFetcher: @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot

    init(
        usageFetcher: @escaping @Sendable (OpenAIAPIUsageCredential, Int) async throws -> OpenAIAPIUsageSnapshot =
            OpenAIAPIBalanceFetchStrategy.fetchUsage(credential:days:),
        balanceFetcher: @escaping @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot = { apiKey in
            try await OpenAIAPICreditBalanceFetcher.fetchBalance(apiKey: apiKey)
        })
    {
        self.usageFetcher = usageFetcher
        self.balanceFetcher = balanceFetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        OpenAIAPIUsageCredential(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credential = OpenAIAPIUsageCredential(environment: context.env) else {
            throw OpenAIAPISettingsError.missingToken
        }
        // Budget pacing rides the same environment channel as the credential keys: nil keeps the
        // snapshot conversion on its no-pace behavior.
        let budget = OpenAIAPISpendBudget(
            monthlyUSD: OpenAIAPISettingsReader.monthlyBudgetUSD(environment: context.env),
            resetDay: OpenAIAPISettingsReader.budgetResetDay(environment: context.env))

        do {
            let usage = try await self.usageFetcher(
                credential,
                Self.historyDaysForBudgetPace(context: context, budget: budget))
            return self.makeResult(
                usage: usage.toUsageSnapshot(budget: budget),
                sourceLabel: credential.sourceLabel)
        } catch {
            let usageError = error
            if !credential.allowsLegacyBalanceFallback {
                throw usageError
            }
            // Preserve the older balance-only path for unscoped keys and Admin API outages.
            do {
                let balance = try await self.balanceFetcher(credential.apiKey)
                return self.makeResult(
                    usage: balance.toUsageSnapshot(),
                    sourceLabel: "billing-api")
            } catch {
                if (usageError as? OpenAIAPIUsageError)?.isCredentialRejected != true {
                    throw usageError
                }
                throw error
            }
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    /// Month-to-date budget pacing needs a bucket for every day of the elapsed budget period. The
    /// user-configured cost history depth (default 30) can be shorter than that period — a 31-day
    /// cycle starting on the reset day runs out of fetched buckets before `monthToDateSpend` reaches
    /// the period start — which would silently understate the spend and the pace derived from it.
    /// Widen the fetch to cover the whole elapsed period when a budget is configured; without a
    /// budget the history depth is used unchanged. The fetcher clamps the depth to its own maximum.
    private static func historyDaysForBudgetPace(
        context: ProviderFetchContext,
        budget: OpenAIAPISpendBudget?,
        now: Date = Date()) -> Int
    {
        guard let budget else { return context.costUsageHistoryDays }
        let calendar = Calendar.current
        let periodStart = budget.periodStart(containing: now, calendar: calendar)
        let elapsedDays = (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: periodStart),
            to: calendar.startOfDay(for: now)).day ?? 0) + 1
        return max(context.costUsageHistoryDays, elapsedDays)
    }

    private static func fetchUsage(
        credential: OpenAIAPIUsageCredential,
        days: Int) async throws -> OpenAIAPIUsageSnapshot
    {
        try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: credential.apiKey,
            projectID: credential.projectID,
            historyDays: days)
    }
}

struct OpenAIAPIUsageCredential: Equatable {
    let apiKey: String
    let projectID: String?
    let usesAdminKey: Bool

    init?(environment: [String: String]) {
        if let adminKey = OpenAIAPISettingsReader.adminAPIKey(environment: environment) {
            self.apiKey = adminKey
            self.usesAdminKey = true
        } else if let apiKey = OpenAIAPISettingsReader.apiKey(environment: environment) {
            self.apiKey = apiKey
            self.usesAdminKey = false
        } else {
            return nil
        }
        self.projectID = OpenAIAPISettingsReader.projectID(environment: environment)
    }

    var sourceLabel: String {
        self.projectID == nil ? "admin-api" : "admin-api:project"
    }

    var allowsLegacyBalanceFallback: Bool {
        self.projectID == nil || !self.usesAdminKey
    }
}

extension OpenAIAPISettingsReader {
    // Budget pacing rides the same environment channel as the credential keys: the app projects
    // its SettingsStore values into the fetch environment (see `ProviderRegistry.makeEnvironment`,
    // alongside the OPENAI_ADMIN_KEY/OPENAI_PROJECT_ID projections) and the Admin API strategy
    // reads them back from `ProviderFetchContext.env`.
    public static let monthlyBudgetUSDEnvironmentKey = "OPENAI_MONTHLY_BUDGET_USD"
    public static let budgetResetDayEnvironmentKey = "OPENAI_BUDGET_RESET_DAY"

    public static func monthlyBudgetUSD(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Double?
    {
        guard let raw = self.cleaned(environment[self.monthlyBudgetUSDEnvironmentKey]),
              let budget = Double(raw),
              budget.isFinite,
              budget > 0
        else { return nil }
        return budget
    }

    public static func budgetResetDay(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Int?
    {
        guard let raw = self.cleaned(environment[self.budgetResetDayEnvironmentKey]),
              let day = Int(raw)
        else { return nil }
        return OpenAIAPISpendBudget.sanitizedResetDay(day)
    }
}

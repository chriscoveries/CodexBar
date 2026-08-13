#if os(macOS)
import Foundation

extension OpenAIDashboardFetcher {
    struct ReturnableDashboardDataInput {
        let codeReview: Double?
        let events: [CreditEvent]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let hasUsageLimits: Bool
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
    }

    nonisolated static func hasReturnableDashboardData(_ input: ReturnableDashboardDataInput) -> Bool {
        input.codeReview != nil
            || !input.events.isEmpty
            || !input.usageBreakdown.isEmpty
            || input.hasUsageLimits
            || input.creditsRemaining != nil
            || input.codexCreditLimit != nil
    }

    nonisolated static func hasAnyDashboardSignal(
        hasReturnableData: Bool,
        creditsHeaderPresent: Bool) -> Bool
    {
        hasReturnableData || creditsHeaderPresent
    }

    /// Skip the hidden ChatGPT WebView unless the caller asked for a DOM scrape.
    nonisolated static func shouldSkipPageScrape(allowPageScrape: Bool) -> Bool {
        !allowPageScrape
    }

    nonisolated static func snapshotByMergingAPI(
        apiData: DashboardAPIData,
        verifiedEmail: String,
        subscription: OpenAISubscriptionMetadata?,
        previous: OpenAIDashboardSnapshot?,
        updatedAt: Date = Date()) -> OpenAIDashboardSnapshot
    {
        let email = verifiedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIDashboardSnapshot(
            signedInEmail: email.isEmpty ? previous?.signedInEmail : email,
            codeReviewRemainingPercent: previous?.codeReviewRemainingPercent,
            codeReviewLimit: previous?.codeReviewLimit,
            creditEvents: previous?.creditEvents ?? [],
            dailyBreakdown: previous?.dailyBreakdown ?? [],
            usageBreakdown: previous?.usageBreakdown ?? [],
            creditsPurchaseURL: previous?.creditsPurchaseURL,
            primaryLimit: apiData.primaryLimit ?? previous?.primaryLimit,
            secondaryLimit: apiData.secondaryLimit ?? previous?.secondaryLimit,
            extraRateWindows: apiData.extraRateWindows.isEmpty
                ? previous?.extraRateWindows
                : apiData.extraRateWindows,
            creditsRemaining: apiData.creditsRemaining ?? previous?.creditsRemaining,
            codexCreditLimit: apiData.codexCreditLimit ?? previous?.codexCreditLimit,
            accountPlan: apiData.accountPlan ?? previous?.accountPlan,
            subscriptionExpiresAt: subscription?.expiresAt ?? previous?.subscriptionExpiresAt,
            subscriptionRenewsAt: subscription?.renewsAt ?? previous?.subscriptionRenewsAt,
            updatedAt: updatedAt)
    }

    nonisolated static func fillingMissingPageFields(
        _ snapshot: OpenAIDashboardSnapshot,
        from previous: OpenAIDashboardSnapshot?) -> OpenAIDashboardSnapshot
    {
        guard let previous else { return snapshot }
        return OpenAIDashboardSnapshot(
            signedInEmail: snapshot.signedInEmail ?? previous.signedInEmail,
            codeReviewRemainingPercent: snapshot.codeReviewRemainingPercent
                ?? previous.codeReviewRemainingPercent,
            codeReviewLimit: snapshot.codeReviewLimit ?? previous.codeReviewLimit,
            creditEvents: snapshot.creditEvents.isEmpty ? previous.creditEvents : snapshot.creditEvents,
            dailyBreakdown: snapshot.dailyBreakdown.isEmpty ? previous.dailyBreakdown : snapshot.dailyBreakdown,
            usageBreakdown: snapshot.usageBreakdown.isEmpty ? previous.usageBreakdown : snapshot.usageBreakdown,
            creditsPurchaseURL: snapshot.creditsPurchaseURL ?? previous.creditsPurchaseURL,
            primaryLimit: snapshot.primaryLimit ?? previous.primaryLimit,
            secondaryLimit: snapshot.secondaryLimit ?? previous.secondaryLimit,
            extraRateWindows: snapshot.extraRateWindows ?? previous.extraRateWindows,
            creditsRemaining: snapshot.creditsRemaining ?? previous.creditsRemaining,
            codexCreditLimit: snapshot.codexCreditLimit ?? previous.codexCreditLimit,
            accountPlan: snapshot.accountPlan ?? previous.accountPlan,
            subscriptionExpiresAt: snapshot.subscriptionExpiresAt ?? previous.subscriptionExpiresAt,
            subscriptionRenewsAt: snapshot.subscriptionRenewsAt ?? previous.subscriptionRenewsAt,
            updatedAt: snapshot.updatedAt)
    }
}
#endif

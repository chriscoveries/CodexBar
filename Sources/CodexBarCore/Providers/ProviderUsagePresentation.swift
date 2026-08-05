import Foundation

public struct ProviderRateWindowLabels: Sendable, Equatable {
    public let primary: String
    public let secondary: String
    public let tertiary: String
    public let showsTertiary: Bool

    public init(primary: String, secondary: String, tertiary: String, showsTertiary: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.showsTertiary = showsTertiary
    }
}

public struct ProviderIdentityPresentation: Sendable, Equatable {
    public struct Detail: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public let badge: String?
    public let plan: String?
    public let details: [Detail]

    public init(badge: String?, plan: String?, details: [Detail] = []) {
        self.badge = badge
        self.plan = plan
        self.details = details
    }
}

public struct ProviderCostPresentation: Sendable, Equatable {
    public struct Balance: Sendable, Equatable {
        public let label: String
        public let amount: Double
        public let currencyCode: String

        public init(label: String, amount: Double, currencyCode: String) {
            self.label = label
            self.amount = amount
            self.currencyCode = currencyCode
        }
    }

    public let showsGenericFallback: Bool
    public let balances: [Balance]

    public init(showsGenericFallback: Bool = true, balances: [Balance] = []) {
        self.showsGenericFallback = showsGenericFallback
        self.balances = balances
    }
}

public struct ProviderUsagePresentation: Sendable {
    public typealias RateWindowLabeler = @Sendable (
        _ metadata: ProviderMetadata,
        _ snapshot: UsageSnapshot,
        _ now: Date) -> ProviderRateWindowLabels
    public typealias IdentityPresenter = @Sendable (
        _ provider: UsageProvider,
        _ snapshot: UsageSnapshot) -> ProviderIdentityPresentation
    public typealias CostPresenter = @Sendable (_ snapshot: UsageSnapshot) -> ProviderCostPresentation
    public typealias ExtraRateWindowSelector = @Sendable (_ snapshot: UsageSnapshot) -> [NamedRateWindow]
    public typealias CreditResolver = @Sendable (_ credits: CreditsSnapshot) -> Double?

    private let rateWindowLabeler: RateWindowLabeler?
    private let identityPresenter: IdentityPresenter?
    private let costPresenter: CostPresenter
    private let extraRateWindowSelector: ExtraRateWindowSelector
    private let creditResolver: CreditResolver?

    public init(
        rateWindowLabeler: RateWindowLabeler? = nil,
        identityPresenter: IdentityPresenter? = nil,
        costPresenter: @escaping CostPresenter = { _ in ProviderCostPresentation() },
        extraRateWindowSelector: @escaping ExtraRateWindowSelector = { _ in [] },
        creditResolver: CreditResolver? = nil)
    {
        self.rateWindowLabeler = rateWindowLabeler
        self.identityPresenter = identityPresenter
        self.costPresenter = costPresenter
        self.extraRateWindowSelector = extraRateWindowSelector
        self.creditResolver = creditResolver
    }

    public func rateWindowLabels(
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot,
        now: Date = .now) -> ProviderRateWindowLabels
    {
        self.rateWindowLabeler?(metadata, snapshot, now) ?? ProviderRateWindowLabels(
            primary: metadata.sessionLabel,
            secondary: metadata.weeklyLabel,
            tertiary: metadata.opusLabel ?? "Sonnet",
            showsTertiary: metadata.supportsOpus)
    }

    public func identity(provider: UsageProvider, snapshot: UsageSnapshot) -> ProviderIdentityPresentation {
        if let identityPresenter {
            return identityPresenter(provider, snapshot)
        }
        guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
            return ProviderIdentityPresentation(badge: nil, plan: nil)
        }
        let display = plan.capitalized
        return ProviderIdentityPresentation(badge: display, plan: display)
    }

    public func cost(snapshot: UsageSnapshot) -> ProviderCostPresentation {
        self.costPresenter(snapshot)
    }

    public func extraRateWindows(snapshot: UsageSnapshot) -> [NamedRateWindow] {
        self.extraRateWindowSelector(snapshot)
    }

    public func creditRemaining(_ credits: CreditsSnapshot) -> Double? {
        self.creditResolver?(credits)
    }
}

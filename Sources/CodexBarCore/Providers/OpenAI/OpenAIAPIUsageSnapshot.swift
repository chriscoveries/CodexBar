import Foundation

/// User-configured monthly spend budget backing the OpenAI Admin API pace bar. OpenAI reports no
/// quota lanes, so pace is budget-based: actual metered spend fills a synthetic monthly window
/// that resets on the configured day of month.
public struct OpenAIAPISpendBudget: Equatable, Sendable {
    public static let minResetDay = 1
    public static let maxResetDay = 28
    public static let defaultResetDay = 1

    public let monthlyUSD: Double
    public let resetDay: Int

    /// Fails when the budget is missing or unusable (non-finite, non-positive), which keeps the
    /// provider on its no-pace behavior instead of surfacing a broken window.
    public init?(monthlyUSD: Double?, resetDay: Int? = nil) {
        guard let monthlyUSD, monthlyUSD.isFinite, monthlyUSD > 0 else { return nil }
        self.monthlyUSD = monthlyUSD
        self.resetDay = Self.sanitizedResetDay(resetDay)
    }

    public static func sanitizedResetDay(_ raw: Int?) -> Int {
        guard let raw else { return Self.defaultResetDay }
        return max(Self.minResetDay, min(Self.maxResetDay, raw))
    }

    /// Start of the budget period containing `date`: the most recent occurrence of the reset day
    /// (local midnight) on or before `date`.
    public func periodStart(containing date: Date, calendar: Calendar) -> Date {
        let candidate = self.resetDayCandidate(onOrBefore: date, calendar: calendar)
        guard candidate > date else { return candidate }
        return calendar.date(byAdding: .month, value: -1, to: candidate) ?? candidate
    }

    /// Next budget reset: the first occurrence of the reset day (local midnight) after `date`.
    public func nextReset(from date: Date, calendar: Calendar) -> Date {
        let candidate = self.resetDayCandidate(onOrBefore: date, calendar: calendar)
        guard candidate > date else {
            return calendar.date(byAdding: .month, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    /// Budget pace window for `spendUSD`: percent of the monthly budget (clamped at 100), the
    /// monthly sentinel duration matched by the reset-window pace rules, and the next reset-day
    /// occurrence. The window is a real user-configured lane driven by metered spend, so it is
    /// deliberately NOT `isSyntheticPlaceholder` — that flag means "no lane present" and would
    /// hide the window from the menu bar, widget, and warning surfaces; estimation is conveyed
    /// via `UsageSnapshot.dataConfidence` instead.
    public func rateWindow(spendUSD: Double, now: Date, calendar: Calendar) -> RateWindow {
        let spend = spendUSD.isFinite ? max(0, spendUSD) : 0
        return RateWindow(
            usedPercent: min(spend / self.monthlyUSD * 100, 100),
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: self.nextReset(from: now, calendar: calendar),
            resetDescription: nil,
            nextRegenPercent: nil)
    }

    private func resetDayCandidate(onOrBefore date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = self.resetDay
        return calendar.date(from: components) ?? date
    }
}

public struct OpenAIAPIUsageSnapshot: Codable, Equatable, Sendable {
    public struct DailyBucket: Codable, Equatable, Sendable, Identifiable {
        public let day: String
        public let startTime: Date
        public let endTime: Date
        public let costUSD: Double
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let lineItems: [LineItemBreakdown]
        public let models: [ModelBreakdown]

        public var id: String {
            self.day
        }

        public init(
            day: String,
            startTime: Date,
            endTime: Date,
            costUSD: Double,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int,
            lineItems: [LineItemBreakdown],
            models: [ModelBreakdown])
        {
            self.day = day
            self.startTime = startTime
            self.endTime = endTime
            self.costUSD = costUSD
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.lineItems = lineItems
            self.models = models
        }
    }

    public struct LineItemBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let costUSD: Double

        public var id: String {
            self.name
        }

        public init(name: String, costUSD: Double) {
            self.name = name
            self.costUSD = costUSD
        }
    }

    public struct ModelBreakdown: Codable, Equatable, Sendable, Identifiable {
        public let name: String
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int

        public var id: String {
            self.name
        }

        public init(
            name: String,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int)
        {
            self.name = name
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public struct Summary: Equatable, Sendable {
        public let costUSD: Double
        public let requests: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int

        public init(
            costUSD: Double,
            requests: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            totalTokens: Int)
        {
            self.costUSD = costUSD
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public let daily: [DailyBucket]
    public let updatedAt: Date
    public let historyDays: Int
    public let projectID: String?

    public init(daily: [DailyBucket], updatedAt: Date, historyDays: Int = 30, projectID: String? = nil) {
        self.daily = daily.sorted { $0.startTime < $1.startTime }
        self.updatedAt = updatedAt
        self.historyDays = max(1, min(365, historyDays))
        self.projectID = OpenAIAPISettingsReader.cleaned(projectID)
    }

    public var last30Days: Summary {
        self.historyDays == 1 ? self.currentDay : self.summary(days: self.historyDays)
    }

    public var historyWindowLabel: String {
        self.historyDays == 1 ? "Today" : "\(self.historyDays)d"
    }

    public var historyWindowPeriodLabel: String {
        self.historyDays == 1 ? "Today" : "Last \(self.historyDays) days"
    }

    public var last7Days: Summary {
        self.summary(days: 7)
    }

    public var currentDay: Summary {
        self.summary(forLocalDayContaining: self.updatedAt)
    }

    public var latestDay: Summary {
        self.summary(days: 1)
    }

    public func summary(forLocalDayContaining date: Date, calendar _: Calendar = .current) -> Summary {
        let selected = self.daily.filter { bucket in
            CostUsageBucketInterval.contains(
                date,
                startTime: bucket.startTime,
                endTime: bucket.endTime)
        }
        return Summary(
            costUSD: selected.reduce(0) { $0 + $1.costUSD },
            requests: selected.reduce(0) { $0 + $1.requests },
            inputTokens: selected.reduce(0) { $0 + $1.inputTokens },
            cachedInputTokens: selected.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: selected.reduce(0) { $0 + $1.outputTokens },
            totalTokens: selected.reduce(0) { $0 + $1.totalTokens })
    }

    public func summary(days: Int) -> Summary {
        let selected = self.daily.suffix(max(1, days))
        return Summary(
            costUSD: selected.reduce(0) { $0 + $1.costUSD },
            requests: selected.reduce(0) { $0 + $1.requests },
            inputTokens: selected.reduce(0) { $0 + $1.inputTokens },
            cachedInputTokens: selected.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: selected.reduce(0) { $0 + $1.outputTokens },
            totalTokens: selected.reduce(0) { $0 + $1.totalTokens })
    }

    public var topModels: [ModelBreakdown] {
        var totals: [String: ModelAccumulator] = [:]
        for day in self.daily {
            for model in day.models {
                totals[model.name, default: ModelAccumulator()].add(model)
            }
        }
        return totals
            .map { name, total in total.makeModel(name: name) }
            .sorted {
                if $0.totalTokens == $1.totalTokens {
                    return $0.name < $1.name
                }
                return $0.totalTokens > $1.totalTokens
            }
    }

    public var topLineItems: [LineItemBreakdown] {
        var totals: [String: Double] = [:]
        for day in self.daily {
            for item in day.lineItems {
                totals[item.name, default: 0] += item.costUSD
            }
        }
        return totals
            .map { LineItemBreakdown(name: $0.key, costUSD: $0.value) }
            .sorted {
                if $0.costUSD == $1.costUSD {
                    return $0.name < $1.name
                }
                return $0.costUSD > $1.costUSD
            }
    }

    public func toUsageSnapshot(
        budget: OpenAIAPISpendBudget? = nil,
        now: Date = Date(),
        calendar: Calendar = .current) -> UsageSnapshot
    {
        let total = self.last30Days
        // Without a budget the snapshot stays exactly as before: no window, no pace, default
        // confidence. With one, metered spend since the reset day fills a synthetic monthly lane.
        let primary = budget.map { activeBudget in
            activeBudget.rateWindow(
                spendUSD: self.monthToDateSpend(budget: activeBudget, now: now, calendar: calendar),
                now: now,
                calendar: calendar)
        }
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: total.costUSD,
                limit: 0,
                currencyCode: "USD",
                period: self.historyWindowPeriodLabel,
                updatedAt: self.updatedAt),
            openAIAPIUsage: self,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .openai,
                accountEmail: nil,
                accountOrganization: self.identityAccountOrganization,
                loginMethod: self.identityLoginMethod),
            dataConfidence: primary == nil ? .unknown : .estimated)
    }

    /// Spend accumulated since the budget period began. Admin API costs are daily-aggregated, so a
    /// bucket straddling the reset-day boundary contributes its full metered cost.
    public func monthToDateSpend(
        budget: OpenAIAPISpendBudget,
        now: Date = Date(),
        calendar: Calendar = .current) -> Double
    {
        let periodStart = budget.periodStart(containing: now, calendar: calendar)
        return self.daily
            .filter { $0.endTime > periodStart && $0.startTime <= now }
            .reduce(0) { $0 + $1.costUSD }
    }

    private var identityLoginMethod: String {
        guard let projectID else { return "Admin API" }
        return "Admin API: \(projectID)"
    }

    private var identityAccountOrganization: String? {
        guard let projectID else { return nil }
        return "Project: \(projectID)"
    }

    public func toCostUsageTokenSnapshot() -> CostUsageTokenSnapshot {
        let daily = self.daily.map { bucket in
            let modelBreakdowns = bucket.models.map {
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0.name,
                    costUSD: nil,
                    totalTokens: $0.totalTokens,
                    requestCount: $0.requests)
            }
            let modelsUsed = bucket.models.map(\.name)
            return CostUsageDailyReport.Entry(
                date: bucket.day,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cachedInputTokens,
                cacheCreationTokens: nil,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.requests,
                costUSD: bucket.costUSD,
                modelsUsed: modelsUsed.isEmpty ? nil : modelsUsed,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        let today = self.currentDay
        let total = self.last30Days
        return CostUsageTokenSnapshot(
            sessionTokens: today.totalTokens,
            sessionCostUSD: today.costUSD,
            sessionRequests: today.requests,
            last30DaysTokens: total.totalTokens,
            last30DaysCostUSD: total.costUSD,
            last30DaysRequests: total.requests,
            historyDays: self.historyDays,
            costProvenance: .vendorMetered,
            daily: daily,
            updatedAt: self.updatedAt)
    }

    private struct ModelAccumulator {
        var requests = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var totalTokens = 0

        mutating func add(_ model: ModelBreakdown) {
            self.requests += model.requests
            self.inputTokens += model.inputTokens
            self.cachedInputTokens += model.cachedInputTokens
            self.outputTokens += model.outputTokens
            self.totalTokens += model.totalTokens
        }

        func makeModel(name: String) -> ModelBreakdown {
            ModelBreakdown(
                name: name,
                requests: self.requests,
                inputTokens: self.inputTokens,
                cachedInputTokens: self.cachedInputTokens,
                outputTokens: self.outputTokens,
                totalTokens: self.totalTokens)
        }
    }
}

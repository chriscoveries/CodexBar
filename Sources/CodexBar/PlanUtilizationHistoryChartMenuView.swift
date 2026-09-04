import CodexBarCore
import SwiftUI

@MainActor
struct PlanUtilizationHistoryChartMenuView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 130
        static let detailHeight: CGFloat = 16
        static let emptyStateHeight: CGFloat = chartHeight + detailHeight
        static let maxPoints = 30
        static let maxAxisLabels = 4
    }

    private struct SeriesSelection: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int

        var id: String {
            "\(self.name.rawValue):\(self.windowMinutes)"
        }
    }

    private struct VisibleSeries: Identifiable, Equatable {
        let selection: SeriesSelection
        let title: String
        let history: PlanUtilizationSeriesHistory

        var id: String {
            self.selection.id
        }
    }

    private struct EntryPointAccumulator {
        let effectiveBoundaryDate: Date
        let displayBoundaryDate: Date
        let observedAt: Date
        let usedPercent: Double
        let hasObservedResetBoundary: Bool
    }

    private struct ResetBoundaryLattice {
        let referenceBoundaryDate: Date
        let windowInterval: TimeInterval
    }

    private struct Point: Identifiable {
        let id: Date
        let index: Int
        let date: Date
        let usedPercent: Double
        let isObserved: Bool
    }

    private struct Model {
        let points: [Point]
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let pointsByID: [Date: Point]
        let pointsByIndex: [Int: Point]
        let barColor: Color
    }

    private let provider: UsageProvider
    private let visibleSeries: [VisibleSeries]
    private let paceModelsBySeriesID: [String: PlanUtilizationPaceChartModel]
    private let referenceDate: Date
    private let width: CGFloat

    @AppStorage("planUsageChartSeriesID") private var storedSeriesID = ""
    @State private var selectedSeriesID: String?

    private var defaultSelectedSeriesID: String? {
        Self.defaultSelectedSeriesID(storedSeriesID: self.storedSeriesID, in: self.visibleSeries)
    }

    init(
        provider: UsageProvider,
        histories: [PlanUtilizationSeriesHistory],
        snapshot: UsageSnapshot? = nil,
        width: CGFloat)
    {
        self.provider = provider
        let visibleSeries = Self.visibleSeries(
            histories: histories,
            provider: provider,
            snapshot: snapshot)
        let referenceDate = Date()
        self.visibleSeries = visibleSeries
        self.paceModelsBySeriesID = Dictionary(uniqueKeysWithValues: visibleSeries.compactMap { series in
            guard let currentWindow = Self.currentWindow(
                for: series,
                provider: provider,
                snapshot: snapshot)
            else {
                return nil
            }
            guard let model = PlanUtilizationPaceChartModel(
                history: series.history,
                currentWindow: currentWindow,
                referenceDate: referenceDate,
                currentWindowCapturedAt: snapshot?.updatedAt)
            else {
                return nil
            }
            return (series.id, model)
        })
        self.referenceDate = referenceDate
        self.width = width
    }

    var body: some View {
        let effectiveSelectedSeries = self.visibleSeries.first(where: { $0.id == self.selectedSeriesID })
            ?? self.visibleSeries.first
        let paceModel = effectiveSelectedSeries.flatMap { self.paceModelsBySeriesID[$0.id] }

        VStack(alignment: .leading, spacing: 10) {
            if self.visibleSeries.count > 1 {
                Picker(selection: Binding(
                    get: { effectiveSelectedSeries?.id ?? "" },
                    set: { newValue in
                        self.selectedSeriesID = newValue
                        self.storedSeriesID = newValue
                    })) {
                        ForEach(self.visibleSeries) { series in
                            Text(series.title).tag(series.id)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                        .pickerStyle(.segmented)
            }

            if let paceModel {
                PlanUtilizationPaceChartView(
                    provider: self.provider,
                    windowTitle: effectiveSelectedSeries?.title ?? L("Usage"),
                    model: paceModel,
                    currentDate: self.referenceDate,
                    width: self.width)
            } else {
                ZStack {
                    Text(Self.emptyStateText(title: effectiveSelectedSeries?.title))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.emptyStateHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .task(id: self.visibleSeries.map(\.id).joined(separator: ",")) {
            guard !self.visibleSeries.contains(where: { $0.id == self.selectedSeriesID }) else { return }
            guard let restoredSeriesID = self.defaultSelectedSeriesID else { return }
            self.selectedSeriesID = restoredSeriesID
        }
    }

    private nonisolated static func visibleSeries(
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> [VisibleSeries]
    {
        let metadata = ProviderDescriptorRegistry.metadata[provider]
        let allowedNames = self.visibleSeriesNames(provider: provider, snapshot: snapshot)
        var historiesBySelection: [SeriesSelection: PlanUtilizationSeriesHistory] = [:]
        for history in histories {
            guard !history.entries.isEmpty else { continue }
            guard history.windowMinutes > 0 else { continue }
            let effectiveName = Self.effectiveSeriesName(provider: provider, history: history)
            guard Self.displayableSeriesNames.contains(effectiveName) else { continue }
            guard allowedNames?.contains(effectiveName) ?? true else { continue }

            let canonicalWindowMinutes = effectiveName.canonicalWindowMinutes(history.windowMinutes)
            let selection = SeriesSelection(name: effectiveName, windowMinutes: canonicalWindowMinutes)
            if let existingHistory = historiesBySelection[selection] {
                historiesBySelection[selection] = PlanUtilizationSeriesHistory(
                    name: effectiveName,
                    windowMinutes: canonicalWindowMinutes,
                    entries: Self.mergedEntries(existingHistory.entries + history.entries))
            } else {
                historiesBySelection[selection] = PlanUtilizationSeriesHistory(
                    name: effectiveName,
                    windowMinutes: canonicalWindowMinutes,
                    entries: history.entries)
            }
        }

        return historiesBySelection.values
            .sorted { lhs, rhs in
                let lhsOrder = self.seriesSortOrder(lhs.name)
                let rhsOrder = self.seriesSortOrder(rhs.name)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                if lhs.windowMinutes != rhs.windowMinutes {
                    return lhs.windowMinutes < rhs.windowMinutes
                }
                return lhs.name.rawValue < rhs.name.rawValue
            }
            .map { history in
                VisibleSeries(
                    selection: SeriesSelection(name: history.name, windowMinutes: history.windowMinutes),
                    title: self.seriesTitle(
                        name: history.name,
                        metadata: metadata,
                        windowMinutes: history.windowMinutes),
                    history: history)
            }
    }

    /// Histories recorded before duration-based classification stored a 43,200-minute Codex window
    /// under its payload slot (session for primary, weekly for secondary). Fold those into the
    /// monthly series so the chart does not split or hide the window's history.
    private nonisolated static func effectiveSeriesName(
        provider: UsageProvider,
        history: PlanUtilizationSeriesHistory) -> PlanUtilizationSeriesName
    {
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let normalized = presentation.normalizePlanUtilizationSeries(
            self.providerSeries(history.name),
            windowMinutes: history.windowMinutes)
        return self.historySeries(normalized)
    }

    nonisolated static func mergedEntries(
        _ entries: [PlanUtilizationHistoryEntry]) -> [PlanUtilizationHistoryEntry]
    {
        var seen: Set<PlanUtilizationHistoryEntry> = []
        return entries.filter { entry in
            seen.insert(entry).inserted
        }
    }

    private nonisolated static func visibleSeriesNames(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> Set<PlanUtilizationSeriesName>?
    {
        guard let snapshot else { return nil }

        return ProviderDescriptorRegistry.descriptor(for: provider).presentation
            .planUtilizationSeries(snapshot: snapshot)
            .map { Set($0.map(self.historySeries)) }
    }

    private nonisolated static func providerSeries(
        _ series: PlanUtilizationSeriesName) -> ProviderPlanUtilizationSeries
    {
        switch series {
        case .session: .session
        case .weekly: .weekly
        case .opus: .tertiary
        case .monthly: .monthly
        default: .weekly
        }
    }

    private nonisolated static func historySeries(
        _ series: ProviderPlanUtilizationSeries) -> PlanUtilizationSeriesName
    {
        switch series {
        case .session: .session
        case .weekly: .weekly
        case .tertiary: .opus
        case .monthly: .monthly
        }
    }

    private nonisolated static func makeModel(
        history: PlanUtilizationSeriesHistory?,
        provider: UsageProvider,
        referenceDate: Date) -> Model
    {
        guard let history else {
            return self.emptyModel(provider: provider)
        }

        var points = self.seriesPoints(history: history, referenceDate: referenceDate)
        if points.count > Layout.maxPoints {
            points = Array(points.suffix(Layout.maxPoints))
        }

        points = points.enumerated().map { offset, point in
            Point(
                id: point.id,
                index: offset,
                date: point.date,
                usedPercent: point.usedPercent,
                isObserved: point.isObserved)
        }

        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let pointsByIndex = Dictionary(uniqueKeysWithValues: points.map { ($0.index, $0) })
        let color = ProviderAccentPalette.color(for: provider)
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)

        return Model(
            points: points,
            axisIndexes: self.axisIndexes(points: points, windowMinutes: history.windowMinutes),
            xDomain: self.xDomain(points: points),
            pointsByID: pointsByID,
            pointsByIndex: pointsByIndex,
            barColor: barColor)
    }

    private nonisolated static func emptyModel(provider: UsageProvider) -> Model {
        let color = ProviderAccentPalette.color(for: provider)
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)
        return Model(
            points: [],
            axisIndexes: [],
            xDomain: nil,
            pointsByID: [:],
            pointsByIndex: [:],
            barColor: barColor)
    }

    private nonisolated static func seriesPoints(
        history: PlanUtilizationSeriesHistory,
        referenceDate: Date) -> [Point]
    {
        guard history.windowMinutes > 0 else { return [] }
        let windowInterval = Double(history.windowMinutes) * 60
        let resetBoundaryLattice = self.resetBoundaryLattice(
            entries: history.entries,
            windowMinutes: history.windowMinutes)
        var strongestObservedPointByPeriod: [Date: EntryPointAccumulator] = [:]

        for entry in history.entries {
            let candidate = self.observedPointCandidate(
                for: entry,
                windowMinutes: history.windowMinutes,
                resetBoundaryLattice: resetBoundaryLattice)

            if let existing = strongestObservedPointByPeriod[candidate.effectiveBoundaryDate],
               !self.shouldPreferObservedPoint(candidate, over: existing)
            {
                continue
            }
            strongestObservedPointByPeriod[candidate.effectiveBoundaryDate] = candidate
        }

        guard !strongestObservedPointByPeriod.isEmpty else { return [] }

        let sortedPeriodBoundaryDates = strongestObservedPointByPeriod.keys.sorted()
        var points: [Point] = []
        var previousPeriodBoundaryDate: Date?

        for periodBoundaryDate in sortedPeriodBoundaryDates {
            if let previousPeriodBoundaryDate {
                var cursor = previousPeriodBoundaryDate.addingTimeInterval(windowInterval)
                while cursor < periodBoundaryDate {
                    points.append(Point(
                        id: cursor,
                        index: 0,
                        date: cursor,
                        usedPercent: 0,
                        isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }

            if let bucket = strongestObservedPointByPeriod[periodBoundaryDate] {
                points.append(Point(
                    id: bucket.effectiveBoundaryDate,
                    index: 0,
                    date: bucket.displayBoundaryDate,
                    usedPercent: bucket.usedPercent,
                    isObserved: true))
            }
            previousPeriodBoundaryDate = periodBoundaryDate
        }

        if let lastObservedPeriodBoundaryDate = sortedPeriodBoundaryDates.last {
            let currentPeriodBoundaryDate = self.currentPeriodBoundaryDate(
                for: referenceDate,
                windowMinutes: history.windowMinutes,
                resetBoundaryLattice: resetBoundaryLattice)

            if currentPeriodBoundaryDate > lastObservedPeriodBoundaryDate {
                var cursor = lastObservedPeriodBoundaryDate.addingTimeInterval(windowInterval)
                while cursor <= currentPeriodBoundaryDate {
                    points.append(Point(
                        id: cursor,
                        index: 0,
                        date: cursor,
                        usedPercent: 0,
                        isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }
        }

        return points
    }

    private nonisolated static func observedPointCandidate(
        for entry: PlanUtilizationHistoryEntry,
        windowMinutes: Int,
        resetBoundaryLattice: ResetBoundaryLattice?) -> EntryPointAccumulator
    {
        let rawResetBoundaryDate = entry.resetsAt.map(self.normalizedBoundaryDate)
        let effectiveBoundaryDate = self.effectivePeriodBoundaryDate(
            for: entry,
            windowMinutes: windowMinutes,
            rawResetBoundaryDate: rawResetBoundaryDate,
            resetBoundaryLattice: resetBoundaryLattice)
        return EntryPointAccumulator(
            effectiveBoundaryDate: effectiveBoundaryDate,
            displayBoundaryDate: rawResetBoundaryDate ?? effectiveBoundaryDate,
            observedAt: entry.capturedAt,
            usedPercent: max(0, min(100, entry.usedPercent)),
            hasObservedResetBoundary: rawResetBoundaryDate != nil)
    }

    private nonisolated static func resetBoundaryLattice(
        entries: [PlanUtilizationHistoryEntry],
        windowMinutes: Int) -> ResetBoundaryLattice?
    {
        guard let latestObservedResetBoundaryDate = entries
            .compactMap(\.resetsAt)
            .map(self.normalizedBoundaryDate)
            .max()
        else {
            return nil
        }
        return ResetBoundaryLattice(
            referenceBoundaryDate: latestObservedResetBoundaryDate,
            windowInterval: Double(windowMinutes) * 60)
    }

    private nonisolated static func normalizedBoundaryDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private nonisolated static func effectivePeriodBoundaryDate(
        for entry: PlanUtilizationHistoryEntry,
        windowMinutes: Int,
        rawResetBoundaryDate: Date?,
        resetBoundaryLattice: ResetBoundaryLattice?) -> Date
    {
        if let rawResetBoundaryDate {
            if let resetBoundaryLattice {
                return self.closestPeriodBoundaryDate(
                    to: rawResetBoundaryDate,
                    resetBoundaryLattice: resetBoundaryLattice)
            }
            return rawResetBoundaryDate
        }
        if let resetBoundaryLattice {
            return self.periodBoundaryDate(
                containing: entry.capturedAt,
                resetBoundaryLattice: resetBoundaryLattice)
        }
        return self.syntheticBoundaryDate(for: entry.capturedAt, windowMinutes: windowMinutes)
    }

    private nonisolated static func shouldPreferObservedPoint(
        _ candidate: EntryPointAccumulator,
        over existing: EntryPointAccumulator) -> Bool
    {
        if candidate.usedPercent != existing.usedPercent {
            return candidate.usedPercent > existing.usedPercent
        }
        if candidate.hasObservedResetBoundary != existing.hasObservedResetBoundary {
            return candidate.hasObservedResetBoundary
        }
        if candidate.displayBoundaryDate != existing.displayBoundaryDate {
            return candidate.displayBoundaryDate > existing.displayBoundaryDate
        }
        return candidate.observedAt >= existing.observedAt
    }

    private nonisolated static func currentPeriodBoundaryDate(
        for referenceDate: Date,
        windowMinutes: Int,
        resetBoundaryLattice: ResetBoundaryLattice?) -> Date
    {
        if let resetBoundaryLattice {
            return self.periodBoundaryDate(
                containing: referenceDate,
                resetBoundaryLattice: resetBoundaryLattice)
        }
        return self.syntheticBoundaryDate(for: referenceDate, windowMinutes: windowMinutes)
    }

    private nonisolated static func closestPeriodBoundaryDate(
        to rawBoundaryDate: Date,
        resetBoundaryLattice: ResetBoundaryLattice) -> Date
    {
        let offset = rawBoundaryDate.timeIntervalSince(resetBoundaryLattice.referenceBoundaryDate)
        let periodOffset = (offset / resetBoundaryLattice.windowInterval).rounded()
        return resetBoundaryLattice.referenceBoundaryDate
            .addingTimeInterval(periodOffset * resetBoundaryLattice.windowInterval)
    }

    private nonisolated static func periodBoundaryDate(
        containing capturedAt: Date,
        resetBoundaryLattice: ResetBoundaryLattice) -> Date
    {
        let offset = capturedAt.timeIntervalSince(resetBoundaryLattice.referenceBoundaryDate)
        let periodOffset = ceil(offset / resetBoundaryLattice.windowInterval)
        return resetBoundaryLattice.referenceBoundaryDate
            .addingTimeInterval(periodOffset * resetBoundaryLattice.windowInterval)
    }

    private nonisolated static func syntheticBoundaryDate(for date: Date, windowMinutes: Int) -> Date {
        let bucketSeconds = Double(windowMinutes) * 60
        let bucketIndex = floor(date.timeIntervalSince1970 / bucketSeconds)
        return Date(timeIntervalSince1970: (bucketIndex + 1) * bucketSeconds)
    }

    private nonisolated static func xDomain(points: [Point]) -> ClosedRange<Double>? {
        guard !points.isEmpty else { return nil }
        return -0.5...(Double(Layout.maxPoints) - 0.5)
    }

    private nonisolated static func axisIndexes(points: [Point], windowMinutes: Int) -> [Double] {
        let candidateIndexes = self.axisCandidateIndexes(points: points, windowMinutes: windowMinutes)
        return self.proportionalAxisIndexes(points: points, candidateIndexes: candidateIndexes)
    }

    private nonisolated static func axisCandidateIndexes(points: [Point], windowMinutes: Int) -> [Int] {
        if windowMinutes <= 300 {
            return self.sessionAxisCandidateIndexes(points: points)
        }
        return points.map(\.index)
    }

    private nonisolated static func sessionAxisCandidateIndexes(points: [Point]) -> [Int] {
        guard let firstPoint = points.first else { return [] }
        let calendar = Calendar.current
        var previousPoint = firstPoint
        var rawIndexes: [Int] = [firstPoint.index]

        for point in points.dropFirst() {
            if !calendar.isDate(point.date, inSameDayAs: previousPoint.date) {
                rawIndexes.append(point.index)
            }
            previousPoint = point
        }

        return rawIndexes
    }

    private nonisolated static func proportionalAxisIndexes(points: [Point], candidateIndexes: [Int]) -> [Double] {
        guard !points.isEmpty, !candidateIndexes.isEmpty else { return [] }

        let occupiedFraction = Double(points.count) / Double(Layout.maxPoints)
        let proportionalBudget = Int(ceil(Double(Layout.maxAxisLabels) * occupiedFraction))
        let labelBudget = max(1, min(Layout.maxAxisLabels, proportionalBudget, candidateIndexes.count))

        if labelBudget == 1 {
            return [Double(candidateIndexes[0])]
        }

        let step = Double(candidateIndexes.count - 1) / Double(labelBudget - 1)
        var selectedIndexes = (0..<labelBudget).map { position in
            let candidateOffset = Int((Double(position) * step).rounded())
            return candidateIndexes[candidateOffset]
        }
        selectedIndexes = Array(NSOrderedSet(array: selectedIndexes)) as? [Int] ?? selectedIndexes

        let trailingLabelCutoff = points.first!.index + Int(floor(Double(points.count) * 0.8))
        if selectedIndexes.count > 1,
           let lastSelectedIndex = selectedIndexes.last,
           lastSelectedIndex >= trailingLabelCutoff
        {
            selectedIndexes.removeLast()
        }

        if points.count == Layout.maxPoints,
           let lastVisibleIndex = points.last?.index,
           !selectedIndexes.contains(lastVisibleIndex)
        {
            selectedIndexes.append(lastVisibleIndex)
        }

        let deduplicated = Array(NSOrderedSet(array: selectedIndexes)) as? [Int] ?? selectedIndexes
        return deduplicated.map(Double.init)
    }

    private nonisolated static func seriesTitle(
        name: PlanUtilizationSeriesName,
        metadata: ProviderMetadata?,
        windowMinutes: Int) -> String
    {
        switch name {
        case .session:
            localizedSessionQuotaLabel(metadata?.sessionLabel ?? "Session", windowMinutes: windowMinutes)
        case .weekly:
            L(metadata?.weeklyLabel ?? "Weekly")
        case .monthly:
            metadata?.opusLabel ?? "Monthly"
        case .opus:
            metadata?.opusLabel ?? "Opus"
        default:
            self.fallbackTitle(for: name.rawValue)
        }
    }

    private nonisolated static func fallbackTitle(for rawValue: String) -> String {
        let words = rawValue
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private nonisolated static func seriesSortOrder(_ name: PlanUtilizationSeriesName) -> Int {
        switch name {
        case .session:
            0
        case .weekly:
            1
        case .monthly:
            2
        case .opus:
            2
        default:
            100
        }
    }

    private nonisolated static func emptyStateText(title: String?) -> String {
        if let title {
            return String(format: L("No %@ utilization data yet."), title.lowercased())
        }
        return L("No utilization data yet.")
    }

    #if DEBUG
    struct ModelSnapshot: Equatable {
        let pointCount: Int
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let selectedSeries: String?
        let visibleSeries: [String]
        let visibleSeriesTitles: [String]
        let usedPercents: [Double]
        let pointDates: [String]
    }

    nonisolated static func _modelSnapshotForTesting(
        selectedSeriesRawValue: String? = nil,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        referenceDate: Date? = nil) -> ModelSnapshot
    {
        let visibleSeries = self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot)
        let selectedSeries = visibleSeries.first(where: { $0.id == selectedSeriesRawValue }) ?? visibleSeries.first
        let model = self.makeModel(
            history: selectedSeries?.history,
            provider: provider,
            referenceDate: referenceDate ?? histories.flatMap(\.entries).map(\.capturedAt).max() ?? Date())
        return ModelSnapshot(
            pointCount: model.points.count,
            axisIndexes: model.axisIndexes,
            xDomain: model.xDomain,
            selectedSeries: selectedSeries?.id,
            visibleSeries: visibleSeries.map(\.id),
            visibleSeriesTitles: visibleSeries.map(\.title),
            usedPercents: model.points.map(\.usedPercent),
            pointDates: model.points.map { point in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return formatter.string(from: point.date)
            })
    }

    nonisolated static func _detailLineForTesting(
        selectedSeriesRawValue: String? = nil,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        referenceDate: Date? = nil) -> String
    {
        let visibleSeries = self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot)
        let selectedSeries = visibleSeries.first(where: { $0.id == selectedSeriesRawValue }) ?? visibleSeries.first
        let model = self.makeModel(
            history: selectedSeries?.history,
            provider: provider,
            referenceDate: referenceDate ?? histories.flatMap(\.entries).map(\.capturedAt).max() ?? Date())
        return self.detailLine(point: model.points.last, windowMinutes: selectedSeries?.history.windowMinutes ?? 0)
    }

    nonisolated static func _emptyStateTextForTesting(title: String?) -> String {
        self.emptyStateText(title: title)
    }
    #endif
}

extension PlanUtilizationHistoryChartMenuView {
    /// The plan usage chart only offers the core rate windows; tertiary (e.g. Claude Opus) and
    /// extra rate-window series are tracked elsewhere and never appear as chart tabs.
    private nonisolated static let displayableSeriesNames: Set<PlanUtilizationSeriesName> = [
        .session,
        .weekly,
        .monthly,
    ]

    private nonisolated static let defaultSeriesPriority: [PlanUtilizationSeriesName] = [
        .session,
        .weekly,
        .monthly,
    ]

    /// Restores the persisted series when it is still visible; otherwise defaults in priority
    /// order (session, weekly, monthly) before falling back to the first available series.
    private nonisolated static func defaultSelectedSeriesID(
        storedSeriesID: String?,
        in visibleSeries: [VisibleSeries]) -> String?
    {
        if let storedSeriesID,
           visibleSeries.contains(where: { $0.id == storedSeriesID })
        {
            return storedSeriesID
        }
        for name in Self.defaultSeriesPriority {
            if let match = visibleSeries.first(where: { $0.selection.name == name }) {
                return match.id
            }
        }
        return visibleSeries.first?.id
    }

    private nonisolated static func resetMatchesHistory(
        _ window: RateWindow,
        latestReset: Date?) -> Bool
    {
        guard let latestReset, let windowReset = window.resetsAt else { return true }
        return abs(windowReset.timeIntervalSince(latestReset)) < 2 * 60
    }

    private nonisolated static func currentWindow(
        for series: VisibleSeries,
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> RateWindow?
    {
        guard let snapshot else { return nil }
        let tertiaryName: PlanUtilizationSeriesName = provider == .opencodego ? .monthly : .opus
        let slotted: [(PlanUtilizationSeriesName, RateWindow?)] = [
            (.session, snapshot.primary),
            (.weekly, snapshot.secondary),
            (tertiaryName, snapshot.tertiary),
        ]
        let named = (snapshot.extraRateWindows ?? [])
            .filter(\.usageKnown)
            .map { (PlanUtilizationSeriesName(rawValue: $0.id), Optional($0.window)) }
        let candidates = (slotted + named).compactMap { candidate -> (PlanUtilizationSeriesName, RateWindow)? in
            let (suggestedName, window) = candidate
            guard let window, !window.isSyntheticPlaceholder else { return nil }
            return (suggestedName, window)
        }

        let historyReset = series.history.entries.compactMap(\.resetsAt).max()

        let durationMatches = candidates.filter { _, window in
            guard let minutes = window.windowMinutes, minutes > 0 else { return false }
            return series.selection.name.canonicalWindowMinutes(minutes) == series.selection.windowMinutes
        }
        if durationMatches.count == 1,
           self.resetMatchesHistory(durationMatches[0].1, latestReset: historyReset)
        {
            return durationMatches[0].1
        }

        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        if let semanticMatch = durationMatches.first(where: { suggestedName, window in
            guard let minutes = window.windowMinutes,
                  self.resetMatchesHistory(window, latestReset: historyReset)
            else { return false }
            let normalized = presentation.normalizePlanUtilizationSeries(
                self.providerSeries(suggestedName),
                windowMinutes: minutes)
            return self.historySeries(normalized) == series.selection.name
        }) {
            return semanticMatch.1
        }

        guard let latestReset = historyReset else { return nil }
        let resetCandidates = candidates.filter { suggestedName, window in
            if let minutes = window.windowMinutes, minutes > 0 {
                let normalized = presentation.normalizePlanUtilizationSeries(
                    self.providerSeries(suggestedName),
                    windowMinutes: minutes)
                return self.historySeries(normalized) == series.selection.name
            }
            return self.historySeries(self.providerSeries(suggestedName)) == series.selection.name
        }
        let closest = resetCandidates.min { lhs, rhs in
            let lhsDistance = lhs.1.resetsAt.map { abs($0.timeIntervalSince(latestReset)) }
                ?? .greatestFiniteMagnitude
            let rhsDistance = rhs.1.resetsAt.map { abs($0.timeIntervalSince(latestReset)) }
                ?? .greatestFiniteMagnitude
            return lhsDistance < rhsDistance
        }?.1
        guard let closest,
              let closestReset = closest.resetsAt,
              abs(closestReset.timeIntervalSince(latestReset)) < 2 * 60
        else {
            return nil
        }
        return closest
    }

    #if DEBUG
    nonisolated static func _currentWindowUsedPercentForTesting(
        history: PlanUtilizationSeriesHistory,
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> Double?
    {
        let series = VisibleSeries(
            selection: SeriesSelection(name: history.name, windowMinutes: history.windowMinutes),
            title: history.name.rawValue,
            history: history)
        return self.currentWindow(for: series, provider: provider, snapshot: snapshot)?.usedPercent
    }

    struct PaceModelSnapshot: Equatable {
        let selectedSeries: String
        let resetsAt: Date
        let observedDates: [Date]
        let rawUsedPercents: [Double]
    }

    nonisolated static func _paceModelSnapshotForTesting(
        selectedSeriesRawValue: String? = nil,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        referenceDate: Date) -> PaceModelSnapshot?
    {
        let visibleSeries = self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot)
        guard let selectedSeries = visibleSeries.first(where: { $0.id == selectedSeriesRawValue })
            ?? visibleSeries.first
        else {
            return nil
        }
        let currentWindow = self.currentWindow(for: selectedSeries, provider: provider, snapshot: snapshot)
        guard let model = PlanUtilizationPaceChartModel(
            history: selectedSeries.history,
            currentWindow: currentWindow,
            referenceDate: referenceDate,
            currentWindowCapturedAt: snapshot.updatedAt)
        else {
            return nil
        }
        return PaceModelSnapshot(
            selectedSeries: selectedSeries.id,
            resetsAt: model.resetsAt,
            observedDates: model.observedPoints.map(\.date),
            rawUsedPercents: model.observedPoints.map(\.rawUsedPercent))
    }

    nonisolated static func _defaultSelectedSeriesIDForTesting(
        storedSeriesID: String?,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil) -> String?
    {
        self.defaultSelectedSeriesID(
            storedSeriesID: storedSeriesID,
            in: self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot))
    }
    #endif

    private nonisolated static func detailLine(point: Point?, windowMinutes: Int) -> String {
        guard let point else {
            return "-"
        }

        let dateLabel = self.detailDateLabel(for: point.date, windowMinutes: windowMinutes)

        let used = max(0, min(100, point.usedPercent))
        if !point.isObserved {
            return "\(dateLabel): -"
        }
        let usedText = used.formatted(.number.precision(.fractionLength(0...1)))
        return L("%@: %@%% used", dateLabel, usedText)
    }

    private nonisolated static func detailDateLabel(for date: Date, windowMinutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedLocale()
        formatter.timeZone = TimeZone.current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        var rendered = formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        let amSymbol = formatter.amSymbol ?? ""
        let pmSymbol = formatter.pmSymbol ?? ""
        if !amSymbol.isEmpty {
            rendered = rendered.replacingOccurrences(of: amSymbol, with: amSymbol.lowercased())
        }
        if !pmSymbol.isEmpty {
            rendered = rendered.replacingOccurrences(of: pmSymbol, with: pmSymbol.lowercased())
        }
        return rendered
    }
}

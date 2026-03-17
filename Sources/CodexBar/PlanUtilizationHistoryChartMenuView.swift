import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct PlanUtilizationHistoryChartMenuView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 130
        static let detailHeight: CGFloat = 32
        static let emptyStateHeight: CGFloat = chartHeight + detailHeight
    }

    private enum Period: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case monthly

        var id: String {
            self.rawValue
        }

        var title: String {
            switch self {
            case .daily:
                "Daily"
            case .weekly:
                "Weekly"
            case .monthly:
                "Monthly"
            }
        }

        var emptyStateText: String {
            switch self {
            case .daily:
                "No daily utilization data yet."
            case .weekly:
                "No weekly utilization data yet."
            case .monthly:
                "No monthly utilization data yet."
            }
        }

        var maxPoints: Int {
            switch self {
            case .daily:
                30
            case .weekly:
                24
            case .monthly:
                24
            }
        }

        var chartWindowMinutes: Int {
            switch self {
            case .daily:
                1440
            case .weekly:
                10080
            case .monthly:
                44640
            }
        }
    }

    private enum WindowSlot: Int, CaseIterable {
        case primary
        case secondary
    }

    private struct WindowSourceSelection: Hashable {
        let slot: WindowSlot
        let windowMinutes: Int
    }

    private struct DerivedGroupAccumulator {
        let chartDate: Date
        let boundaryDate: Date
        let usesResetBoundary: Bool
        var maxUsedPercent: Double
    }

    private enum AggregationMode {
        case exactFit
        case derived
    }

    private struct Point: Identifiable {
        let id: String
        let index: Int
        let date: Date
        let usedPercent: Double
    }

    private let provider: UsageProvider
    private let samples: [PlanUtilizationHistorySample]
    private let width: CGFloat
    private let isRefreshing: Bool

    @State private var selectedPeriod: Period = .daily
    @State private var selectedPointID: String?

    init(provider: UsageProvider, samples: [PlanUtilizationHistorySample], width: CGFloat, isRefreshing: Bool = false) {
        self.provider = provider
        self.samples = samples
        self.width = width
        self.isRefreshing = isRefreshing
    }

    var body: some View {
        let availablePeriods = Self.availablePeriods(samples: self.samples)
        let visiblePeriods = availablePeriods.isEmpty ? Period.allCases : availablePeriods
        let effectiveSelectedPeriod = visiblePeriods.contains(self.selectedPeriod)
            ? self.selectedPeriod
            : (visiblePeriods.first ?? .daily)
        let model = Self.makeModel(period: effectiveSelectedPeriod, samples: self.samples, provider: self.provider)

        VStack(alignment: .leading, spacing: 10) {
            if visiblePeriods.count > 1 {
                Picker("Period", selection: self.$selectedPeriod) {
                    ForEach(visiblePeriods) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: self.selectedPeriod) { _, _ in
                    self.selectedPointID = nil
                }
            }

            if model.points.isEmpty {
                ZStack {
                    Text(Self.emptyStateText(period: effectiveSelectedPeriod, isRefreshing: self.isRefreshing))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.emptyStateHeight)
            } else {
                self.utilizationChart(model: model)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: model.axisIndexes) { value in
                            AxisGridLine().foregroundStyle(Color.clear)
                            AxisTick().foregroundStyle(Color.clear)
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    let index = Int(raw.rounded())
                                    if let point = model.pointsByIndex[index] {
                                        Text(point.date.formatted(self.axisFormat(for: effectiveSelectedPeriod)))
                                            .font(.caption2)
                                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                    }
                                }
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: Layout.chartHeight)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }

                let detail = self.detailLines(model: model, period: effectiveSelectedPeriod)
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                    Text(detail.secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                }
                .frame(height: Layout.detailHeight, alignment: .top)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .task(id: visiblePeriods.map(\.rawValue).joined(separator: ",")) {
            guard let firstVisiblePeriod = visiblePeriods.first else { return }
            guard !visiblePeriods.contains(self.selectedPeriod) else { return }
            self.selectedPeriod = firstVisiblePeriod
            self.selectedPointID = nil
        }
    }

    private struct Model {
        let points: [Point]
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let pointsByID: [String: Point]
        let pointsByIndex: [Int: Point]
        let barColor: Color
    }

    private nonisolated static func makeModel(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        provider: UsageProvider) -> Model
    {
        let calendar = Calendar.current
        guard let selectedSource = Self.selectedSource(for: period, samples: samples) else {
            return Self.emptyModel(provider: provider, period: period)
        }
        let aggregationMode = Self.aggregationMode(period: period, source: selectedSource)
        let buckets = Self.chartBuckets(
            period: period,
            samples: samples,
            source: selectedSource,
            mode: aggregationMode,
            calendar: calendar)

        var points = buckets
            .map { date, used in
                Point(
                    id: Self.pointID(date: date, period: period),
                    index: 0,
                    date: date,
                    usedPercent: used)
            }
            .sorted { $0.date < $1.date }

        if points.count > period.maxPoints {
            points = Array(points.suffix(period.maxPoints))
        }

        points = points.enumerated().map { offset, point in
            Point(
                id: point.id,
                index: offset,
                date: point.date,
                usedPercent: point.usedPercent)
        }

        let axisIndexes = Self.axisIndexes(points: points, period: period)
        let xDomain = Self.xDomain(points: points, period: period)

        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let pointsByIndex = Dictionary(uniqueKeysWithValues: points.map { ($0.index, $0) })
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)

        return Model(
            points: points,
            axisIndexes: axisIndexes,
            xDomain: xDomain,
            pointsByID: pointsByID,
            pointsByIndex: pointsByIndex,
            barColor: barColor)
    }

    private nonisolated static func emptyModel(provider: UsageProvider, period: Period) -> Model {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)
        return Model(
            points: [],
            axisIndexes: [],
            xDomain: self.xDomain(points: [], period: period),
            pointsByID: [:],
            pointsByIndex: [:],
            barColor: barColor)
    }

    private nonisolated static func xDomain(points: [Point], period: Period) -> ClosedRange<Double>? {
        guard !points.isEmpty else { return nil }
        return -0.5...(Double(period.maxPoints) - 0.5)
    }

    private nonisolated static func axisIndexes(points: [Point], period: Period) -> [Double] {
        guard let first = points.first?.index, let last = points.last?.index else { return [] }
        if first == last { return [Double(first)] }
        switch period {
        case .daily:
            return [Double(first), Double(last)]
        case .weekly, .monthly:
            return [Double(last)]
        }
    }

    #if DEBUG
    struct ModelSnapshot: Equatable {
        let pointCount: Int
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let selectedSource: String?
        let usedPercents: [Double]
    }

    nonisolated static func _modelSnapshotForTesting(
        periodRawValue: String,
        samples: [PlanUtilizationHistorySample],
        provider: UsageProvider) -> ModelSnapshot?
    {
        guard let period = Period(rawValue: periodRawValue) else { return nil }
        let model = self.makeModel(period: period, samples: samples, provider: provider)
        return ModelSnapshot(
            pointCount: model.points.count,
            axisIndexes: model.axisIndexes,
            xDomain: model.xDomain,
            selectedSource: self.selectedSource(for: period, samples: samples).map {
                "\($0.slot == .primary ? "primary" : "secondary"):\($0.windowMinutes)"
            },
            usedPercents: model.points.map(\.usedPercent))
    }

    nonisolated static func _emptyStateTextForTesting(periodRawValue: String, isRefreshing: Bool) -> String? {
        guard let period = Period(rawValue: periodRawValue) else { return nil }
        return self.emptyStateText(period: period, isRefreshing: isRefreshing)
    }

    nonisolated static func _visiblePeriodsForTesting(samples: [PlanUtilizationHistorySample]) -> [String] {
        self.availablePeriods(samples: samples).map(\.rawValue)
    }
    #endif

    private nonisolated static func emptyStateText(period: Period, isRefreshing: Bool) -> String {
        if isRefreshing {
            return "Refreshing..."
        }
        return period.emptyStateText
    }

    private nonisolated static func selectedSource(
        for period: Period,
        samples: [PlanUtilizationHistorySample]) -> WindowSourceSelection?
    {
        var counts: [WindowSourceSelection: Int] = [:]

        for sample in samples {
            for slot in WindowSlot.allCases {
                guard let windowMinutes = self.windowMinutes(for: sample, slot: slot) else { continue }
                guard windowMinutes <= period.chartWindowMinutes else { continue }
                let selection = WindowSourceSelection(slot: slot, windowMinutes: windowMinutes)
                counts[selection, default: 0] += 1
            }
        }

        return counts.max { lhs, rhs in
            if lhs.key.windowMinutes != rhs.key.windowMinutes {
                return lhs.key.windowMinutes < rhs.key.windowMinutes
            }
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return lhs.key.slot.rawValue > rhs.key.slot.rawValue
        }?.key
    }

    private nonisolated static func availablePeriods(samples: [PlanUtilizationHistorySample]) -> [Period] {
        Period.allCases.filter { self.selectedSource(for: $0, samples: samples) != nil }
    }

    private nonisolated static func usedPercent(
        for sample: PlanUtilizationHistorySample,
        source: WindowSourceSelection) -> Double?
    {
        guard self.windowMinutes(for: sample, slot: source.slot) == source.windowMinutes else { return nil }
        switch source.slot {
        case .primary:
            return sample.primaryUsedPercent
        case .secondary:
            return sample.secondaryUsedPercent
        }
    }

    private nonisolated static func windowMinutes(
        for sample: PlanUtilizationHistorySample,
        slot: WindowSlot) -> Int?
    {
        switch slot {
        case .primary:
            sample.primaryWindowMinutes
        case .secondary:
            sample.secondaryWindowMinutes
        }
    }

    private nonisolated static func aggregationMode(
        period: Period,
        source: WindowSourceSelection) -> AggregationMode
    {
        source.windowMinutes == period.chartWindowMinutes ? .exactFit : .derived
    }

    private nonisolated static func chartBuckets(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        source: WindowSourceSelection,
        mode: AggregationMode,
        calendar: Calendar) -> [Date: Double]
    {
        switch mode {
        case .exactFit:
            self.exactFitChartBuckets(period: period, samples: samples, source: source, calendar: calendar)
        case .derived:
            self.derivedChartBuckets(period: period, samples: samples, source: source, calendar: calendar)
        }
    }

    private nonisolated static func exactFitChartBuckets(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        source: WindowSourceSelection,
        calendar: Calendar) -> [Date: Double]
    {
        var buckets: [Date: Double] = [:]

        for sample in samples {
            guard let used = self.usedPercent(for: sample, source: source) else { continue }
            guard let chartDate = self.bucketDate(for: sample.capturedAt, period: period, calendar: calendar) else {
                continue
            }
            let clamped = max(0, min(100, used))
            buckets[chartDate] = max(buckets[chartDate] ?? 0, clamped)
        }

        return buckets
    }

    private nonisolated static func derivedChartBuckets(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        source: WindowSourceSelection,
        calendar: Calendar) -> [Date: Double]
    {
        let groups = self.derivedGroups(period: period, samples: samples, source: source, calendar: calendar)
        guard !groups.isEmpty else { return [:] }

        let sortedGroups = groups.values.sorted { lhs, rhs in
            if lhs.boundaryDate != rhs.boundaryDate {
                return lhs.boundaryDate < rhs.boundaryDate
            }
            return lhs.chartDate < rhs.chartDate
        }

        var previousResetBoundary: Date?
        var weightedSums: [Date: Double] = [:]
        var totalWeights: [Date: Double] = [:]
        let nominalWindowMinutes = Double(source.windowMinutes)

        for group in sortedGroups {
            var weightMinutes = nominalWindowMinutes
            if group.usesResetBoundary, let previousResetBoundary {
                let factualWindowMinutes = group.boundaryDate.timeIntervalSince(previousResetBoundary) / 60
                if factualWindowMinutes > 0, factualWindowMinutes < nominalWindowMinutes {
                    weightMinutes = factualWindowMinutes
                }
            }

            weightedSums[group.chartDate, default: 0] += group.maxUsedPercent * weightMinutes
            totalWeights[group.chartDate, default: 0] += weightMinutes

            if group.usesResetBoundary {
                previousResetBoundary = group.boundaryDate
            }
        }

        return weightedSums.reduce(into: [Date: Double]()) { output, entry in
            let (chartDate, weightedSum) = entry
            let totalWeight = totalWeights[chartDate] ?? 0
            guard totalWeight > 0 else { return }
            output[chartDate] = weightedSum / totalWeight
        }
    }

    private nonisolated static func derivedGroups(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        source: WindowSourceSelection,
        calendar: Calendar) -> [Date: DerivedGroupAccumulator]
    {
        var groups: [Date: DerivedGroupAccumulator] = [:]

        for sample in samples {
            guard let used = self.usedPercent(for: sample, source: source) else { continue }
            guard let groupBoundary = self.derivedBoundaryDate(for: sample, source: source) else { continue }
            guard let chartDate = self.bucketDate(for: groupBoundary, period: period, calendar: calendar) else {
                continue
            }

            let clamped = max(0, min(100, used))
            let usesResetBoundary = self.resetsAt(for: sample, source: source) != nil

            if var existing = groups[groupBoundary] {
                existing.maxUsedPercent = max(existing.maxUsedPercent, clamped)
                groups[groupBoundary] = existing
            } else {
                groups[groupBoundary] = DerivedGroupAccumulator(
                    chartDate: chartDate,
                    boundaryDate: groupBoundary,
                    usesResetBoundary: usesResetBoundary,
                    maxUsedPercent: clamped)
            }
        }

        return groups
    }

    private nonisolated static func derivedBoundaryDate(
        for sample: PlanUtilizationHistorySample,
        source: WindowSourceSelection) -> Date?
    {
        if let resetsAt = self.resetsAt(for: sample, source: source) {
            return self.normalizedBoundaryDate(resetsAt)
        }
        return self.syntheticResetBoundaryDate(
            for: sample.capturedAt,
            windowMinutes: source.windowMinutes)
    }

    private nonisolated static func resetsAt(
        for sample: PlanUtilizationHistorySample,
        source: WindowSourceSelection) -> Date?
    {
        guard self.windowMinutes(for: sample, slot: source.slot) == source.windowMinutes else { return nil }
        switch source.slot {
        case .primary:
            return sample.primaryResetsAt
        case .secondary:
            return sample.secondaryResetsAt
        }
    }

    private nonisolated static func normalizedBoundaryDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private nonisolated static func syntheticResetBoundaryDate(
        for date: Date,
        windowMinutes: Int) -> Date?
    {
        guard windowMinutes > 0 else { return nil }
        let bucketSeconds = Double(windowMinutes) * 60
        let bucketIndex = floor(date.timeIntervalSince1970 / bucketSeconds)
        return Date(timeIntervalSince1970: (bucketIndex + 1) * bucketSeconds)
    }

    private nonisolated static func bucketDate(for date: Date, period: Period, calendar: Calendar) -> Date? {
        switch period {
        case .daily:
            calendar.startOfDay(for: date)
        case .weekly:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .monthly:
            calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    private nonisolated static func pointID(date: Date, period: Period) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = switch period {
        case .daily:
            "yyyy-MM-dd"
        case .weekly:
            "yyyy-'W'ww"
        case .monthly:
            "yyyy-MM"
        }
        return formatter.string(from: date)
    }

    private func xValue(for index: Int) -> PlottableValue<Double> {
        .value("Period", Double(index))
    }

    @ViewBuilder
    private func utilizationChart(model: Model) -> some View {
        if let xDomain = model.xDomain {
            Chart {
                self.utilizationChartContent(model: model)
            }
            .chartXScale(domain: xDomain)
        } else {
            Chart {
                self.utilizationChartContent(model: model)
            }
        }
    }

    @ChartContentBuilder
    private func utilizationChartContent(model: Model) -> some ChartContent {
        ForEach(model.points) { point in
            BarMark(
                x: self.xValue(for: point.index),
                y: .value("Utilization", point.usedPercent))
                .foregroundStyle(model.barColor)
        }
        if let selected = self.selectedPoint(model: model) {
            RuleMark(x: self.xValue(for: selected.index))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func axisFormat(for period: Period) -> Date.FormatStyle {
        switch period {
        case .daily, .weekly:
            .dateTime.month(.abbreviated).day()
        case .monthly:
            .dateTime.month(.abbreviated).year(.defaultDigits)
        }
    }

    private func selectedPoint(model: Model) -> Point? {
        guard let selectedPointID else { return nil }
        return model.pointsByID[selectedPointID]
    }

    private func detailLines(model: Model, period: Period) -> (primary: String, secondary: String) {
        let activePoint = self.selectedPoint(model: model) ?? model.points.last
        guard let point = activePoint else {
            return ("No data", "")
        }

        let dateLabel: String = switch period {
        case .daily, .weekly:
            point.date.formatted(.dateTime.month(.abbreviated).day())
        case .monthly:
            point.date.formatted(.dateTime.month(.abbreviated).year(.defaultDigits))
        }

        let used = max(0, min(100, point.usedPercent))
        let wasted = max(0, 100 - used)
        let usedText = used.formatted(.number.precision(.fractionLength(0...1)))
        let wastedText = wasted.formatted(.number.precision(.fractionLength(0...1)))

        return (
            "\(dateLabel): \(usedText)% used",
            "\(wastedText)% wasted")
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        let xInPlot = location.x - plotFrame.origin.x
        guard let xValue: Double = proxy.value(atX: xInPlot) else { return }

        var best: (id: String, distance: Double)?
        for point in model.points {
            let distance = abs(Double(point.index) - xValue)
            if let current = best {
                if distance < current.distance {
                    best = (point.id, distance)
                }
            } else {
                best = (point.id, distance)
            }
        }

        if self.selectedPointID != best?.id {
            self.selectedPointID = best?.id
        }
    }
}

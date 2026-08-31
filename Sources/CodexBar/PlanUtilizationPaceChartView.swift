import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct PlanUtilizationPaceChartView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 150
        static let detailHeight: CGFloat = 17
        static let axisLabelCount = 4
        static let pointSize: CGFloat = 16
    }

    private struct RenderPoint: Identifiable, Equatable {
        let point: PlanUtilizationPaceChartModel.Point

        var id: Date {
            self.point.date
        }
    }

    private struct RenderSegment: Identifiable, Equatable {
        let index: Int
        let points: [RenderPoint]

        var id: Int {
            self.index
        }
    }

    private struct RenderModel: Equatable {
        let paceEndpoints: [PlanUtilizationPaceChartModel.PaceEndpoint]
        let observedSegments: [RenderSegment]
        let observedPoints: [RenderPoint]
        let projection: PlanUtilizationPaceChartModel.Projection?
        let windowDomain: ClosedRange<Date>
        let axisDates: [Date]
        let accentColor: Color
    }

    private let windowTitle: String
    private let model: PlanUtilizationPaceChartModel
    private let currentDate: Date
    private let width: CGFloat
    private let renderModel: RenderModel

    @State private var selectedDate: Date?

    init(
        provider: UsageProvider,
        windowTitle: String,
        model: PlanUtilizationPaceChartModel,
        currentDate: Date,
        width: CGFloat)
    {
        self.windowTitle = windowTitle
        self.model = model
        self.currentDate = currentDate
        self.width = width
        self.renderModel = Self.makeRenderModel(model: model, provider: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.chart
                .frame(height: Layout.chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Pace chart"))
                .accessibilityValue(self.accessibilityValue)
                .focusable()
                .onMoveCommand(perform: self.moveSelection)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: self.moveSelection(.right)
                    case .decrement: self.moveSelection(.left)
                    @unknown default: break
                    }
                }

            Text(self.detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: Layout.detailHeight, alignment: .leading)
        }
        .frame(minWidth: max(self.width - 32, 0), maxWidth: .infinity, alignment: .topLeading)
    }

    private var chart: some View {
        Chart {
            self.paceMarks
            self.observedMarks
            self.projectionMarks
            self.currentDateMark
            self.resetMark
            self.selectedMark
        }
        .chartXScale(domain: self.renderModel.windowDomain)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: self.renderModel.axisDates) { value in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisTick().foregroundStyle(Color.clear)
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(Self.axisLabel(for: date, windowDuration: self.model.windowDuration))
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                MouseLocationReader { location in
                    self.updateSelection(location: location, proxy: proxy, geo: geo)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
    }

    @ChartContentBuilder
    private var paceMarks: some ChartContent {
        ForEach(self.renderModel.paceEndpoints, id: \.date) { endpoint in
            LineMark(
                x: .value(L("Time"), endpoint.date),
                y: .value(L("Pace Remaining"), endpoint.remainingPercent),
                series: .value(L("Series"), L("Pace")))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    @ChartContentBuilder
    private var observedMarks: some ChartContent {
        ForEach(self.renderModel.observedSegments) { segment in
            ForEach(segment.points) { renderPoint in
                LineMark(
                    x: .value(L("Time"), renderPoint.point.date),
                    y: .value(L("Remaining"), renderPoint.point.displayRemainingPercent),
                    series: .value(L("Segment"), segment.index))
                    .foregroundStyle(self.renderModel.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                PointMark(
                    x: .value(L("Time"), renderPoint.point.date),
                    y: .value(L("Remaining"), renderPoint.point.displayRemainingPercent))
                    .symbolSize(Layout.pointSize)
                    .foregroundStyle(self.renderModel.accentColor)
            }
        }
    }

    @ChartContentBuilder
    private var projectionMarks: some ChartContent {
        if let projection = self.renderModel.projection {
            ForEach([projection.start, projection.end], id: \.date) { point in
                LineMark(
                    x: .value(L("Time"), point.date),
                    y: .value(L("Projected Remaining"), point.displayRemainingPercent),
                    series: .value(L("Series"), L("Projection")))
                    .foregroundStyle(self.renderModel.accentColor.opacity(projection.isLowConfidence ? 0.42 : 0.62))
                    .lineStyle(StrokeStyle(
                        lineWidth: 1.6,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: projection.isLowConfidence ? [3, 4] : [6, 4]))
            }
        }
    }

    @ChartContentBuilder
    private var currentDateMark: some ChartContent {
        if self.renderModel.windowDomain.contains(self.currentDate) {
            RuleMark(x: .value(L("Current Time"), self.currentDate))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    @ChartContentBuilder
    private var resetMark: some ChartContent {
        RuleMark(x: .value(L("Reset"), self.model.resetMarker))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private var selectedMark: some ChartContent {
        if let hover = self.selectedHoverPoint {
            RuleMark(x: .value(L("Selected Time"), hover.point.date))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(
                x: .value(L("Selected Time"), hover.point.date),
                y: .value(L("Selected Remaining"), hover.point.displayRemainingPercent))
                .symbolSize(Layout.pointSize * 1.7)
                .foregroundStyle(self.renderModel.accentColor)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    self.tooltip(for: hover)
                }
        }
    }

    private var selectedHoverPoint: PlanUtilizationPaceChartModel.HoverPoint? {
        self.selectedDate.flatMap(self.model.nearestObservedPoint(to:))
    }

    private var detailLine: String {
        guard let hover = self.selectedHoverPoint
            ?? self.model.observedPoints.last.map({ PlanUtilizationPaceChartModel.HoverPoint(
                point: $0,
                deltaFromPace: $0.rawRemainingPercent - $0.paceRemainingPercent)
            })
        else {
            return L("%@: no pace data yet", self.windowTitle)
        }
        return self.summaryLine(for: hover)
    }

    private var accessibilityValue: String {
        guard let latest = self.model.observedPoints.last else {
            return L("%@: no pace data yet", self.windowTitle)
        }
        let delta = latest.rawRemainingPercent - latest.paceRemainingPercent
        return [
            self.windowTitle,
            L("%@ remaining", Self.percent(latest.rawRemainingPercent)),
            L("%@ used", Self.percent(latest.rawUsedPercent)),
            Self.deltaText(delta),
        ].joined(separator: ", ")
    }

    private func tooltip(for hover: PlanUtilizationPaceChartModel.HoverPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.detailDateLabel(for: hover.point.date))
            Text(L(
                "Remaining %@ / used %@",
                Self.percent(hover.point.rawRemainingPercent),
                Self.percent(hover.point.rawUsedPercent)))
            Text(L(
                "Pace %@, %@",
                Self.percent(hover.point.paceRemainingPercent),
                Self.deltaText(hover.deltaFromPace)))
            if self.isProjectionStart(hover.point),
               let runOutAt = self.model.projection?.runOutAt
            {
                Text(L("Run-out %@", Self.detailDateLabel(for: runOutAt)))
            }
        }
        .font(.caption2)
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(radius: 2, y: 1)
    }

    private func summaryLine(for hover: PlanUtilizationPaceChartModel.HoverPoint) -> String {
        var parts = [
            Self.detailDateLabel(for: hover.point.date),
            L("%@ remaining", Self.percent(hover.point.rawRemainingPercent)),
            L("%@ used", Self.percent(hover.point.rawUsedPercent)),
            Self.deltaText(hover.deltaFromPace),
        ]
        if self.isProjectionStart(hover.point),
           let runOutAt = self.model.projection?.runOutAt
        {
            parts.append(L("run-out %@", Self.detailDateLabel(for: runOutAt)))
        }
        return "\(self.windowTitle): \(parts.joined(separator: " · "))"
    }

    private func updateSelection(
        location: CGPoint?,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedDate != nil {
                self.selectedDate = nil
            }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            if self.selectedDate != nil {
                self.selectedDate = nil
            }
            return
        }

        let xInPlot = location.x - plotFrame.origin.x
        guard let selectedDate: Date = proxy.value(atX: xInPlot) else { return }
        let nearest = self.model.nearestObservedPoint(to: selectedDate)
        if self.selectedDate != nearest?.point.date {
            self.selectedDate = nearest?.point.date
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !self.renderModel.observedPoints.isEmpty else { return }
        let points = self.renderModel.observedPoints
        let currentIndex = self.selectedDate.flatMap { selectedDate in
            points.firstIndex { $0.point.date == selectedDate }
        }

        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max((currentIndex ?? points.count) - 1, 0)
        case .right:
            nextIndex = min((currentIndex ?? -1) + 1, points.count - 1)
        default:
            return
        }

        self.selectedDate = points[nextIndex].point.date
    }

    private func isProjectionStart(_ point: PlanUtilizationPaceChartModel.Point) -> Bool {
        self.model.projection?.start.date == point.date
    }

    private nonisolated static func makeRenderModel(
        model: PlanUtilizationPaceChartModel,
        provider: UsageProvider) -> RenderModel
    {
        let providerColor = ProviderAccentPalette.color(for: provider)
        let accentColor = Color(red: providerColor.red, green: providerColor.green, blue: providerColor.blue)
        let observedSegments = model.observedSegments.enumerated().map { index, points in
            RenderSegment(index: index, points: points.map(RenderPoint.init(point:)))
        }
        return RenderModel(
            paceEndpoints: model.paceEndpoints,
            observedSegments: observedSegments,
            observedPoints: model.observedPoints.map(RenderPoint.init(point:)),
            projection: model.projection,
            windowDomain: model.windowStart...model.resetsAt,
            axisDates: self.axisDates(windowStart: model.windowStart, resetsAt: model.resetsAt),
            accentColor: accentColor)
    }

    private nonisolated static func axisDates(windowStart: Date, resetsAt: Date) -> [Date] {
        let duration = resetsAt.timeIntervalSince(windowStart)
        guard duration > 0 else { return [windowStart] }
        return (0..<Layout.axisLabelCount).map { index in
            let fraction = Double(index) / Double(Layout.axisLabelCount - 1)
            return windowStart.addingTimeInterval(duration * fraction)
        }
    }

    private nonisolated static func axisLabel(for date: Date, windowDuration: TimeInterval) -> String {
        if windowDuration <= 24 * 60 * 60 {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private nonisolated static func detailDateLabel(for date: Date) -> String {
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

    private nonisolated static func percent(_ value: Double) -> String {
        let formatted = value.formatted(.number.precision(.fractionLength(0...1)))
        return "\(formatted)%"
    }

    private nonisolated static func deltaText(_ delta: Double) -> String {
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
        if abs(delta) < 0.05 {
            return L("on pace")
        }
        if delta > 0 {
            return L("%@ pts ahead", magnitude)
        }
        return L("%@ pts behind", magnitude)
    }
}

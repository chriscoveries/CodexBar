import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload

    private let background = Color(red: 0.078, green: 0.067, blue: 0.063)
    private let primary = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let secondary = Color(red: 0.70, green: 0.66, blue: 0.62)
    private let accent = Color(red: 0.93, green: 0.56, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            self.hero
                .padding(.top, 16)
            Rectangle()
                .fill(self.secondary.opacity(0.22))
                .frame(height: 1)
                .padding(.vertical, 17)
            self.rankings
                .frame(height: 286, alignment: .top)
            Spacer(minLength: 10)
            self.footer
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 34)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(self.background)
        .foregroundStyle(self.primary)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                ShareStatsMark(accent: self.accent)
                    .frame(width: 34, height: 34)
                Text("CodexBar")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            Spacer()
            Text("LOCAL SNAPSHOT")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(self.secondary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(self.secondary.opacity(0.45), lineWidth: 1)
                }
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 52) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TRACKED TOKENS · \(self.payload.days) DAYS")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(self.secondary)
                Text(self.payload.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—")
                    .font(.system(size: 104, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                ShareStatsMetric(
                    label: "EST. \(self.payload.days)-DAY SPEND",
                    value: self.payload.estimatedCostUSD
                        .flatMap { $0.isFinite ? ShareStatsFormatting.currencyUSD($0) : nil } ?? "—",
                    valueSize: 42,
                    color: self.primary,
                    secondary: self.secondary)
                if let monthToDateSpendUSD = self.payload.monthToDateSpendUSD {
                    ShareStatsMetric(
                        label: "OPENROUTER · MONTH TO DATE",
                        value: ShareStatsFormatting.currencyUSD(monthToDateSpendUSD),
                        valueSize: 34,
                        color: self.accent,
                        secondary: self.secondary)
                } else {
                    Text("\(self.payload.providers.count) subscriptions · \(self.payload.topModels.count) models surfaced")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(self.secondary)
                }
            }
            .frame(width: 390, alignment: .leading)
        }
        .frame(height: 132, alignment: .bottom)
    }

    private var rankings: some View {
        HStack(alignment: .top, spacing: 46) {
            VStack(alignment: .leading, spacing: 6) {
                self.sectionHeader("SUBSCRIPTIONS", detail: "\(self.payload.providers.count) CONNECTED")
                ForEach(
                    Array(self.payload.providers.prefix(self.providerDisplayLimit).enumerated()),
                    id: \.element.id)
                { index, provider in
                    ShareStatsProviderRow(
                        rank: index + 1,
                        provider: provider,
                        color: ShareStatsPalette.color(at: index))
                }
                if self.payload.providers.count > self.providerDisplayLimit {
                    Text("+\(self.payload.providers.count - self.providerDisplayLimit) more configured")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(self.secondary)
                        .padding(.leading, 20)
                }
            }
            .frame(width: 554, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    self.sectionHeader("TOP MODELS", detail: "BY USAGE")
                    if self.payload.topModels.isEmpty {
                        Text("No model-level history in this local snapshot")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(self.secondary)
                            .padding(.top, 4)
                    } else {
                        ForEach(
                            Array(self.payload.topModels.prefix(3).enumerated()),
                            id: \.element.id)
                        { index, model in
                            ShareStatsModelRow(
                                rank: index + 1,
                                model: model,
                                color: self.color(forProviderNamed: model.providerName))
                        }
                    }
                }
                HStack {
                    Text("ACTIVITY BY SUBSCRIPTION")
                    Spacer()
                    Text("\(self.payload.days)D")
                        .monospacedDigit()
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(self.secondary)
                .padding(.top, 18)
                ShareStatsActivityChart(providers: self.payload.providers, emptyColor: self.secondary)
                    .frame(height: 56)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var providerDisplayLimit: Int {
        self.payload.topModels.isEmpty ? 7 : 5
    }

    private func color(forProviderNamed name: String) -> Color {
        ShareStatsPalette.color(at: self.paletteIndex(forProviderNamed: name))
    }

    private func paletteIndex(forProviderNamed name: String) -> Int {
        self.payload.providers.firstIndex { $0.providerName == name } ?? 0
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .tracking(1.5)
            Spacer()
            Text(detail)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .tracking(1.0)
        }
        .foregroundStyle(self.secondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("LOCAL · AGGREGATE ONLY", systemImage: "lock.shield")
            Spacer()
            Text("DATA THROUGH \(ShareStatsFormatting.dataThrough(self.payload.periodEnd).uppercased())")
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .tracking(0.7)
        .foregroundStyle(self.secondary)
    }
}

private struct ShareStatsMetric: View {
    let label: String
    let value: String
    let valueSize: CGFloat
    let color: Color
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(self.label)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(self.secondary)
                .lineLimit(1)
            Text(self.value)
                .font(.system(size: self.valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct ShareStatsModelRow: View {
    let rank: Int
    let model: ShareStatsModelPayload
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(self.color)
                .frame(width: 5, height: 34)
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                .frame(width: 27, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.model.modelName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(self.model.providerName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(self.detail)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.78, green: 0.74, blue: 0.69))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 48)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var detail: String {
        if let cost = self.model.estimatedCostUSD, cost.isFinite {
            return "~\(ShareStatsFormatting.currencyUSD(cost))"
        }
        return self.model.totalTokens.map(ShareStatsFormatting.compactCount) ?? "used"
    }
}

private struct ShareStatsProviderRow: View {
    let rank: Int
    let provider: ShareStatsProviderPayload
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(self.color)
                .frame(width: 6, height: 30)
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                .frame(width: 27, alignment: .leading)
            HStack(spacing: 8) {
                Text(self.provider.providerName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let subscriptionName = self.provider.subscriptionName {
                    Text("· \(subscriptionName)")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(self.detail)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.78, green: 0.74, blue: 0.69))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var detail: String {
        var metrics: [String] = []
        if let tokens = self.provider.totalTokens {
            metrics.append(ShareStatsFormatting.compactCount(tokens))
        }
        if let cost = self.provider.estimatedCostUSD, cost.isFinite {
            let window = self.provider.spendWindow == .monthToDate ? " MTD" : ""
            metrics.append("~\(ShareStatsFormatting.currencyUSD(cost))\(window)")
        }
        return metrics.isEmpty ? "connected" : metrics.joined(separator: " · ")
    }
}

private enum ShareStatsPalette {
    static let colors = [
        Color(red: 1.00, green: 0.60, blue: 0.38),
        Color(red: 0.60, green: 0.66, blue: 1.00),
        Color(red: 0.38, green: 0.84, blue: 0.72),
        Color(red: 0.95, green: 0.79, blue: 0.41),
        Color(red: 0.44, green: 0.77, blue: 0.96),
        Color(red: 0.95, green: 0.55, blue: 0.67),
    ]

    static func color(at index: Int) -> Color {
        self.colors[index % self.colors.count]
    }
}

private struct ShareStatsMark: View {
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array([0.38, 0.68, 1.0].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(self.accent)
                    .frame(width: 5, height: 28 * height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ShareStatsActivityChart: View {
    struct Series: Identifiable {
        let id: String
        let values: [Int]
        let color: Color
    }

    let providers: [ShareStatsProviderPayload]
    let emptyColor: Color

    var body: some View {
        let dailySeries = self.providers.enumerated().map { index, provider in
            Series(id: provider.id, values: provider.dailyTokens, color: ShareStatsPalette.color(at: index))
        }
        let dayCount = dailySeries.map(\.values.count).max() ?? 0
        let bucketCount = min(10, dayCount)
        let series = dailySeries.map { item in
            Series(
                id: item.id,
                values: (0..<bucketCount).map { bucket in
                    let start = bucket * dayCount / max(bucketCount, 1)
                    let end = (bucket + 1) * dayCount / max(bucketCount, 1)
                    return (start..<end).reduce(0) { subtotal, day in
                        subtotal + (item.values.indices.contains(day) ? item.values[day] : 0)
                    }
                },
                color: item.color)
        }
        let totals = (0..<bucketCount).map { bucket in
            series.reduce(0) { total, item in
                total + (item.values.indices.contains(bucket) ? item.values[bucket] : 0)
            }
        }
        let maximum = max(Double(totals.max() ?? 0), 1)

        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<bucketCount, id: \.self) { bucket in
                    let total = totals[bucket]
                    if total == 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(self.emptyColor.opacity(0.13))
                            .frame(maxWidth: .infinity, maxHeight: 4)
                    } else {
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            ForEach(Array(series.reversed())) { item in
                                let value = item.values.indices.contains(bucket) ? item.values[bucket] : 0
                                if value > 0 {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(item.color.opacity(0.90))
                                        .frame(height: max(2, proxy.size.height * Double(value) / maximum))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

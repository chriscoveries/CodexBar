import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload

    private let background = Color(red: 0.055, green: 0.052, blue: 0.047)
    private let primary = Color(red: 0.94, green: 0.92, blue: 0.87)
    private let secondary = Color(red: 0.60, green: 0.57, blue: 0.52)
    private let accent = Color(red: 0.93, green: 0.54, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Rectangle()
                .fill(self.secondary.opacity(0.24))
                .frame(height: 1)
                .padding(.top, 24)
            HStack(alignment: .top, spacing: 52) {
                self.summary
                    .frame(width: 455, alignment: .leading)
                self.providerBreakdown
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 30)
            .frame(maxHeight: .infinity, alignment: .top)
            self.footer
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 38)
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
                    .font(.system(size: 25, weight: .medium, design: .rounded))
            }
            Spacer()
            Text("LOCAL SNAPSHOT")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(self.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(self.accent.opacity(0.85), lineWidth: 1)
                }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MY AI SUBSCRIPTIONS · LAST \(self.payload.days) DAYS")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .tracking(1.35)
                .lineLimit(1)
            Text(self.payload.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—")
                .font(.system(size: 105, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.top, 7)
            Text("TRACKED TOKENS")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .tracking(5.5)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: ShareStatsPalette.colors,
                        startPoint: .leading,
                        endPoint: .trailing))
                .frame(width: 112, height: 3)
                .padding(.vertical, 16)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let cost = self.payload.estimatedCostUSD, cost.isFinite {
                    Text(ShareStatsFormatting.currencyUSD(cost))
                        .font(.system(size: 36, weight: .regular, design: .rounded))
                        .monospacedDigit()
                    Text("estimated")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(self.secondary)
                }
            }
            Text("\(self.payload.providers.count) subscriptions · \(self.payload.topModels.count) models surfaced")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(self.secondary)
                .padding(.top, 10)
            HStack {
                Text("ACTIVITY BY SUBSCRIPTION")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                Spacer()
                Text("\(self.payload.days)D")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(self.secondary)
            .padding(.top, 18)
            ShareStatsActivityChart(providers: self.payload.providers, emptyColor: self.secondary)
                .frame(height: 84)
                .padding(.top, 8)
        }
    }

    private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("SUBSCRIPTION STACK")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                    Spacer()
                    Text("\(self.payload.providers.count) CONNECTED")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.1)
                }
                .foregroundStyle(self.secondary)
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
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(self.secondary)
                        .padding(.leading, 18)
                }
            }

            Rectangle()
                .fill(self.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 7) {
                Text("MODEL RANKING")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(self.secondary)
                if self.payload.topModels.isEmpty {
                    Text("No model-level history in this local snapshot")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(self.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(
                        Array(self.payload.topModels.prefix(4).enumerated()),
                        id: \.element.id)
                    { index, model in
                        ShareStatsModelRow(
                            rank: index + 1,
                            subscriptionRank: self.subscriptionRank(forProviderNamed: model.providerName),
                            model: model,
                            color: self.color(forProviderNamed: model.providerName))
                    }
                }
            }
        }
    }

    private var providerDisplayLimit: Int {
        self.payload.topModels.isEmpty ? 8 : 5
    }

    private func color(forProviderNamed name: String) -> Color {
        ShareStatsPalette.color(at: self.paletteIndex(forProviderNamed: name))
    }

    private func subscriptionRank(forProviderNamed name: String) -> Int {
        self.paletteIndex(forProviderNamed: name) + 1
    }

    private func paletteIndex(forProviderNamed name: String) -> Int {
        self.payload.providers.firstIndex { $0.providerName == name } ?? 0
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Rectangle()
                .fill(self.secondary.opacity(0.24))
                .frame(height: 1)
            HStack(spacing: 18) {
                Label("Generated locally by CodexBar", systemImage: "lock.shield")
                Spacer()
                Text("Only aggregate usage included")
                Circle().fill(self.secondary.opacity(0.6)).frame(width: 4, height: 4)
                Text("Data through \(ShareStatsFormatting.dataThrough(self.payload.periodEnd))")
            }
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(self.secondary)
        }
    }
}

private struct ShareStatsModelRow: View {
    let rank: Int
    let subscriptionRank: Int
    let model: ShareStatsModelPayload
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.color)
                .frame(width: 25, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.model.modelName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("subscription \(String(format: "%02d", self.subscriptionRank)) · \(self.model.providerName)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(self.color)
            }
            Spacer(minLength: 10)
            Text(self.detail)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.73, green: 0.70, blue: 0.65))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(self.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(self.color.opacity(0.62), lineWidth: 1)
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
        HStack(spacing: 10) {
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.color)
                .frame(width: 28, height: 25)
                .background(self.color.opacity(0.21), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(self.color.opacity(0.62), lineWidth: 1)
                }
            HStack(spacing: 8) {
                Text(self.provider.providerName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                if let subscriptionName = self.provider.subscriptionName {
                    Text(subscriptionName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(self.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(self.color.opacity(0.20), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(self.color.opacity(0.50), lineWidth: 1)
                        }
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(self.detail)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.73, green: 0.70, blue: 0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(self.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(self.color.opacity(0.62), lineWidth: 1)
        }
    }

    private var detail: String {
        var metrics: [String] = []
        if let tokens = self.provider.totalTokens {
            metrics.append(ShareStatsFormatting.compactCount(tokens))
        }
        if let cost = self.provider.estimatedCostUSD, cost.isFinite {
            metrics.append("~\(ShareStatsFormatting.currencyUSD(cost))")
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
        let series = self.providers.enumerated().map { index, provider in
            Series(id: provider.id, values: provider.dailyTokens, color: ShareStatsPalette.color(at: index))
        }
        let dayCount = series.map(\.values.count).max() ?? 0
        let totals = (0..<dayCount).map { day in
            series.reduce(0) { total, item in
                total + (item.values.indices.contains(day) ? item.values[day] : 0)
            }
        }
        let maximum = max(Double(totals.max() ?? 0), 1)

        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<dayCount, id: \.self) { day in
                    let total = totals[day]
                    if total == 0 {
                        Capsule()
                            .fill(self.emptyColor.opacity(0.13))
                            .frame(maxWidth: .infinity, maxHeight: 3)
                    } else {
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            ForEach(Array(series.reversed())) { item in
                                let value = item.values.indices.contains(day) ? item.values[day] : 0
                                if value > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(item.color.opacity(0.96))
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

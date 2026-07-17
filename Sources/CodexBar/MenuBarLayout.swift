import CodexBarCore
import Foundation

enum PercentWindow: String, CaseIterable, Codable, Hashable, Sendable {
    case session
    case weekly
    case automatic
}

enum MenuBarLayoutToken: Codable, Hashable, Sendable {
    case icon
    case providerName
    case accountLabel
    case percent(window: PercentWindow)
    case usageBar
    case resetCountdown
    case resetAbsolute
    case runsOut
    case costToday
    case cost30d
    case separatorDot
    case space
}

struct MenuBarLayout: Codable, Hashable, Sendable {
    static let defaultLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])

    let lines: [[MenuBarLayoutToken]]

    init(lines: [[MenuBarLayoutToken]]) {
        self.lines = Self.normalizedLines(lines)
    }

    private enum CodingKeys: String, CodingKey {
        case lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lines: container.decode([[MenuBarLayoutToken]].self, forKey: .lines))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.lines, forKey: .lines)
    }

    private static func normalizedLines(_ lines: [[MenuBarLayoutToken]]) -> [[MenuBarLayoutToken]] {
        let nonemptyLines = lines.filter { !$0.isEmpty }.prefix(2)
        return nonemptyLines.isEmpty ? Self.defaultLayout.lines : Array(nonemptyLines)
    }
}

enum MenuBarLayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case iconAndPercent
    case iconOnly
    case percentAndReset
    case compactStacked
    case custom

    var id: String {
        self.rawValue
    }

    var layout: MenuBarLayout? {
        switch self {
        case .iconAndPercent:
            MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        case .iconOnly:
            MenuBarLayout(lines: [[.icon]])
        case .percentAndReset:
            MenuBarLayout(lines: [[
                .icon,
                .percent(window: .automatic),
                .separatorDot,
                .resetCountdown,
            ]])
        case .compactStacked:
            MenuBarLayout(lines: [
                [.percent(window: .session)],
                [.percent(window: .weekly)],
            ])
        case .custom:
            nil
        }
    }

    static func matching(_ layout: MenuBarLayout) -> Self {
        allCases.first { $0.layout == layout } ?? .custom
    }
}

enum MenuBarLayoutSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case regular

    var id: String {
        self.rawValue
    }
}

enum MenuBarLayoutGap: String, CaseIterable, Identifiable, Sendable {
    case tight
    case regular

    var id: String {
        self.rawValue
    }
}

struct MenuBarLayoutResolution: Equatable {
    struct LegacySettings: Equatable {
        let iconStyle: MenuBarIconStyle
        let displayMode: MenuBarDisplayMode
        let metricPreference: MenuBarMetricPreference
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
    }

    let layout: MenuBarLayout
    let legacySettings: LegacySettings?

    var usesLegacyRendering: Bool {
        self.legacySettings != nil
    }

    static func stored(_ layout: MenuBarLayout) -> Self {
        Self(layout: layout, legacySettings: nil)
    }

    static func legacy(
        iconStyle: MenuBarIconStyle,
        displayMode: MenuBarDisplayMode,
        metricPreference: MenuBarMetricPreference,
        resetTimeDisplayStyle: ResetTimeDisplayStyle)
        -> Self
    {
        Self(
            layout: MenuBarLayout.migrated(
                iconStyle: iconStyle,
                displayMode: displayMode,
                metricPreference: metricPreference,
                resetTimeDisplayStyle: resetTimeDisplayStyle),
            legacySettings: LegacySettings(
                iconStyle: iconStyle,
                displayMode: displayMode,
                metricPreference: metricPreference,
                resetTimeDisplayStyle: resetTimeDisplayStyle))
    }
}

extension MenuBarLayout {
    static func migrated(
        iconStyle: MenuBarIconStyle,
        displayMode: MenuBarDisplayMode,
        metricPreference: MenuBarMetricPreference,
        resetTimeDisplayStyle: ResetTimeDisplayStyle)
        -> MenuBarLayout
    {
        _ = iconStyle // Critters and bars keep rendering through their unchanged legacy path.
        let icon: MenuBarLayoutToken = .icon
        switch displayMode {
        case .percent:
            if metricPreference == .primaryAndSecondary {
                return MenuBarLayout(lines: [[
                    icon,
                    .percent(window: .session),
                    .separatorDot,
                    .percent(window: .weekly),
                ]])
            }
            return MenuBarLayout(lines: [[icon, .percent(window: Self.percentWindow(for: metricPreference))]])
        case .pace:
            return MenuBarLayout(lines: [[icon, .runsOut]])
        case .both:
            return MenuBarLayout(lines: [[
                icon,
                .percent(window: Self.percentWindow(for: metricPreference)),
                .separatorDot,
                .runsOut,
            ]])
        case .resetTime:
            let resetItem = resetTimeDisplayStyle == .absolute
                ? MenuBarLayoutToken.resetAbsolute
                : MenuBarLayoutToken.resetCountdown
            return MenuBarLayout(lines: [[icon, resetItem]])
        }
    }

    private static func percentWindow(for preference: MenuBarMetricPreference) -> PercentWindow {
        switch preference {
        case .primary:
            .session
        case .secondary:
            .weekly
        case .automatic, .primaryAndSecondary, .tertiary, .extraUsage, .average, .monthlyPlan:
            .automatic
        }
    }
}

import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static let sessionEquivalentHistoryIdentityDefaultsKey =
        "SessionEquivalentHistoryWeeklyWindowIDsV1"
    nonisolated static let sessionEquivalentStandardWindowIdentity = "__standard__"

    func planUtilizationWeeklyWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .antigravity {
            let namedWeeklyWindows = snapshot.extraRateWindows?
                .filter {
                    $0.usageKnown
                        && $0.id.hasPrefix("antigravity-quota-summary-")
                        && $0.window.windowMinutes == Self.weeklyWindowMinutes
                }
                .map(\.window) ?? []
            if let mostUsedWeeklyWindow = namedWeeklyWindows.max(by: { $0.usedPercent < $1.usedPercent }) {
                return mostUsedWeeklyWindow
            }

            let legacyWeeklyWindows = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
                .compactMap(\.self)
                .filter { $0.windowMinutes == Self.weeklyWindowMinutes }
                + (snapshot.extraRateWindows?
                    .filter { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }
                    .map(\.window) ?? [])
            return legacyWeeklyWindows.max(by: { $0.usedPercent < $1.usedPercent })
        }

        let standardWeeklyWindow = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == Self.weeklyWindowMinutes }
        let extraWeeklyWindow = snapshot.extraRateWindows?
            .lazy
            .first { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }?
            .window
        return standardWeeklyWindow ?? extraWeeklyWindow
    }

    func sessionEquivalentWindows(provider: UsageProvider, snapshot: UsageSnapshot)
        -> (session: RateWindow, weekly: RateWindow, weeklyWindowID: String?)?
    {
        if provider == .antigravity {
            return Self.antigravitySessionEquivalentWindows(snapshot: snapshot)
        }
        let standardWeekly = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == Self.weeklyWindowMinutes }
        let namedWeekly = snapshot.extraRateWindows?
            .lazy
            .first { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }
        guard let session = self.planUtilizationSessionWindow(provider: provider, snapshot: snapshot),
              let weekly = standardWeekly ?? namedWeekly?.window
        else {
            return nil
        }
        return (session, weekly, standardWeekly == nil ? namedWeekly?.id : nil)
    }

    func sessionEquivalentHistoryIdentityMatches(
        provider: UsageProvider,
        accountKey: String?,
        weeklyWindowID: String?) -> Bool
    {
        guard ![UsageProvider.codex, .claude, .antigravity].contains(provider) else { return true }
        let identityKey = Self.sessionEquivalentHistoryIdentityKey(provider: provider, accountKey: accountKey)
        let identities = self.settings.userDefaults.dictionary(
            forKey: Self.sessionEquivalentHistoryIdentityDefaultsKey) as? [String: String]
        return identities?[identityKey] == (weeklyWindowID ?? Self.sessionEquivalentStandardWindowIdentity)
    }

    nonisolated static func sessionEquivalentHistoryIdentityKey(
        provider: UsageProvider,
        accountKey: String?) -> String
    {
        "\(provider.rawValue)|\(accountKey ?? self.planUtilizationUnscopedPreferredKey)"
    }

    func planUtilizationSessionWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        let standardSessionWindow = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == Self.sessionWindowMinutes }
        let extraSessionWindow = snapshot.extraRateWindows?
            .lazy
            .first { $0.usageKnown && $0.window.windowMinutes == Self.sessionWindowMinutes }?
            .window
        return standardSessionWindow
            ?? self.sessionQuotaWindow(provider: provider, snapshot: snapshot)?.window
            ?? extraSessionWindow
    }

    private nonisolated static func antigravitySessionEquivalentWindows(snapshot: UsageSnapshot)
        -> (session: RateWindow, weekly: RateWindow, weeklyWindowID: String?)?
    {
        let namedWindows = snapshot.extraRateWindows?
            .filter { $0.usageKnown && $0.id.hasPrefix("antigravity-quota-summary-") } ?? []
        let grouped = Dictionary(grouping: namedWindows) { window in
            Self.antigravityQuotaFamilyKey(window.id)
        }
        let completeGeminiFamilies: [(session: NamedRateWindow, weekly: NamedRateWindow)] = grouped.keys
            .filter { $0 == "gemini" }.compactMap { family in
                guard let windows = grouped[family] else { return nil }
                let sessions = windows.filter { $0.window.windowMinutes == Self.sessionWindowMinutes }
                let weeklies = windows.filter { $0.window.windowMinutes == Self.weeklyWindowMinutes }
                guard sessions.count == 1, weeklies.count == 1 else { return nil }
                return (session: sessions[0], weekly: weeklies[0])
            }
        guard completeGeminiFamilies.count == 1, let pair = completeGeminiFamilies.first else { return nil }
        return (pair.session.window, pair.weekly.window, pair.weekly.id)
    }

    private nonisolated static func antigravityQuotaFamilyKey(_ id: String) -> String {
        var key = String(id.dropFirst("antigravity-quota-summary-".count)).lowercased()
        let suffixes = [
            "-5h limit", "_5h_limit", "-weekly", "_weekly", " weekly",
            "-session", "_session", " session", "-5h", "_5h", " 5h",
        ]
        if let suffix = suffixes.first(where: { key.hasSuffix($0) }) {
            key.removeLast(suffix.count)
        } else if ["weekly", "session", "5h"].contains(key) {
            key = ""
        }
        return key
    }
}

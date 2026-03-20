import CodexBarCore
import Foundation

struct PlanUtilizationSeriesName: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let session: Self = "session"
    static let weekly: Self = "weekly"
    static let opus: Self = "opus"
}

struct PlanUtilizationHistoryEntry: Codable, Sendable, Equatable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct PlanUtilizationSeriesHistory: Codable, Sendable, Equatable {
    let name: PlanUtilizationSeriesName
    let windowMinutes: Int
    let entries: [PlanUtilizationHistoryEntry]

    init(name: PlanUtilizationSeriesName, windowMinutes: Int, entries: [PlanUtilizationHistoryEntry]) {
        self.name = name
        self.windowMinutes = windowMinutes
        self.entries = entries.sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            let lhsReset = lhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            let rhsReset = rhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            return lhsReset < rhsReset
        }
    }

    var latestCapturedAt: Date? {
        self.entries.last?.capturedAt
    }
}

struct PlanUtilizationHistoryBuckets: Sendable, Equatable {
    var preferredAccountKey: String?
    var unscoped: [PlanUtilizationSeriesHistory] = []
    var accounts: [String: [PlanUtilizationSeriesHistory]] = [:]

    func histories(for accountKey: String?) -> [PlanUtilizationSeriesHistory] {
        guard let accountKey, !accountKey.isEmpty else { return self.unscoped }
        return self.accounts[accountKey] ?? []
    }

    mutating func setHistories(_ histories: [PlanUtilizationSeriesHistory], for accountKey: String?) {
        let sorted = Self.sortedHistories(histories)
        guard let accountKey, !accountKey.isEmpty else {
            self.unscoped = sorted
            return
        }
        if sorted.isEmpty {
            self.accounts.removeValue(forKey: accountKey)
        } else {
            self.accounts[accountKey] = sorted
        }
    }

    var isEmpty: Bool {
        self.unscoped.isEmpty && self.accounts.values.allSatisfy(\.isEmpty)
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        histories.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }
}

private struct PlanUtilizationHistoryFile: Codable, Sendable {
    let version: Int
    let providers: [String: ProviderHistoryFile]
}

private struct ProviderHistoryFile: Codable, Sendable {
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
}

struct PlanUtilizationHistoryStore: Sendable {
    fileprivate static let schemaVersion = 6

    let fileURL: URL?

    init(fileURL: URL? = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultAppSupport() -> Self {
        Self()
    }

    func load() -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        guard let url = self.fileURL else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PlanUtilizationHistoryFile.self, from: data) else {
            return [:]
        }
        return Self.decodeProviders(decoded.providers)
    }

    func save(_ providers: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        guard let url = self.fileURL else { return }
        let persistedProviders = providers.reduce(into: [String: ProviderHistoryFile]()) { output, entry in
            let (provider, buckets) = entry
            guard !buckets.isEmpty else { return }
            let accounts: [String: [PlanUtilizationSeriesHistory]] = Dictionary(
                uniqueKeysWithValues: buckets.accounts.compactMap { accountKey, histories in
                    let sorted = Self.sortedHistories(histories)
                    guard !sorted.isEmpty else { return nil }
                    return (accountKey, sorted)
                })
            output[provider.rawValue] = ProviderHistoryFile(
                preferredAccountKey: buckets.preferredAccountKey,
                unscoped: Self.sortedHistories(buckets.unscoped),
                accounts: accounts)
        }

        let payload = PlanUtilizationHistoryFile(
            version: Self.schemaVersion,
            providers: persistedProviders)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: Data.WritingOptions.atomic)
        } catch {
            // Best-effort persistence only.
        }
    }

    private static func decodeProviders(
        _ providers: [String: ProviderHistoryFile]) -> [UsageProvider: PlanUtilizationHistoryBuckets]
    {
        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]
        for (rawProvider, providerHistory) in providers {
            guard let provider = UsageProvider(rawValue: rawProvider) else { continue }
            output[provider] = PlanUtilizationHistoryBuckets(
                preferredAccountKey: providerHistory.preferredAccountKey,
                unscoped: Self.sortedHistories(providerHistory.unscoped),
                accounts: Dictionary(
                    uniqueKeysWithValues: providerHistory.accounts.compactMap { accountKey, histories in
                        let sorted = Self.sortedHistories(histories)
                        guard !sorted.isEmpty else { return nil }
                        return (accountKey, sorted)
                    }))
        }
        return output
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        histories.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("plan-utilization-history.json")
    }
}

extension PlanUtilizationHistoryFile {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == PlanUtilizationHistoryStore.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported plan utilization history schema version \(version)")
        }
        self.version = version
        self.providers = try container.decode([String: ProviderHistoryFile].self, forKey: .providers)
    }
}

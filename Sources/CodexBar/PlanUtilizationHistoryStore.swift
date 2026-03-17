import CodexBarCore
import Foundation

struct PlanUtilizationHistorySample: Codable, Sendable, Equatable {
    let capturedAt: Date
    let dailyUsedPercent: Double?
    let weeklyUsedPercent: Double?
    let monthlyUsedPercent: Double?
}

struct PlanUtilizationHistoryBuckets: Sendable, Equatable {
    var unscoped: [PlanUtilizationHistorySample] = []
    var accounts: [String: [PlanUtilizationHistorySample]] = [:]

    func samples(for accountKey: String?) -> [PlanUtilizationHistorySample] {
        guard let accountKey, !accountKey.isEmpty else { return self.unscoped }
        return self.accounts[accountKey] ?? []
    }

    mutating func setSamples(_ samples: [PlanUtilizationHistorySample], for accountKey: String?) {
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
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
}

private struct PlanUtilizationHistoryFile: Codable, Sendable {
    let version: Int
    let providers: [String: ProviderHistoryFile]
}

private struct ProviderHistoryFile: Codable, Sendable {
    let unscoped: [PlanUtilizationHistorySample]
    let accounts: [String: [PlanUtilizationHistorySample]]
}

private struct LegacyPlanUtilizationHistoryFile: Codable, Sendable {
    let providers: [String: [PlanUtilizationHistorySample]]
}

struct PlanUtilizationHistoryStore: Sendable {
    private static let schemaVersion = 2

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
        if let decoded = try? decoder.decode(PlanUtilizationHistoryFile.self, from: data) {
            return Self.decodeProviders(decoded.providers)
        }
        guard let legacy = try? decoder.decode(LegacyPlanUtilizationHistoryFile.self, from: data) else {
            return [:]
        }
        return Self.decodeLegacyProviders(legacy.providers)
    }

    func save(_ providers: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        guard let url = self.fileURL else { return }
        let persistedProviders = providers.reduce(into: [String: ProviderHistoryFile]()) { output, entry in
            let (provider, buckets) = entry
            guard !buckets.isEmpty else { return }
            let accounts: [String: [PlanUtilizationHistorySample]] = Dictionary(
                uniqueKeysWithValues: buckets.accounts.compactMap { accountKey, samples in
                    let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
                    guard !sorted.isEmpty else { return nil }
                    return (accountKey, sorted)
                })
            output[provider.rawValue] = ProviderHistoryFile(
                unscoped: buckets.unscoped.sorted { $0.capturedAt < $1.capturedAt },
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
                unscoped: providerHistory.unscoped.sorted { $0.capturedAt < $1.capturedAt },
                accounts: Dictionary(
                    uniqueKeysWithValues: providerHistory.accounts.compactMap { accountKey, samples in
                        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
                        guard !sorted.isEmpty else { return nil }
                        return (accountKey, sorted)
                    }))
        }
        return output
    }

    private static func decodeLegacyProviders(
        _ providers: [String: [PlanUtilizationHistorySample]]) -> [UsageProvider: PlanUtilizationHistoryBuckets]
    {
        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]
        for (rawProvider, samples) in providers {
            guard let provider = UsageProvider(rawValue: rawProvider) else { continue }
            output[provider] = PlanUtilizationHistoryBuckets(
                unscoped: samples.sorted { $0.capturedAt < $1.capturedAt })
        }
        return output
    }

    private static func defaultFileURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("plan-utilization-history.json")
    }
}

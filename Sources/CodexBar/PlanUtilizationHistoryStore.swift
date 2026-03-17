import CodexBarCore
import Foundation

struct PlanUtilizationHistorySample: Codable, Sendable, Equatable {
    let capturedAt: Date
    let primaryUsedPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetsAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetsAt: Date?
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

struct PlanUtilizationHistoryStore: Sendable {
    private static let schemaVersion = 3

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
        guard version == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported plan utilization history schema version \(version)")
        }
        self.version = version
        self.providers = try container.decode([String: ProviderHistoryFile].self, forKey: .providers)
    }
}

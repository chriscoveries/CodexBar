import CodexBarCore
import Foundation

struct PlanUtilizationHistorySample: Codable, Sendable, Equatable {
    let capturedAt: Date
    let dailyUsedPercent: Double?
    let weeklyUsedPercent: Double?
    let monthlyUsedPercent: Double?
}

private struct PlanUtilizationHistoryFile: Codable, Sendable {
    let providers: [String: [PlanUtilizationHistorySample]]
}

enum PlanUtilizationHistoryStore {
    static func load(fileManager: FileManager = .default) -> [UsageProvider: [PlanUtilizationHistorySample]] {
        guard let url = self.fileURL(fileManager: fileManager) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PlanUtilizationHistoryFile.self, from: data) else {
            return [:]
        }

        var output: [UsageProvider: [PlanUtilizationHistorySample]] = [:]
        for (rawProvider, samples) in decoded.providers {
            guard let provider = UsageProvider(rawValue: rawProvider) else { continue }
            output[provider] = samples.sorted { $0.capturedAt < $1.capturedAt }
        }
        return output
    }

    static func save(
        _ providers: [UsageProvider: [PlanUtilizationHistorySample]],
        fileManager: FileManager = .default)
    {
        guard let url = self.fileURL(fileManager: fileManager) else { return }

        let payload = PlanUtilizationHistoryFile(
            providers: Dictionary(
                uniqueKeysWithValues: providers.map { provider, samples in
                    (provider.rawValue, samples)
                }))

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort persistence only.
        }
    }

    private static func fileURL(fileManager: FileManager) -> URL? {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("plan-utilization-history.json")
    }
}

import Foundation

public struct CodexLocalProjectUsageIndexStore: Sendable {
    private let cacheRoot: URL?

    public init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot
    }

    public func loadSnapshot(
        expectedScopeSignature: String? = nil,
        expectedHistoryDays: Int? = nil) -> CodexLocalProjectUsageSnapshot?
    {
        guard let data = try? Data(contentsOf: self.cacheFileURL()),
              let decoded = try? JSONDecoder.codexLocalProjectUsage.decode(Cache.self, from: data),
              decoded.version == 1
        else { return nil }
        if let expectedScopeSignature, decoded.snapshot.scopeSignature != expectedScopeSignature {
            return nil
        }
        if let expectedHistoryDays, decoded.snapshot.historyDays != expectedHistoryDays {
            return nil
        }
        guard decoded.snapshot.hasInspectorDetail else { return nil }
        return decoded.snapshot
    }

    public func saveSnapshot(_ snapshot: CodexLocalProjectUsageSnapshot) {
        let url = self.cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Cache(version: 1, snapshot: snapshot)
        guard let data = try? JSONEncoder.codexLocalProjectUsage.encode(payload) else { return }
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: self.cacheFileURL())
    }

    private func cacheFileURL() -> URL {
        let root = self.cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("local-usage", isDirectory: true)
            .appendingPathComponent("codex-project-v1.json", isDirectory: false)
    }

    private struct Cache: Codable {
        let version: Int
        let snapshot: CodexLocalProjectUsageSnapshot
    }
}

extension JSONDecoder {
    static var codexLocalProjectUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var codexLocalProjectUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

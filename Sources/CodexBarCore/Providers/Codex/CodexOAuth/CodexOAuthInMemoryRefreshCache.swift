import Foundation

/// Coordinates OAuth refreshes inside CodexBar without publishing token material to a source file.
///
/// Codex CLI owns its native `auth.json` and may atomically replace it while a usage probe is in
/// flight. Keeping the rotated credentials in this process avoids both a cross-writer race and a
/// second refresh request from concurrent provider/account probes. A subsequent read with a new
/// source token snapshot (for example after a CLI login) naturally bypasses the old entry.
actor CodexOAuthInMemoryRefreshCache {
    static let shared = CodexOAuthInMemoryRefreshCache()

    private struct Entry {
        let sourceRefreshToken: String
        let credentials: CodexOAuthCredentials
        let lastUsed: UInt64
    }

    private let maximumEntries = 16
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<CodexOAuthCredentials, Error>] = [:]
    private var useCounter: UInt64 = 0

    func refreshIfNeeded(
        credentials: CodexOAuthCredentials,
        cacheKey: String,
        refresh: @escaping @Sendable () async throws -> CodexOAuthCredentials) async throws
        -> CodexOAuthCredentials
    {
        guard !credentials.isAPIKey, credentials.needsRefresh else { return credentials }
        guard !credentials.refreshToken.isEmpty else { return credentials }

        if let entry = self.entries[cacheKey], entry.sourceRefreshToken == credentials.refreshToken {
            // The source read is stale by construction here. Retain the in-memory rotation until
            // the source publishes a new token snapshot; a fresh snapshot has a new cache key.
            if !entry.credentials.needsRefresh {
                self.useCounter &+= 1
                self.entries[cacheKey] = Entry(
                    sourceRefreshToken: entry.sourceRefreshToken,
                    credentials: entry.credentials,
                    lastUsed: self.useCounter)
                return entry.credentials
            }
        }

        if let task = self.inFlight[cacheKey] {
            return try await task.value
        }

        let task = Task { try await refresh() }
        self.inFlight[cacheKey] = task
        do {
            let refreshed = try await task.value
            self.inFlight.removeValue(forKey: cacheKey)
            self.useCounter &+= 1
            self.entries[cacheKey] = Entry(
                sourceRefreshToken: credentials.refreshToken,
                credentials: refreshed,
                lastUsed: self.useCounter)
            self.trimToMaximumEntries()
            return refreshed
        } catch {
            self.inFlight.removeValue(forKey: cacheKey)
            throw error
        }
    }

    #if DEBUG
    func _resetForTesting() {
        self.entries.removeAll()
        self.inFlight.removeAll()
        self.useCounter = 0
    }
    #endif

    private func trimToMaximumEntries() {
        guard self.entries.count > self.maximumEntries else { return }
        let removeCount = self.entries.count - self.maximumEntries
        let keysToRemove = self.entries
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(removeCount)
            .map(\.key)
        for key in keysToRemove {
            self.entries.removeValue(forKey: key)
        }
    }
}

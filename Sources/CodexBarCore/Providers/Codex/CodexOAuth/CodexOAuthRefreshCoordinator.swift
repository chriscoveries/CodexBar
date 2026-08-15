#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Crypto
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coordinates native Codex OAuth refreshes across concurrent CodexBar tasks and processes.
///
/// OpenAI may rotate a refresh grant. A process-local single-flight prevents two in-process
/// callers from consuming the same grant, while the advisory `flock` prevents two CodexBar
/// processes from running the same read-modify-write cycle. The generation check remains the
/// final fence: a newer login on disk is never overwritten by an older refresh result.
actor CodexOAuthRefreshCoordinator {
    static let shared = CodexOAuthRefreshCoordinator()

    private var flights: [String: Task<CodexOAuthCredentials, Error>] = [:]

    func refreshAndPersist(
        _ credentials: CodexOAuthCredentials,
        env: [String: String],
        transport: any ProviderHTTPTransport) async throws -> CodexOAuthCredentials
    {
        guard credentials.source == .codexHome else {
            if credentials.needsRefresh {
                throw CodexOAuthCredentialsError.readOnlySource
            }
            return credentials
        }
        guard credentials.needsRefresh, !credentials.refreshToken.isEmpty else {
            return credentials
        }

        let key = Self.flightKey(credentials: credentials, env: env)
        if let existing = self.flights[key] {
            return try await existing.value
        }

        let task = Task { [credentials, env, transport] in
            try await Self.performRefreshAndPersist(
                credentials,
                env: env,
                transport: transport)
        }
        self.flights[key] = task
        do {
            let result = try await task.value
            self.flights[key] = nil
            return result
        } catch {
            self.flights[key] = nil
            throw error
        }
    }

    private static func flightKey(
        credentials: CodexOAuthCredentials,
        env: [String: String]) -> String
    {
        let lockPath = CodexOAuthCredentialsStore.refreshLockURL(env: env).path
        let grantFingerprint = SHA256.hash(data: Data(credentials.refreshToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(lockPath)\u{0}\(grantFingerprint)"
    }

    private static func performRefreshAndPersist(
        _ credentials: CodexOAuthCredentials,
        env: [String: String],
        transport: any ProviderHTTPTransport) async throws -> CodexOAuthCredentials
    {
        try await self.withNativeRefreshLock(env: env) {
            let locked = try CodexOAuthCredentialsStore.loadNativeSnapshot(env: env).credentials

            // Another caller may have completed the rotation before this process acquired the
            // file lock. Reuse a fresh newer credential and never refresh the old grant again.
            if !CodexOAuthCredentialsStore.tokenMaterialMatches(locked, credentials) {
                guard locked.needsRefresh, !locked.refreshToken.isEmpty else {
                    return locked
                }
            }
            guard locked.needsRefresh, !locked.refreshToken.isEmpty else {
                return locked
            }

            let updated = try await CodexTokenRefresher.refresh(locked, session: transport)
            guard try CodexOAuthCredentialsStore.saveIfCurrent(
                updated,
                expected: locked,
                env: env)
            else {
                let current = try CodexOAuthCredentialsStore.loadNativeSnapshot(env: env).credentials
                if !current.needsRefresh {
                    return current
                }
                throw CodexTokenRefresher.RefreshError.generationConflict
            }
            return updated
        }
    }

    private static func withNativeRefreshLock<Value: Sendable>(
        env: [String: String],
        operation: () async throws -> Value) async throws -> Value
    {
        let lockURL = CodexOAuthCredentialsStore.refreshLockURL(env: env)
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = lockURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw CodexTokenRefresher.RefreshError.lockUnavailable(Self.posixMessage(
                errno,
                path: lockURL.path))
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw CodexTokenRefresher.RefreshError.lockUnavailable(Self.posixMessage(
                errno,
                path: lockURL.path))
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw CodexTokenRefresher.RefreshError.lockUnavailable(Self.posixMessage(
                    code,
                    path: lockURL.path))
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        return try await operation()
    }

    private static func posixMessage(_ code: Int32, path: String) -> String {
        "\(String(cString: strerror(code))) (\(path))"
    }
}

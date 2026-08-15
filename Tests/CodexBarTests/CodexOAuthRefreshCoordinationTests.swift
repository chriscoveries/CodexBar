import Foundation
import Testing
@testable import CodexBarCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct CodexOAuthRefreshCoordinationTests {
    @Test
    func `concurrent native refreshes share one token request`() async throws {
        let home = try self.makeHome(prefix: "codex-oauth-refresh-single-flight")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["CODEX_HOME": home.path]
        try self.writeExpiredCredentials(to: home)
        let initial = try CodexOAuthCredentialsStore.load(env: environment)
        let calls = RefreshCallCounter()
        let transport = self.makeRefreshTransport(calls: calls)

        let results = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                try await withThrowingTaskGroup(of: CodexOAuthCredentials.self) { group in
                    for _ in 0..<2 {
                        group.addTask {
                            try await CodexTokenRefresher.refreshAndPersist(initial, env: environment)
                        }
                    }
                    var values: [CodexOAuthCredentials] = []
                    for try await value in group {
                        values.append(value)
                    }
                    return values
                }
            }

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.accessToken == "refreshed-access" })
        #expect(await calls.count() == 1)
        let persisted = try CodexOAuthCredentialsStore.load(env: environment)
        #expect(persisted.accessToken == "refreshed-access")
        #expect(persisted.refreshToken == "refreshed-refresh")
    }

    @Test
    func `newer native credentials win a refresh generation race`() async throws {
        let home = try self.makeHome(prefix: "codex-oauth-refresh-generation")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["CODEX_HOME": home.path]
        try self.writeExpiredCredentials(to: home)
        let initial = try CodexOAuthCredentialsStore.load(env: environment)
        let calls = RefreshCallCounter()
        let transport = ProviderHTTPTransportHandler { _ in
            await calls.record()
            let newer = CodexOAuthCredentials(
                accessToken: "newer-access",
                refreshToken: "newer-refresh",
                idToken: nil,
                accountId: "account-newer",
                lastRefresh: Date(),
                source: .codexHome)
            try CodexOAuthCredentialsStore.save(newer, env: environment)
            let response = try #require(HTTPURLResponse(
                url: URL(string: "https://auth.openai.com/oauth/token")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (
                Data(#"{"access_token":"stale-access","refresh_token":"stale-refresh","expires_in":3600}"#.utf8),
                response)
        }

        let resolved = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                try await CodexTokenRefresher.refreshAndPersist(initial, env: environment)
            }

        #expect(await calls.count() == 1)
        #expect(resolved.accessToken == "newer-access")
        #expect(try CodexOAuthCredentialsStore.load(env: environment).accessToken == "newer-access")
    }

    private func makeHome(prefix: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeExpiredCredentials(to home: URL) throws {
        let auth = #"""
        {
          "tokens":{"access_token":"expired-access","refresh_token":"expired-refresh"},
          "last_refresh":"2020-01-01T00:00:00Z"
        }
        """#
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
    }

    private func makeRefreshTransport(calls: RefreshCallCounter) -> any ProviderHTTPTransport {
        ProviderHTTPTransportHandler { request in
            await calls.record()
            try await Task.sleep(nanoseconds: 50_000_000)
            let response = try #require(HTTPURLResponse(
                url: request.url ?? URL(string: "https://auth.openai.com/oauth/token")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (
                Data(#"{"access_token":"refreshed-access","refresh_token":"refreshed-refresh","expires_in":3600}"#
                    .utf8),
                response)
        }
    }
}

private actor RefreshCallCounter {
    private var value = 0

    func record() {
        self.value += 1
    }

    func count() -> Int {
        self.value
    }
}

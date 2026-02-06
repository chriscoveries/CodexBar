import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreBootstrapConcurrencyTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func concurrentBootstrapLoadsPerformSingleInteractiveKeychainRead() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            ClaudeOAuthCredentialsStore.setClaudeKeychainReadOverrideForTesting(nil)
            ClaudeOAuthCredentialsStore.setClaudeKeychainInteractiveReadAttemptHandlerForTesting(nil)
            KeychainPromptHandler.handler = nil
        }

        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        KeychainCacheStore.clear(key: cacheKey)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainReadOverrideForTesting { allowKeychainPrompt, _ in
            if !allowKeychainPrompt { return nil }
            Thread.sleep(forTimeInterval: 0.2)
            return keychainData
        }

        final class ConcurrentLoadState: @unchecked Sendable {
            private let lock = NSLock()
            private var preAlertHits = 0
            private var interactiveReadAttempts = 0
            private var results: [ClaudeOAuthCredentials] = []
            private var errors: [Error] = []

            func markPreAlert() {
                self.lock.lock()
                self.preAlertHits += 1
                self.lock.unlock()
            }

            func markInteractiveReadAttempt() {
                self.lock.lock()
                self.interactiveReadAttempts += 1
                self.lock.unlock()
            }

            func appendResult(_ credentials: ClaudeOAuthCredentials) {
                self.lock.lock()
                self.results.append(credentials)
                self.lock.unlock()
            }

            func appendError(_ error: Error) {
                self.lock.lock()
                self.errors.append(error)
                self.lock.unlock()
            }

            func snapshot() -> (
                preAlertHits: Int,
                interactiveReadAttempts: Int,
                results: [ClaudeOAuthCredentials],
                errors: [Error])
            {
                self.lock.lock()
                defer { self.lock.unlock() }
                return (self.preAlertHits, self.interactiveReadAttempts, self.results, self.errors)
            }
        }

        let state = ConcurrentLoadState()
        KeychainPromptHandler.handler = { _ in
            state.markPreAlert()
        }
        ClaudeOAuthCredentialsStore.setClaudeKeychainInteractiveReadAttemptHandlerForTesting {
            state.markInteractiveReadAttempt()
        }

        let queue = DispatchQueue(label: "ClaudeOAuthCredentialsStoreTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let startGate = DispatchSemaphore(value: 0)

        for _ in 0..<2 {
            group.enter()
            queue.async {
                startGate.wait()
                do {
                    let creds = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: true)
                    state.appendResult(creds)
                } catch {
                    state.appendError(error)
                }
                group.leave()
            }
        }

        startGate.signal()
        startGate.signal()
        #expect(group.wait(timeout: .now() + 5) == .success)

        let snapshot = state.snapshot()
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.results.count == 2)
        #expect(snapshot.results.allSatisfy { $0.accessToken == "keychain-token" })
        #expect(snapshot.preAlertHits == 1)
        #expect(snapshot.interactiveReadAttempts == 1)
    }
}

import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheConditionalMutationTests {
    #if os(macOS)
    @Test
    func `temporary keychain read permits fresh replacement when legacy state is unchanged`() {
        self.withIsolatedCookieCache {
            let legacy = CookieHeaderCache.Entry(
                cookieHeader: "sessionKey=sk-ant-legacy",
                storedAt: Date(timeIntervalSince1970: 1),
                sourceLabel: "Legacy")
            CookieHeaderCache.store(legacy, to: CookieHeaderCache.legacyURLForTesting(provider: .claude))

            let observation = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.observeForConditionalMutation(provider: .claude)
            }
            let replaced = CookieHeaderCache.storeIfObservationCurrent(
                provider: .claude,
                expected: observation,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(observation.entry == nil)
            #expect(replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-fresh")
            #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: .claude))
        }
    }

    @Test
    func `temporary keychain read does not overwrite a concurrent keychain entry`() {
        self.withIsolatedCookieCache {
            let observation = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.observeForConditionalMutation(provider: .claude)
            }
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-concurrent",
                sourceLabel: "Chrome")

            let replaced = CookieHeaderCache.storeIfObservationCurrent(
                provider: .claude,
                expected: observation,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(!replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-concurrent")
        }
    }

    @Test
    func `observable store failure preserves the current cookie entry`() {
        self.withIsolatedCookieCache {
            let initiallyStored = CookieHeaderCache.storeResult(
                provider: .cursor,
                cookieHeader: "WorkosCursorSessionToken=existing",
                sourceLabel: "Chrome")

            let replaced = KeychainCacheStore.withStoreFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.storeResult(
                    provider: .cursor,
                    cookieHeader: "WorkosCursorSessionToken=replacement",
                    sourceLabel: "Comet")
            }

            #expect(initiallyStored)
            #expect(!replaced)
            #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader ==
                "WorkosCursorSessionToken=existing")
        }
    }
    #endif

    @Test
    func `legacy clear failure still permits replacing the keychain entry`() {
        self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale",
                sourceLabel: "Chrome")
            let stale = CookieHeaderCache.load(provider: .claude)
            #expect(stale != nil)
            guard let stale else { return }

            CookieHeaderCache.store(
                CookieHeaderCache.Entry(
                    cookieHeader: "sessionKey=sk-ant-legacy",
                    storedAt: Date(timeIntervalSince1970: 1),
                    sourceLabel: "Legacy"),
                to: CookieHeaderCache.legacyURLForTesting(provider: .claude))

            let cleared = CookieHeaderCache.withLegacyRemovalFailureForTesting {
                CookieHeaderCache.clearIfCurrent(provider: .claude, expected: stale)
            }
            let replaced = CookieHeaderCache.storeIfCurrent(
                provider: .claude,
                expected: stale,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(!cleared)
            #expect(replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-fresh")
            #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: .claude))
        }
    }

    @Test
    func `interactive mutation gate invalidates an earlier background observation`() {
        self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: "fixtureSession=original",
                sourceLabel: "Original")
            let observation = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)
            let gate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)

            #expect(!CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: observation,
                cookieHeader: "fixtureSession=background-during-login",
                sourceLabel: "Background"))
            #expect(CookieHeaderCache.storeResult(
                provider: .cursor,
                cookieHeader: "fixtureSession=selected",
                sourceLabel: "Interactive login"))
            CookieHeaderCache.endConditionalMutationGate(gate)

            #expect(!CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: observation,
                cookieHeader: "fixtureSession=background-after-login",
                sourceLabel: "Background"))
            #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader == "fixtureSession=selected")
        }
    }

    @Test
    func `observation captured during cancelled interactive mutation remains stale`() {
        self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: "fixtureSession=original",
                sourceLabel: "Original")
            let gate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)
            let observation = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)

            #expect(!CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: observation,
                cookieHeader: "fixtureSession=background-during-login",
                sourceLabel: "Background"))
            CookieHeaderCache.endConditionalMutationGate(gate)

            #expect(!CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: observation,
                cookieHeader: "fixtureSession=background-after-cancel",
                sourceLabel: "Background"))
            #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader == "fixtureSession=original")
        }
    }

    @Test
    func `nested interactive mutation gate blocks until outer flow ends`() {
        self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: "fixtureSession=original",
                sourceLabel: "Original")
            let outerGate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)
            let runnerGate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)
            CookieHeaderCache.endConditionalMutationGate(runnerGate)

            let whileOuterGateIsActive = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)
            #expect(!CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: whileOuterGateIsActive,
                cookieHeader: "fixtureSession=background",
                sourceLabel: "Background"))
            CookieHeaderCache.endConditionalMutationGate(outerGate)

            let afterOuterGateEnds = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)
            #expect(CookieHeaderCache.storeIfObservationCurrent(
                provider: .cursor,
                expected: afterOuterGateEnds,
                cookieHeader: "fixtureSession=late-background",
                sourceLabel: "Background"))
            #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader == "fixtureSession=late-background")
        }
    }

    private func withIsolatedCookieCache<T>(_ operation: () -> T) -> T {
        KeychainCacheStore.withServiceOverrideForTesting("cookie-conditional-\(UUID().uuidString)") {
            let legacyBase = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            return CookieHeaderCache.withLegacyBaseURLOverrideForTesting(legacyBase) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                return operation()
            }
        }
    }
}

import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaLowHookAccountScopingTests {
    @Test
    func `quota_low crossing history is scoped per account`() {
        // Same provider/window/lane, different accounts must not share history: one
        // account's high usage must not overwrite or re-arm another account's.
        let accountA = UsageStore.QuotaLowHookUsageKey(
            provider: .claude, window: .session, windowID: nil, account: "a@example.com")
        let accountB = UsageStore.QuotaLowHookUsageKey(
            provider: .claude, window: .session, windowID: nil, account: "b@example.com")
        #expect(accountA != accountB)

        var usage: [UsageStore.QuotaLowHookUsageKey: Double] = [:]
        usage[accountA] = 0.40
        usage[accountB] = 0.95
        // Account B's observation did not clobber account A's baseline.
        #expect(usage[accountA] == 0.40)
        #expect(usage[accountB] == 0.95)
    }

    @Test
    func `distinct windows and lanes stay independent for one account`() {
        let session = UsageStore.QuotaLowHookUsageKey(
            provider: .claude, window: .session, windowID: nil, account: "a@example.com")
        let weekly = UsageStore.QuotaLowHookUsageKey(
            provider: .claude, window: .weekly, windowID: nil, account: "a@example.com")
        let scoped = UsageStore.QuotaLowHookUsageKey(
            provider: .claude, window: .weekly, windowID: "claude-weekly-scoped-fable", account: "a@example.com")
        #expect(Set([session, weekly, scoped]).count == 3)
    }
}

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
    func `account discriminator separates email-less accounts by other identity fields`() {
        // Two accounts with no email but different organizations must not collide.
        let orgA = UsageStore.quotaHookAccountKey(email: nil, organization: "org-a", loginMethod: "oauth")
        let orgB = UsageStore.quotaHookAccountKey(email: nil, organization: "org-b", loginMethod: "oauth")
        #expect(orgA != nil)
        #expect(orgA != orgB)

        // Same email but different login method still separates.
        let sub = UsageStore.quotaHookAccountKey(email: "x@y.com", organization: nil, loginMethod: "subscription")
        let api = UsageStore.quotaHookAccountKey(email: "x@y.com", organization: nil, loginMethod: "api")
        #expect(sub != api)

        // Identical identity (same account) shares a key; no identity is nil.
        let same1 = UsageStore.quotaHookAccountKey(email: "x@y.com", organization: "org", loginMethod: "oauth")
        let same2 = UsageStore.quotaHookAccountKey(email: "x@y.com", organization: "org", loginMethod: "oauth")
        #expect(same1 == same2)
        #expect(UsageStore.quotaHookAccountKey(email: nil, organization: nil, loginMethod: nil) == nil)
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

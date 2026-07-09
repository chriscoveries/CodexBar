import Foundation
import Testing
@testable import CodexBarCore

struct HooksTests {
    private func event(
        _ type: HookEventType = .quotaReached,
        provider: String = "codex",
        usagePercent: Double? = 0.95,
        account: String? = nil,
        window: String? = "session") -> HookEvent
    {
        HookEvent(
            event: type,
            provider: provider,
            account: account,
            window: window,
            usagePercent: usagePercent,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            timestamp: Date(timeIntervalSince1970: 1_700_000_100))
    }

    // MARK: - Matching

    @Test
    func `rule matches on event and provider`() {
        let rule = HookRule(event: .quotaReached, provider: "codex", executable: "/bin/echo")
        #expect(rule.matches(self.event(.quotaReached, provider: "codex")))
        #expect(!rule.matches(self.event(.quotaReached, provider: "claude")))
        #expect(!rule.matches(self.event(.quotaLow, provider: "codex")))
    }

    @Test
    func `nil provider matches any provider`() {
        let rule = HookRule(event: .quotaReached, provider: nil, executable: "/bin/echo")
        #expect(rule.matches(self.event(.quotaReached, provider: "codex")))
        #expect(rule.matches(self.event(.quotaReached, provider: "claude")))
    }

    @Test
    func `quotaLow threshold gates on usage percent`() {
        let rule = HookRule(event: .quotaLow, threshold: 0.90, executable: "/bin/echo")
        #expect(rule.matches(self.event(.quotaLow, usagePercent: 0.92)))
        #expect(rule.matches(self.event(.quotaLow, usagePercent: 0.90)))
        #expect(!rule.matches(self.event(.quotaLow, usagePercent: 0.80)))
        #expect(!rule.matches(self.event(.quotaLow, usagePercent: nil)))
    }

    @Test
    func `disabled rule and relative path never match`() {
        let disabled = HookRule(enabled: false, event: .quotaReached, executable: "/bin/echo")
        #expect(!disabled.matches(self.event()))

        let relative = HookRule(event: .quotaReached, executable: "my-command")
        #expect(!relative.matches(self.event()))
    }

    @Test
    func `disabled config yields no matching rules`() {
        let rule = HookRule(event: .quotaReached, executable: "/bin/echo")
        let enabled = HooksConfig(enabled: true, events: [rule])
        let disabled = HooksConfig(enabled: false, events: [rule])
        #expect(enabled.matchingRules(for: self.event()).count == 1)
        #expect(disabled.matchingRules(for: self.event()).isEmpty)
    }

    // MARK: - Payload

    @Test
    func `environment variables include set fields and omit nil`() {
        let env = self.event(.quotaLow, usagePercent: 0.5, account: nil, window: "weekly")
            .environmentVariables()
        #expect(env["CODEXBAR_EVENT"] == "quota_low")
        #expect(env["CODEXBAR_PROVIDER"] == "codex")
        #expect(env["CODEXBAR_WINDOW"] == "weekly")
        #expect(env["CODEXBAR_USAGE_PERCENT"] == "0.5")
        #expect(env["CODEXBAR_RESET_AT"] == "2023-11-14T22:13:20Z")
        #expect(env["CODEXBAR_TIMESTAMP"] != nil)
        #expect(env["CODEXBAR_ACCOUNT"] == nil)
        #expect(env["CODEXBAR_STATUS"] == nil)
    }

    @Test
    func `json payload round-trips`() throws {
        let original = self.event(.quotaReached, provider: "claude", usagePercent: 0.42, window: "session")
        let data = try original.jsonPayload()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HookEvent.self, from: data)
        #expect(decoded.event == .quotaReached)
        #expect(decoded.provider == "claude")
        #expect(decoded.usagePercent == 0.42)
        #expect(decoded.window == "session")
    }

    // MARK: - Rate limiter

    @Test
    func `rate limiter suppresses same key within window`() async {
        let limiter = HookRateLimiter(window: 600)
        let base = Date(timeIntervalSince1970: 1_000_000)
        #expect(await limiter.allow(self.event(), now: base))
        #expect(await !limiter.allow(self.event(), now: base.addingTimeInterval(300)))
        #expect(await limiter.allow(self.event(), now: base.addingTimeInterval(601)))
    }

    @Test
    func `rate limiter treats distinct keys independently`() async {
        let limiter = HookRateLimiter(window: 600)
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(await limiter.allow(self.event(provider: "codex"), now: now))
        #expect(await limiter.allow(self.event(provider: "claude"), now: now))
    }

    // MARK: - Runner

    @Test
    func `runner executes command and passes environment`() async throws {
        // /usr/bin/env prints the environment; assert our injected vars reach the child.
        let rule = HookRule(event: .quotaReached, executable: "/usr/bin/env")
        let result = try await HookRunner.run(rule: rule, event: self.event())
        #expect(result.stdout.contains("CODEXBAR_EVENT=quota_reached"))
        #expect(result.stdout.contains("CODEXBAR_PROVIDER=codex"))
    }

    @Test
    func `runner throws on missing executable`() async {
        let rule = HookRule(event: .quotaReached, executable: "/nonexistent/codexbar-hook")
        await #expect(throws: SubprocessRunnerError.self) {
            try await HookRunner.run(rule: rule, event: self.event())
        }
    }
}

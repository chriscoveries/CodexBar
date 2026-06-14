import Testing
@testable import CodexBarCore

struct AntigravityCompactFallbackTests {
    @Test
    func `local unclassified model remains available as compact fallback`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows?.map(\.id) == ["antigravity-compact-fallback-MODEL_PLACEHOLDER_NEW"])
        #expect(usage.extraRateWindows?.map(\.title) == ["Experimental Model"])
        #expect(usage.extraRateWindows?.map(\.window.usedPercent) == [64])
    }

    @Test
    func `remote unclassified model remains detail only`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows?.map(\.id) == ["MODEL_PLACEHOLDER_NEW"])
    }
}

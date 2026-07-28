import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `codex weekly celebration ignores an advanced boundary before the prior reset is due`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-early-rolling-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-early-rolling-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-07-28T03:09:20Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-02T10:17:56Z"))
        let falseLowCapturedAt = try #require(formatter.date(from: "2026-07-28T03:59:23Z"))
        let falseLowReset = try #require(formatter.date(from: "2026-08-04T03:59:21Z"))
        let previous = codexWeeklySnapshotForEarlyBoundaryTest(
            accountLabel: accountLabel,
            usedPercent: 100,
            resetsAt: previousReset,
            updatedAt: previousCapturedAt)
        let falseLow = codexWeeklySnapshotForEarlyBoundaryTest(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: falseLowReset,
            updatedAt: falseLowCapturedAt)
        let realReset = codexWeeklySnapshotForEarlyBoundaryTest(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: previousReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: previousReset.addingTimeInterval(1))

        for snapshot in [previous, falseLow] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }
}

private func codexWeeklySnapshotForEarlyBoundaryTest(
    accountLabel: String,
    usedPercent: Double,
    resetsAt: Date,
    updatedAt: Date) -> UsageSnapshot
{
    UsageSnapshot(
        primary: RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: 14,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil),
        updatedAt: updatedAt,
        identity: ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: accountLabel,
            accountOrganization: nil,
            loginMethod: "test"))
}

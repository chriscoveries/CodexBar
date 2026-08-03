import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// `WidgetSnapshotStore.load()` opens a file in the real app-group container. On
/// macOS 26 that `open()` can block forever behind app-data (TCC) gating, so a
/// test that reaches `persistWidgetSnapshot` without stubbing the save path hangs
/// the whole suite. These tests pin the gate that keeps container I/O out of tests.
@MainActor
struct WidgetSnapshotTestIsolationTests {
    @Test
    func `persistence gate only opens for tests that install a save override`() {
        #expect(!UsageStore.shouldPersistWidgetSnapshot(isRunningTests: true, hasSaveOverride: false))
        #expect(UsageStore.shouldPersistWidgetSnapshot(isRunningTests: true, hasSaveOverride: true))
        #expect(UsageStore.shouldPersistWidgetSnapshot(isRunningTests: false, hasSaveOverride: false))
        #expect(UsageStore.shouldPersistWidgetSnapshot(isRunningTests: false, hasSaveOverride: true))
    }

    @Test
    func `persist without a save override queues no widget snapshot work`() {
        let settings = testSettingsStore(suiteName: "WidgetSnapshotTestIsolationTests-no-override")
        settings.providerDetectionCompleted = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        store.persistWidgetSnapshot(reason: "test-no-override")

        #expect(store.widgetSnapshotPersistTask == nil)
        #expect(store.lastQueuedWidgetSnapshot == nil)
    }

    @Test
    func `persist with a save override routes the snapshot through the override`() async {
        let settings = testSettingsStore(suiteName: "WidgetSnapshotTestIsolationTests-override")
        settings.providerDetectionCompleted = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "test-override")
        await store.widgetSnapshotPersistTask?.value

        #expect(saved.count == 1)
    }
}

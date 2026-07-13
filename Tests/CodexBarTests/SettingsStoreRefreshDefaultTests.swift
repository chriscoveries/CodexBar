import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct SettingsStoreRefreshDefaultTests {
    enum PreviousLaunchMarker: CaseIterable, Sendable {
        case providerDetection
        case appGroupMigration

        func seed(_ defaults: UserDefaults) {
            switch self {
            case .providerDetection:
                defaults.set(true, forKey: "providerDetectionCompleted")
            case .appGroupMigration:
                defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
            }
        }
    }

    @Test
    func `fresh install defaults to adaptive and persists the choice`() throws {
        let suite = "SettingsStoreRefreshDefaultTests-fresh"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = self.makeStore(defaults: defaults, configStore: configStore)

        #expect(store.refreshFrequency == .adaptive)
        #expect(store.refreshFrequency.seconds == nil)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.adaptive.rawValue)

        defaults.set(true, forKey: "providerDetectionCompleted")
        let reloaded = self.makeStore(defaults: defaults, configStore: configStore)
        #expect(reloaded.refreshFrequency == .adaptive)
    }

    @Test
    func `unrecognized refresh frequency keeps the legacy fallback`() throws {
        let suite = "SettingsStoreRefreshDefaultTests-invalid"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("legacyValue", forKey: "refreshFrequency")

        let store = self.makeStore(
            defaults: defaults,
            configStore: testConfigStore(suiteName: suite))

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test(arguments: PreviousLaunchMarker.allCases)
    func `legacy unset refresh keeps five minute fallback`(marker: PreviousLaunchMarker) throws {
        let suite = "SettingsStoreRefreshDefaultTests-legacy-\(marker)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        marker.seed(defaults)

        let store = self.makeStore(
            defaults: defaults,
            configStore: testConfigStore(suiteName: suite))

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test
    func `existing config without launch markers keeps five minute fallback`() throws {
        let suite = "SettingsStoreRefreshDefaultTests-existing-config"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig.makeDefault())

        let store = self.makeStore(defaults: defaults, configStore: configStore)

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test
    func `non string refresh value keeps five minute fallback`() throws {
        let suite = "SettingsStoreRefreshDefaultTests-non-string"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(17, forKey: "refreshFrequency")

        let store = self.makeStore(
            defaults: defaults,
            configStore: testConfigStore(suiteName: suite))

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test
    func `every valid stored refresh frequency remains authoritative`() throws {
        let markers: [PreviousLaunchMarker?] = [nil, .providerDetection, .appGroupMigration]
        for frequency in RefreshFrequency.allCases {
            for marker in markers {
                let suite = "SettingsStoreRefreshDefaultTests-valid-\(frequency.rawValue)-\(String(describing: marker))"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                defaults.set(frequency.rawValue, forKey: "refreshFrequency")
                marker?.seed(defaults)

                let store = self.makeStore(
                    defaults: defaults,
                    configStore: testConfigStore(suiteName: suite))

                #expect(store.refreshFrequency == frequency)
                #expect(defaults.string(forKey: "refreshFrequency") == frequency.rawValue)
            }
        }
    }

    private func makeStore(
        defaults: UserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}

import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct CrossModelProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .crossmodel

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.crossModelAPIToken
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if CrossModelSettingsReader.apiToken(environment: context.environment) != nil {
            return true
        }
        return !context.settings.crossModelAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "crossmodel-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. "
                    + "Create a key in the CrossModel console at crossmodel.ai/console/api-keys.",
                kind: .secure,
                placeholder: "cm-...",
                binding: context.stringBinding(\.crossModelAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

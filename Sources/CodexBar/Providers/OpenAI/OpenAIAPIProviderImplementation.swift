import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct OpenAIAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .openai, field: .apiKey]
        _ = settings[providerConfig: .openai, field: .secretWorkspace(logField: "projectID")]
        _ = settings.openaiMonthlyBudgetUSD
        _ = settings.openaiBudgetResetDay
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenAIAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .openai, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let monthlyBudgetBinding = Binding(
            get: {
                guard let budget = context.settings.openaiMonthlyBudgetUSD else { return "" }
                return budget == budget.rounded() ? String(Int(budget)) : String(budget)
            },
            set: { text in
                context.settings.openaiMonthlyBudgetUSD =
                    Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            })
        let budgetResetDayBinding = Binding(
            get: { String(context.settings.openaiBudgetResetDay) },
            set: { text in
                context.settings.openaiBudgetResetDay =
                    OpenAIAPISpendBudget.sanitizedResetDay(
                        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            })

        return [
            ProviderSettingsFieldDescriptor(
                id: "openai-api-key",
                title: "Admin API key",
                subtitle: "Stored in ~/.codexbar/config.json. OPENAI_ADMIN_KEY is required for organization usage; " +
                    "legacy/user keys only get a best-effort balance fallback.",
                kind: .secure,
                placeholder: "sk-admin-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "openai-open-billing",
                        title: "Open billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.openai.com/settings/organization/billing/overview")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-project-id",
                title: "Project ID",
                subtitle: "Optional. Applies to the configured Admin API key; selected token accounts do not " +
                    "inherit OPENAI_PROJECT_ID.",
                kind: .plain,
                placeholder: "proj_...",
                binding: context.providerConfigBinding(.secretWorkspace(logField: "projectID")),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "openai-open-projects",
                        title: "Open projects",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.openai.com/settings/organization/projects") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-monthly-budget",
                title: "Monthly budget (USD)",
                subtitle: "Set your monthly OpenAI budget to get a spend pace bar. Leave empty to disable.",
                kind: .plain,
                placeholder: "e.g. 120",
                binding: monthlyBudgetBinding,
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-budget-reset-day",
                title: "Budget resets on day",
                subtitle: "Day of month your budget resets (1-28).",
                kind: .plain,
                placeholder: "1",
                binding: budgetResetDayBinding,
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

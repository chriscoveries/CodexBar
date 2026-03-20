import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    @discardableResult
    func addUsageHistoryMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeUsageHistorySubmenu(provider: provider) else { return false }
        let width: CGFloat = 310
        menu.addItem(self.makeFixedWidthSubmenuItem(title: "Subscription Utilization", submenu: submenu, width: width))
        return true
    }

    private func makeUsageHistorySubmenu(provider: UsageProvider) -> NSMenu? {
        guard provider == .codex || provider == .claude else { return nil }
        let width: CGFloat = 310
        let submenu = NSMenu()
        submenu.delegate = self
        return self.appendUsageHistoryChartItem(to: submenu, provider: provider, width: width) ? submenu : nil
    }

    private func appendUsageHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        let presentation = self.store.planUtilizationHistoryPresentation(for: provider)
        let histories = presentation.histories
        let snapshot = self.store.snapshot(for: provider)
        let isRefreshing = presentation.isRefreshing

        if !Self.menuCardRenderingEnabled {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = "usageHistoryChart"
            submenu.addItem(chartItem)
            return true
        }

        let chartView = PlanUtilizationHistoryChartMenuView(
            provider: provider,
            histories: histories,
            snapshot: snapshot,
            width: width,
            isRefreshing: isRefreshing)
        let hosting = MenuHostingView(rootView: chartView)
        let controller = NSHostingController(rootView: chartView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "usageHistoryChart"
        submenu.addItem(chartItem)
        return true
    }
}

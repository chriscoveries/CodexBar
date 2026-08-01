import AppKit
import CodexBarCore

/// Keeps the merged menu's window height stable across provider tab switches.
///
/// Probe captures (`MenuSwitchFlickerProbe`) show the tab-switch composite is
/// atomic, but tabs of different heights make AppKit resize the menu window on
/// every switch; the moving bottom edge plus the WindowServer backdrop/shadow
/// recompute reads as a flash. Each provider tab carries a zero-height spacer
/// row between the usage content and the trailing action rows; this pass sizes
/// those spacers so every provider tab matches the tallest one. Overview is
/// excluded: it is a different mode and may be far taller.
extension StatusItemController {
    static let stableMenuHeightSpacerID = "stableHeightSpacer"
    /// Estimated heights for rows AppKit lays out natively (no custom view).
    private static let nativeMenuRowHeightEstimate: CGFloat = 24
    private static let menuSeparatorHeightEstimate: CGFloat = 13

    func makeStableMenuHeightSpacerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.representedObject = Self.stableMenuHeightSpacerID
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 0))
        item.view = view
        return item
    }

    /// Equalizes provider-tab content heights: the visible menu's spacer and every
    /// cached provider tab's spacer are sized against the tallest tab. Runs after
    /// card heights are final for the current populate pass.
    ///
    /// Known simplification: cached tabs keep the spacer size they were last
    /// padded with, so a data tick that shrinks the tallest tab can leave a stale
    /// gap until the sibling becomes visible again — a one-frame height nudge at
    /// worst, instead of a jump on every switch.
    func applyStableMenuHeightPadding(in menu: NSMenu) {
        // Any merged-style menu qualifies: only merged menus carry the provider switcher.
        guard self.shouldMergeIcons, menu.items.first?.view is ProviderSwitcherView else { return }
        guard self.store.enabledProvidersForDisplay().count > 1 else { return }
        let contentStartIndex = self.providerSwitcherContentStartIndex(in: menu)
        guard contentStartIndex > 0 else { return }

        let visibleItems = Array(menu.items[contentStartIndex...])
        let visibleIsProviderTab = self.lastMergedMenuContentSelection.map { $0 != .overview } ?? true
        var tabs: [(spacer: NSMenuItem?, contentHeight: CGFloat)] = []
        if visibleIsProviderTab {
            tabs.append(self.measureTab(items: visibleItems))
        }
        let cacheEntries = self.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
        for (selection, entry) in cacheEntries where selection != .overview {
            if visibleIsProviderTab, selection == self.lastMergedMenuContentSelection { continue }
            tabs.append(self.measureTab(items: entry.items))
        }
        MenuSwitchFlickerProbe.debugLog(
            "padding: visibleProvider=\(visibleIsProviderTab) " +
                "selection=\(String(describing: self.lastMergedMenuContentSelection)) " +
                "cacheKeys=\(cacheEntries.keys.map { String(describing: $0) }) " +
                "tabs=\(tabs.map { "(spacer:\($0.spacer != nil) h:\($0.contentHeight))" })")
        guard tabs.count > 1, let maxHeight = tabs.map(\.contentHeight).max() else { return }

        for tab in tabs {
            guard let spacer = tab.spacer, let spacerView = spacer.view else { continue }
            let padding = max(0, maxHeight - tab.contentHeight)
            if abs(spacerView.frame.height - padding) > 0.5 {
                MenuSwitchFlickerProbe.debugLog("padding: set spacer \(spacerView.frame.height) -> \(padding)")
                spacerView.setFrameSize(NSSize(width: 1, height: padding))
            }
        }
    }

    /// Content height excluding the spacer itself, plus the spacer item when present.
    /// Internal for test access.
    func measureTab(items: [NSMenuItem]) -> (spacer: NSMenuItem?, contentHeight: CGFloat) {
        var spacer: NSMenuItem?
        var height: CGFloat = 0
        for item in items {
            if item.representedObject as? String == Self.stableMenuHeightSpacerID {
                spacer = item
                continue
            }
            if item.isSeparatorItem {
                height += Self.menuSeparatorHeightEstimate
            } else if let view = item.view {
                height += view.frame.height
            } else {
                height += Self.nativeMenuRowHeightEstimate
            }
        }
        return (spacer, height)
    }
}

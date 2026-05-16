import AppKit
import Foundation

struct StatusItemVisibilitySnapshot: Equatable {
    let isVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasScreen: Bool
    let buttonWidth: CGFloat
}

extension StatusItemVisibilitySnapshot: CustomStringConvertible {
    var description: String {
        "visible=\(self.isVisible),button=\(self.hasButton),window=\(self.hasWindow),"
            + "screen=\(self.hasScreen),width=\(String(format: "%.1f", Double(self.buttonWidth)))"
    }
}

@MainActor
func isStatusItemBlocked(_ item: NSStatusItem) -> Bool {
    MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: MenuBarVisibilityWatcher.visibilitySnapshot(item))
}

enum MenuBarVisibilityWatcher {
    static let guidanceShownKey = "hasShownTahoeAllowListGuidance"
    static let guidanceLastShownAtKey = "tahoeAllowListGuidanceLastShownAt"
    static let guidanceRepeatInterval: TimeInterval = 24 * 60 * 60
    static let startupFreshnessInterval: TimeInterval = 10
    static let startupCheckDelay: TimeInterval = 2
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.MenuBarSettings")!

    @MainActor
    static func visibilitySnapshot(_ item: NSStatusItem) -> StatusItemVisibilitySnapshot {
        StatusItemVisibilitySnapshot(
            isVisible: item.isVisible,
            hasButton: item.button != nil,
            hasWindow: item.button?.window != nil,
            hasScreen: item.button?.window?.screen != nil,
            buttonWidth: item.button?.frame.size.width ?? 0)
    }

    static func isBlockedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible else { return false }
        guard snapshot.hasButton else { return true }
        return !snapshot.hasWindow || !snapshot.hasScreen || snapshot.buttonWidth <= 0
    }

    static func hasBlockedVisibleSnapshots(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        let visibleItems = snapshots.filter(\.isVisible)
        guard !visibleItems.isEmpty else { return false }
        return visibleItems.allSatisfy { snapshot in
            self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnyBlockedVisibleSnapshot(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        snapshots.contains { snapshot in
            snapshot.isVisible && self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    @MainActor
    static func visibilitySnapshots(_ items: [NSStatusItem]) -> [StatusItemVisibilitySnapshot] {
        items.map { item in
            self.visibilitySnapshot(item)
        }
    }

    @MainActor
    static func hasBlockedVisibleStatusItems(_ items: [NSStatusItem]) -> Bool {
        self.hasBlockedVisibleSnapshots(self.visibilitySnapshots(items))
    }

    static func shouldAttemptStartupRecovery(
        appLaunchedAt: Date,
        now: Date = Date(),
        snapshots: [StatusItemVisibilitySnapshot])
        -> Bool
    {
        guard now.timeIntervalSince(appLaunchedAt) <= self.startupFreshnessInterval else { return false }
        return self.hasAnyBlockedVisibleSnapshot(snapshots)
    }

    static func shouldShowGuidance(defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: self.guidanceShownKey) else { return true }
        let lastShownAt = defaults.double(forKey: self.guidanceLastShownAtKey)
        guard lastShownAt > 0 else { return false }
        return now.timeIntervalSince1970 - lastShownAt >= self.guidanceRepeatInterval
    }

    static func markGuidanceShown(defaults: UserDefaults, now: Date = Date()) {
        defaults.set(true, forKey: self.guidanceShownKey)
        defaults.set(now.timeIntervalSince1970, forKey: self.guidanceLastShownAtKey)
    }

    @MainActor
    static func presentGuidance(
        defaults: UserDefaults,
        now: Date = Date(),
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) })
    {
        self.markGuidanceShown(defaults: defaults, now: now)

        let alert = NSAlert()
        alert.messageText = L("CodexBar can't show its menu bar icon")
        alert.informativeText = L(
            "macOS Tahoe can block menu bar apps in System Settings → Menu Bar → Allow in the Menu Bar. "
                + "CodexBar is running, but macOS may be hiding its icon. Open Menu Bar settings and turn CodexBar on.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Menu Bar Settings"))
        alert.addButton(withTitle: L("Dismiss"))

        if alert.runModal() == .alertFirstButtonReturn {
            openURL(self.settingsURL)
        }
    }
}

extension StatusItemController {
    func scheduleStartupStatusItemVisibilityCheck(appLaunchedAt: Date = Date()) {
        guard !SettingsStore.isRunningTests else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarVisibilityWatcher.startupCheckDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkStartupStatusItemVisibility(appLaunchedAt: appLaunchedAt)
            }
        }
    }

    private func checkStartupStatusItemVisibility(appLaunchedAt: Date, now: Date = Date()) {
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        guard MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: appLaunchedAt,
            now: now,
            snapshots: snapshots)
        else {
            return
        }

        self.menuLogger.error(
            "Status item failed to materialize; recreating status items",
            metadata: ["snapshots": snapshots.map(\.description).joined(separator: " | ")])
        self.recreateStatusItemsForVisibilityRecovery()

        let recoveredSnapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        guard MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: appLaunchedAt,
            now: now,
            snapshots: recoveredSnapshots)
        else {
            self.menuLogger.info(
                "Status item materialized after recreation",
                metadata: ["snapshots": recoveredSnapshots.map(\.description).joined(separator: " | ")])
            return
        }

        self.menuLogger.error(
            "Status item still failed to materialize after recreation",
            metadata: ["snapshots": recoveredSnapshots.map(\.description).joined(separator: " | ")])
        guard #available(macOS 26.0, *),
              MenuBarVisibilityWatcher.shouldShowGuidance(defaults: self.settings.userDefaults, now: now)
        else {
            return
        }
        MenuBarVisibilityWatcher.presentGuidance(defaults: self.settings.userDefaults, now: now)
    }

    private var startupVisibilityStatusItems: [NSStatusItem] {
        [self.statusItem] + Array(self.statusItems.values)
    }
}

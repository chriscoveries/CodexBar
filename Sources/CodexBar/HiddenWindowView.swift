import SwiftUI

final class SettingsOpenRequest {
    var wasHandled = false
}

struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .background(KeepaliveWindowConfigurator())
            .onReceive(NotificationCenter.default.publisher(for: .codexbarOpenSettings)) { notification in
                (notification.object as? SettingsOpenRequest)?.wasHandled = true
                Task { @MainActor in
                    self.openSettings()
                }
            }
            .task {
                // Migrate keychain items to reduce permission prompts during development (runs off main thread)
                await Task.detached(priority: .userInitiated) {
                    KeychainMigration.migrateIfNeeded()
                }.value
            }
    }
}

@MainActor
private struct KeepaliveWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> KeepaliveWindowConfiguratorView {
        KeepaliveWindowConfiguratorView()
    }

    func updateNSView(_ nsView: KeepaliveWindowConfiguratorView, context: Context) {}
}

@MainActor
private final class KeepaliveWindowConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.identifier = NSUserInterfaceItemIdentifier("CodexBarLifecycleKeepalive")
        // Make the keepalive window truly invisible and non-interactive.
        window.styleMask = [.borderless]
        window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient, .canJoinAllSpaces]
        window.isExcludedFromWindowsMenu = true
        window.level = .floating
        window.isOpaque = false
        window.alphaValue = 0
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.setContentSize(NSSize(width: 1, height: 1))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
    }
}

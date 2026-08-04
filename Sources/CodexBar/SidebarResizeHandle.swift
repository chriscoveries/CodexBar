import AppKit
import SwiftUI

/// Input-only drag strip that resizes the settings sidebar. It draws nothing — the
/// visible hairline stays the `Divider()` in `PreferencesView` — and rides as an
/// overlay on the detail pane's leading edge, which sits exactly on the
/// sidebar/content boundary. Overlaying the detail side (instead of the sidebar's
/// trailing edge) keeps the strip clear of the sidebar list's scroller, and staying
/// out of the `HStack` keeps it from disturbing SwiftUI's width negotiation.
///
/// AppKit mouse tracking is deliberate: a SwiftUI `DragGesture` re-enters layout per
/// event and jitters, while `mouseDown`/`mouseDragged` on an `NSView` report window
/// coordinates that stay stable even as the strip itself moves mid-drag.
///
/// The hover cursor is belt-and-braces: `.pointerStyle(.columnResize)` in
/// `PreferencesView` registers with SwiftUI's pointer engine on macOS 15+, and this
/// view's tracking area asserts `NSCursor` directly (the only mechanism on macOS 14).
/// Both produce the same left-right resize arrows, so they cannot fight.
struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        self.configure(view)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        self.configure(nsView)
    }

    private func configure(_ view: SidebarResizeHandleView) {
        view.getWidth = { self.width }
        view.setWidth = { newWidth in
            self.width = min(max(newWidth, self.minWidth), self.maxWidth)
        }
    }
}

final class SidebarResizeHandleView: NSView {
    /// Width of the grabbable strip; matches the slop AppKit gives thin split-view dividers.
    static let grabWidth: CGFloat = 12

    var getWidth: (() -> Double)?
    var setWidth: ((Double) -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: Double = 0
    private var trackingArea: NSTrackingArea?

    // Clicks here must resize, never drag the window (the strip reaches up into the
    // transparent-titlebar region).
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        // Explicit rect, not `.inVisibleRect`: the hosting view doesn't clip, so
        // `visibleRect` spans the whole window and enter/exit events never fire.
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        // Re-assert every move: SwiftUI keeps resetting the cursor underneath us.
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        self.dragStartX = event.locationInWindow.x
        self.dragStartWidth = self.getWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = event.locationInWindow.x - self.dragStartX
        // Sidebar sits left of the strip: dragging right (positive delta) grows it.
        self.setWidth?(self.dragStartWidth + Double(deltaX))
        // Keep the resize cursor while the pointer strays outside the moving strip.
        NSCursor.resizeLeftRight.set()
    }
}

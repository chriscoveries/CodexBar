#if os(macOS)
import AppKit
import SwiftUI

struct FocusResigningMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> FocusResigningMonitorView {
        let view = FocusResigningMonitorView()
        view.isActive = self.isActive
        view.onOutsideClick = self.onOutsideClick
        return view
    }

    func updateNSView(_ nsView: FocusResigningMonitorView, context: Context) {
        nsView.isActive = self.isActive
        nsView.onOutsideClick = self.onOutsideClick
    }

    static func dismantleNSView(_ nsView: FocusResigningMonitorView, coordinator: ()) {
        nsView.invalidate()
    }
}

final class FocusResigningMonitorView: NSView {
    var onOutsideClick: (() -> Void)?
    var isActive: Bool = false {
        didSet { self.updateMonitor() }
    }

    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate() {
        self.isActive = false
        self.onOutsideClick = nil
    }

    private func updateMonitor() {
        if self.isActive {
            self.installMonitor()
        } else {
            self.removeMonitor()
        }
    }

    private func installMonitor() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard self.isActive else { return }
        guard let window = self.window, event.window === window else { return }

        let location = self.convert(event.locationInWindow, from: nil)
        guard !self.bounds.contains(location) else { return }
        guard !Self.eventHitsTextInput(event) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onOutsideClick?()
        }
    }

    private static func eventHitsTextInput(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(location) else { return false }
        return hitView.hasAncestor(of: NSTextField.self) || hitView.hasAncestor(of: NSTextView.self)
    }
}

extension NSView {
    fileprivate func hasAncestor<T: NSView>(of type: T.Type) -> Bool {
        var view: NSView? = self
        while let current = view {
            if current is T {
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif
